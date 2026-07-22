#!/usr/bin/env bash
# ============================================================
# T4: OCI MySQL HeatWave → Object Storage L2 백업 스크립트
# ============================================================
# 동작:
#   1. flock으로 백업/복구/GameDay 직렬화 (락 점유 시 즉시 종료 + skip +1)
#   2. mysqldump --single-transaction --routines --triggers | gzip
#   3. sha256sum
#   4. DB 메타데이터(스키마/테이블/row 카운트 + 호스트·dump 도구 버전) JSON
#   5. metadata에 size·sha·duration·key 머지
#   6. OCI Object Storage에 3종 PUT (dump, meta, sha)
#   7. Prometheus textfile 메트릭 갱신
#
# 종료 코드:
#   0  성공 (또는 락 점유로 skip)
#   2  dump 실패
#   3  checksum 실패
#   4  upload 실패
#   5  메타데이터 수집 실패
#   1  사용법/환경변수 오류
#
# 환경변수 (필수):
#   MYSQL_HOST, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DATABASE
# 환경변수 (선택):
#   MYSQL_PORT          기본 3306
#   MYSQL_CNF           --defaults-extra-file 경로 (password CLI 노출 회피)
#   BUCKET              기본 qasker-mysql-backup
#   OCI_PROFILE         기본 BACKUP_WRITER
#   LOCK_FILE           기본 /var/lock/oci-mysql-backup.lock
#   STATE_FILE          기본 /var/lib/oci-mysql-backup/state.json
#   METRIC_FILE         기본 /var/lib/node_exporter/textfile_collector/oci_mysql_backup.prom
#   WORK_BASE_DIR       기본 /tmp
#   DRY_RUN             "1" 설정 시 upload 생략 (로컬 테스트)

set -uo pipefail

# ─── 환경변수 기본값 ───
: "${BUCKET:=qasker-mysql-backup}"
: "${OCI_PROFILE:=BACKUP_WRITER}"
: "${LOCK_FILE:=/var/lock/oci-mysql-backup.lock}"
: "${WORK_BASE_DIR:=/tmp}"
: "${DRY_RUN:=0}"

# 저장소 임계 (2단계 경고). 무료 20GB는 tenancy 전체 Object Storage 합산이라 총량을 감시한다.
# 총량 조회는 'read buckets' 권한 프로필 필요(BACKUP_USAGE_READER; BACKUP_WRITER 스코프로는 불가).
# 조회 실패 시 경고만 스킵하고 백업은 정상.
: "${BACKUP_FREE_LIMIT_BYTES:=20000000000}"   # 20 GB (전 버킷 합산)
: "${USAGE_OCI_PROFILE:=BACKUP_USAGE_READER}"
: "${STORAGE_TIER_STATE:=/var/lib/oci-mysql-backup/storage-alert-tier.state}"
STORAGE_WARN_RATIO="0.80"
STORAGE_CRIT_RATIO="0.90"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# lib source
# shellcheck source=lib/metrics.sh
source "$SCRIPT_DIR/lib/metrics.sh"
# shellcheck source=lib/metadata.sh
source "$SCRIPT_DIR/lib/metadata.sh"
# shellcheck source=lib/notify.sh
source "$SCRIPT_DIR/lib/notify.sh"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
fail() {
  local stage="$1" code="$2"
  log "[FAIL] stage=$stage exit=$code"
  metric_increment_fail
  notify_slack ERROR "백업 실패 stage=$stage exit=$code object_key=${OBJECT_KEY:-?}"
  exit "$code"
}

# sha256sum(GNU/coreutils) 또는 shasum -a 256(macOS/BSD) 이식성 래퍼.
# 둘 다 "<hash>  <path>" 형식으로 출력하므로 downstream awk '{print $1}' 호환.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
  else shasum -a 256 "$@"; fi
}

# 저장소 사용량 2단계 경고 (PLG backup.sh와 동일 철학).
# 단계 상향 시에만 발송(재발송 억제), 회복 시 상태만 갱신. 대응은 MySQL 백업 주기 늘리기(systemd timer).
check_storage_threshold() {
  local usage ratio pct headroom cur_tier last_tier comp
  # tenancy 전체 사용량(전 버킷 approximateSize 합) — 무료 20GB는 버킷 합산이므로.
  comp="$(oci --profile "$USAGE_OCI_PROFILE" os bucket get --bucket-name "$BUCKET" --output json 2>/dev/null \
          | jq -r '.data."compartment-id" // empty')"
  if [[ -z "$comp" ]]; then
    log "[storage] 총량 조회 실패: compartment 확인 불가 (프로필 ${USAGE_OCI_PROFILE}의 read buckets 권한 확인) — 경고 스킵"
    return 1
  fi
  usage="$(oci --profile "$USAGE_OCI_PROFILE" os bucket list --compartment-id "$comp" --output json 2>/dev/null \
           | jq -r '.data[]?.name // empty' \
           | while IFS= read -r bkt; do
               [[ -z "$bkt" ]] && continue
               oci --profile "$USAGE_OCI_PROFILE" os bucket get --bucket-name "$bkt" --fields approximateSize \
                 --output json 2>/dev/null | jq -r '.data."approximate-size" // 0'
             done \
           | jq -s 'add // 0')"
  [[ "$usage" =~ ^[0-9]+$ ]] || usage=0
  ratio="$(awk -v u="$usage" -v l="$BACKUP_FREE_LIMIT_BYTES" 'BEGIN{ if(l>0) printf "%.4f", u/l; else print "0" }')"
  pct="$(awk -v r="$ratio" 'BEGIN{ printf "%.1f", r*100 }')"
  headroom=$(( BACKUP_FREE_LIMIT_BYTES - usage ))
  log "[storage] 사용량 ${usage}/${BACKUP_FREE_LIMIT_BYTES} bytes (ratio=${ratio})"

  cur_tier="$(awk -v r="$ratio" -v w="$STORAGE_WARN_RATIO" -v c="$STORAGE_CRIT_RATIO" \
              'BEGIN{ if(r>=c) print "crit"; else if(r>=w) print "warn"; else print "ok" }')"
  last_tier="ok"; [[ -f "$STORAGE_TIER_STATE" ]] && last_tier="$(cat "$STORAGE_TIER_STATE" 2>/dev/null || echo ok)"
  local -A rank=( [ok]=0 [warn]=1 [crit]=2 )
  local cr="${rank[$cur_tier]:-0}" lr="${rank[$last_tier]:-0}"
  mkdir -p "$(dirname "$STORAGE_TIER_STATE")" 2>/dev/null || true

  if (( cr > lr )); then
    if [[ "$cur_tier" == "crit" ]]; then
      notify_slack ERROR "🚨 저장소 총량 ${pct}% 임박 (전 버킷 합산, 잔여 ${headroom}B). 즉시 조치: 백업 주기 늘리기(MySQL=systemd oci-mysql-backup.timer, PLG=cron) / 유료 전환 판단."
    else
      notify_slack WARN "⚠️ 저장소 총량 ${pct}% 도달 (전 버킷 합산, 잔여 ${headroom}B). 백업 주기 늘리기 검토 — MySQL timer 6h→12h(예: 00,12:00:00) 또는 PLG cron."
    fi
    echo "$cur_tier" > "$STORAGE_TIER_STATE"
    log "[storage] 경고 상향: ${last_tier} → ${cur_tier}"
  elif (( cr < lr )); then
    echo "$cur_tier" > "$STORAGE_TIER_STATE"
    log "[storage] 단계 회복: ${last_tier} → ${cur_tier}"
  fi
}

# ─── 사전 검증 ───
for cmd in flock mysqldump mysql jq oci awk; do
  command -v "$cmd" >/dev/null || { log "[ERR] $cmd 미설치"; exit 1; }
done
for var in MYSQL_HOST MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE; do
  if [[ -z "${!var:-}" ]]; then
    log "[ERR] 필수 환경변수 $var 누락"
    exit 1
  fi
done

# ─── flock (논블로킹 직렬화) ───
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  log "[SKIP] lock $LOCK_FILE held by another process (backup/restore/gameday)"
  metric_increment_skip
  exit 0
fi

# ─── 작업 디렉터리 ───
WORK_DIR=$(mktemp -d "$WORK_BASE_DIR/oci-mysql-backup.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

# ─── 객체 키 (UTC 일자 prefix + ISO 시각) ───
NOW_UTC=$(date -u +%Y%m%dT%H%M%SZ)
DATE_PREFIX=$(date -u +%Y/%m/%d)
OBJECT_KEY="${DATE_PREFIX}/qasker-mysql-${NOW_UTC}.sql.gz"
META_KEY="${OBJECT_KEY%.sql.gz}.meta.json"
SHA_KEY="${OBJECT_KEY%.sql.gz}.sha256"

DUMP_FILE="$WORK_DIR/dump.sql.gz"
META_FILE="$WORK_DIR/meta.json"
SHA_FILE="$WORK_DIR/dump.sha256"

START_TS=$(date +%s)
log "[START] object_key=$OBJECT_KEY"

# ─── Step 1: mysqldump → gzip ───
log "[step 1/5] mysqldump..."
if [[ -n "${MYSQL_CNF:-}" ]]; then
  if ! mysqldump --defaults-extra-file="$MYSQL_CNF" \
       --single-transaction --routines --triggers --hex-blob \
       --set-gtid-purged=OFF \
       -h "$MYSQL_HOST" -P "${MYSQL_PORT:-3306}" "$MYSQL_DATABASE" \
       2> "$WORK_DIR/dump.err" | gzip -9 > "$DUMP_FILE"; then
    log "[ERR] mysqldump stderr:"
    cat "$WORK_DIR/dump.err" >&2
    fail "dump" 2
  fi
else
  if ! MYSQL_PWD="$MYSQL_PASSWORD" mysqldump \
       --single-transaction --routines --triggers --hex-blob \
       --set-gtid-purged=OFF \
       -h "$MYSQL_HOST" -P "${MYSQL_PORT:-3306}" -u "$MYSQL_USER" "$MYSQL_DATABASE" \
       2> "$WORK_DIR/dump.err" | gzip -9 > "$DUMP_FILE"; then
    log "[ERR] mysqldump stderr:"
    cat "$WORK_DIR/dump.err" >&2
    fail "dump" 2
  fi
fi
DUMP_SIZE=$(stat -c%s "$DUMP_FILE" 2>/dev/null || stat -f%z "$DUMP_FILE")
[[ "$DUMP_SIZE" -gt 0 ]] || fail "dump-empty" 2
log "[step 1/5] dump complete ($DUMP_SIZE bytes)"

# ─── Step 2: SHA256 ───
log "[step 2/5] checksum..."
if ! sha256 "$DUMP_FILE" | awk '{print $1}' > "$SHA_FILE"; then
  fail "checksum" 3
fi
SHA256=$(cat "$SHA_FILE")
log "[step 2/5] sha256=$SHA256"

# ─── Step 3: 메타데이터 수집 ───
log "[step 3/5] metadata..."
if ! collect_metadata > "$META_FILE"; then
  fail "metadata" 5
fi

# 대표 테이블 정확 COUNT(*) 병합 (baseline 있을 때만, T7 헬스체크 기대값)
if TABLE_COUNTS=$(collect_table_counts 2>/dev/null) && [[ "$TABLE_COUNTS" != "{}" ]]; then
  jq --argjson tc "$TABLE_COUNTS" '. + {table_counts: $tc}' "$META_FILE" > "${META_FILE}.tmp" \
    && mv "${META_FILE}.tmp" "$META_FILE"
  log "[step 3/5] table_counts merged: $(echo "$TABLE_COUNTS" | jq -c .)"
fi

# ─── Step 4: 메타데이터 머지 (크기·체크섬·소요·키) ───
DURATION=$(($(date +%s) - START_TS))
if ! finalize_metadata "$META_FILE" "$DUMP_SIZE" "$SHA256" "$DURATION" "$OBJECT_KEY"; then
  fail "metadata-finalize" 5
fi
log "[step 4/5] metadata finalized"

# ─── Step 5: OCI upload (dump, meta, sha) ───
if [[ "$DRY_RUN" == "1" ]]; then
  log "[step 5/5] DRY_RUN=1 → upload skip"
  log "[OK] (dry-run) would upload: $OBJECT_KEY ($DUMP_SIZE bytes, ${DURATION}s)"
  metric_record_success "$DUMP_SIZE" "$DURATION" "$OBJECT_KEY"
  exit 0
fi

log "[step 5/5] uploading 3 objects to bucket=$BUCKET profile=$OCI_PROFILE..."
upload() {
  local file="$1" key="$2"
  oci --profile "$OCI_PROFILE" os object put \
    --bucket-name "$BUCKET" \
    --name "$key" \
    --file "$file" \
    --force \
    >/dev/null 2>"$WORK_DIR/upload.err"
}
upload "$DUMP_FILE" "$OBJECT_KEY" || { log "[ERR] upload dump: $(cat "$WORK_DIR/upload.err")"; fail "upload-dump" 4; }
upload "$META_FILE" "$META_KEY"  || { log "[ERR] upload meta: $(cat "$WORK_DIR/upload.err")"; fail "upload-meta" 4; }
upload "$SHA_FILE"  "$SHA_KEY"   || { log "[ERR] upload sha: $(cat "$WORK_DIR/upload.err")"; fail "upload-sha" 4; }

# ─── 성공 메트릭 ───
FINAL_DURATION=$(($(date +%s) - START_TS))
metric_record_success "$DUMP_SIZE" "$FINAL_DURATION" "$OBJECT_KEY"
log "[OK] $OBJECT_KEY uploaded ($DUMP_SIZE bytes, ${FINAL_DURATION}s)"
notify_slack SUCCESS "백업 완료 object_key=$OBJECT_KEY size=${DUMP_SIZE}B ${FINAL_DURATION}s"

# 저장소 사용량 2단계 경고 (실패해도 백업 자체는 성공이므로 종료코드에 영향 없음)
check_storage_threshold || log "[storage] 임계 확인 실패 (계속 진행)"
exit 0
