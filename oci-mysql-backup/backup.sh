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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# lib source
# shellcheck source=lib/metrics.sh
source "$SCRIPT_DIR/lib/metrics.sh"
# shellcheck source=lib/metadata.sh
source "$SCRIPT_DIR/lib/metadata.sh"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
fail() {
  local stage="$1" code="$2"
  log "[FAIL] stage=$stage exit=$code"
  metric_increment_fail
  exit "$code"
}

# sha256sum(GNU/coreutils) 또는 shasum -a 256(macOS/BSD) 이식성 래퍼.
# 둘 다 "<hash>  <path>" 형식으로 출력하므로 downstream awk '{print $1}' 호환.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
  else shasum -a 256 "$@"; fi
}

# ─── 사전 검증 ───
for cmd in flock mysqldump mysql jq oci; do
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
exit 0
