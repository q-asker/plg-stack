#!/usr/bin/env bash
# ============================================================
# masked-export.sh — 분석용 "마스킹된 export" 생성 (트러스트 존 전용)
# ============================================================
# backup.sh(DR, 원본) 와 별개. DR 백업을 훼손하지 않는다.
# 흐름(트러스트 존 = 원본 접근 허용 구역에서 실행):
#   1. (사전) staging 컨테이너에 DR 백업이 적재돼 있어야 함 — restore-local.sh --source=dr 로 원본 적재
#   2. pii_classification + information_schema 를 조인해 컬럼별 마스킹 SQL 생성·적용
#      · HASH: 결정적 해시(같은 값→같은 해시, FK 정합) · FAKE: 가짜값 · REDACT/DROP: 원문 제거
#      · deny-by-default: 분류표에 없는 컬럼은 기본 마스킹(REDACT), SAFE 만 원본 유지
#   3. 마스킹된 staging 을 mysqldump → masked.sql.gz (분석용, 개발자 반입 허용)
# 개발자는 이후 restore-local.sh 로 이 마스킹본만 받는다(원본 PII 미도달).
#
# 사용법:
#   ./masked-export.sh --container=local-mysql-prod [--db=qaskerdb] [--root-pwd=password]
#                      [--salt=<고정 솔트>] [--out=/tmp/masked.sql.gz]
#                      [--no-upload] [--bucket=qasker-mysql-backup] [--oci-profile=BACKUP_WRITER]
#                      [--check-only] [--dry-run]
#   --check-only : 커버리지 가드만(미분류 컬럼 있으면 실패). CI 용.
#   --dry-run    : 생성될 마스킹 SQL 미리보기(적용·덤프 안 함).
#   (기본)       : 마스킹 덤프+sha256 을 OCI 버킷 masked/ prefix 에 업로드
#                  (DR 백업은 YYYY/MM/DD/ 날짜 prefix, 마스킹본은 masked/ prefix 로 경로 분리).
#   --no-upload  : 업로드 생략, 로컬 덤프(--out)만 생성.
#
# 종료 코드: 0 성공 / 1 인자오류 / 2 미분류 컬럼(커버리지 실패) / 12 docker·덤프·업로드 오류
set -uo pipefail

CONTAINER="local-mysql-prod"
DB="qaskerdb"
ROOT_PWD="password"
SALT="${MASK_SALT:-qasker-mask-v1}"   # 고정 솔트 → 결정적(재현·FK 정합). 운영은 시크릿으로 주입 권장.
OUT="/tmp/masked-$(date +%Y%m%dT%H%M%SZ).sql.gz"
CHECK_ONLY=0
DRY_RUN=0
UPLOAD=1
BUCKET="${MASKED_BUCKET:-qasker-mysql-backup}"   # DR 백업과 동일 버킷, prefix 로 격리
OCI_PROFILE="${OCI_PROFILE:-BACKUP_WRITER}"      # 트러스트 존은 WRITER 보유
MASKED_PREFIX="masked/"                          # 개발자 restore-local.sh 기본 소스와 일치
EXCLUDE="'flyway_schema_history','pii_classification'"   # 복제/마스킹 제외(메타)

usage() { grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

# sha256sum(GNU) 또는 shasum -a 256(macOS) 이식성 래퍼
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
  else shasum -a 256 "$@"; fi
}

while (( $# > 0 )); do
  case "$1" in
    --container=*) CONTAINER="${1#--container=}" ;;
    --db=*)        DB="${1#--db=}" ;;
    --root-pwd=*)  ROOT_PWD="${1#--root-pwd=}" ;;
    --salt=*)      SALT="${1#--salt=}" ;;
    --out=*)       OUT="${1#--out=}" ;;
    --upload)      UPLOAD=1 ;;
    --no-upload)   UPLOAD=0 ;;
    --bucket=*)    BUCKET="${1#--bucket=}" ;;
    --oci-profile=*) OCI_PROFILE="${1#--oci-profile=}" ;;
    --check-only)  CHECK_ONLY=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    -h|--help)     usage 0 ;;
    *) log "[ERR] 알 수 없는 옵션: $1"; usage 1 ;;
  esac
  shift
done
command -v docker >/dev/null || { log "[ERR] docker 없음"; exit 1; }

mexec()  { docker exec -i "$CONTAINER" mysql -uroot -p"$ROOT_PWD" "$DB" 2>/dev/null; }
mquery() { docker exec "$CONTAINER" mysql -uroot -p"$ROOT_PWD" "$DB" -N -e "$1" 2>/dev/null; }

# ── 사전 점검: 실패 원인을 단계별로 정확히 진단 ──
# (기존엔 접속·DB 실패까지 전부 "pii_classification 없음"으로 오도됐다)
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" \
  || { log "[ERR] 컨테이너 '$CONTAINER' 실행 중 아님 — restore-local.sh --source=dr --latest 로 staging 먼저 적재"; exit 1; }

docker exec "$CONTAINER" mysql -uroot -p"$ROOT_PWD" -N -e "SELECT 1" >/dev/null 2>&1 \
  || { log "[ERR] '$CONTAINER' 접속 실패 — root 비밀번호(--root-pwd) 확인"; exit 1; }

if [ -z "$(docker exec "$CONTAINER" mysql -uroot -p"$ROOT_PWD" -N -e "SHOW DATABASES LIKE '$DB'" 2>/dev/null)" ]; then
  log "[ERR] '$CONTAINER' 에 DB '$DB' 없음 — restore-local.sh --source=dr --latest 로 최신 DR 적재 먼저"; exit 1
fi

# pii_classification 존재 확인 (여기까지 왔으면 접속·DB 는 정상)
if [ -z "$(mquery "SELECT 1 FROM information_schema.tables WHERE table_schema='$DB' AND table_name='pii_classification'")" ]; then
  log "[ERR] $DB.pii_classification 없음 — 이 staging 이 V14 이전의 오래된 DR 일 수 있음. 최신 DR 재적재 필요."; exit 1
fi

# ── 커버리지 가드: 미분류 컬럼(분류표에 아예 없음) 검출 ──
coverage_check() {
  local missing
  missing="$(mquery "
    SELECT CONCAT(c.table_name,'.',c.column_name)
    FROM information_schema.columns c
    LEFT JOIN pii_classification p ON p.table_name=c.table_name AND p.column_name=c.column_name
    WHERE c.table_schema='$DB' AND c.table_name NOT IN ($EXCLUDE) AND p.strategy IS NULL
    ORDER BY 1")"
  if [ -n "$missing" ]; then
    log "[FAIL] 미분류 컬럼 $(echo "$missing" | wc -l | tr -d ' ')개 (기본 마스킹되나 분류 결정 필요):"
    echo "$missing" | sed 's/^/    /'
    return 2
  fi
  log "[OK] 전 컬럼 분류됨(PII 또는 SAFE)"
  return 0
}

coverage_check; cov=$?
[ "$CHECK_ONLY" = 1 ] && exit $cov
[ "$cov" -ne 0 ] && log "[WARN] 미분류 컬럼은 deny-by-default 로 마스킹됩니다(계속 진행)."

# ── 마스킹 SQL 생성 (분류표 + information_schema, SAFE 제외, 미분류=REDACT) ──
gen_mask_sql() {
  mquery "
    SELECT c.table_name, c.column_name, COALESCE(p.strategy,'REDACT'), c.is_nullable, c.data_type
    FROM information_schema.columns c
    LEFT JOIN pii_classification p ON p.table_name=c.table_name AND p.column_name=c.column_name
    WHERE c.table_schema='$DB' AND c.table_name NOT IN ($EXCLUDE)
      AND COALESCE(p.strategy,'REDACT') <> 'SAFE'
    ORDER BY c.table_name, c.column_name" \
  | while IFS=$'\t' read -r t c s nul dt; do
      case "$s" in
        HASH)  echo "UPDATE \`$t\` SET \`$c\`=CONCAT('h_',SUBSTR(SHA2(CONCAT(\`$c\`,'$SALT'),256),1,32)) WHERE \`$c\` IS NOT NULL;" ;;
        FAKE)  echo "UPDATE \`$t\` SET \`$c\`=CONCAT('u_',SUBSTR(SHA2(CONCAT(\`$c\`,'$SALT'),256),1,10)) WHERE \`$c\` IS NOT NULL;" ;;
        REDACT|DROP)
          if [ "$nul" = "YES" ]; then echo "UPDATE \`$t\` SET \`$c\`=NULL;"
          elif [ "$dt" = "json" ]; then echo "UPDATE \`$t\` SET \`$c\`='{}';"
          else echo "UPDATE \`$t\` SET \`$c\`='';"; fi ;;
      esac
    done
}

SQL="$(gen_mask_sql)"
if [ "$DRY_RUN" = 1 ]; then
  log "=== [dry-run] 마스킹 SQL ($(echo "$SQL" | grep -c UPDATE) UPDATE) ==="
  echo "$SQL"
  exit 0
fi

# ── 마스킹 적용 ──
log "마스킹 적용 ($(echo "$SQL" | grep -c UPDATE) UPDATE, salt 고정)"
printf 'SET foreign_key_checks=0;\n%s\n' "$SQL" | mexec || { log "[ERR] 마스킹 적용 실패"; exit 12; }

# ── 마스킹된 덤프 생성 (분석용) ──
log "mysqldump → $OUT (pii_classification 제외)"
docker exec "$CONTAINER" mysqldump -uroot -p"$ROOT_PWD" --single-transaction --no-tablespaces \
  --ignore-table="$DB.pii_classification" "$DB" 2>/dev/null | gzip > "$OUT" \
  || { log "[ERR] 덤프 실패"; exit 12; }

log "✅ 마스킹 export 완료: $OUT ($(du -h "$OUT" | cut -f1))"

# ── OCI 업로드 (masked/ prefix, DR 백업과 경로 격리) ──
if [ "$UPLOAD" = 1 ]; then
  command -v oci >/dev/null || { log "[ERR] oci CLI 없음 — 업로드 불가"; exit 12; }
  NOW_UTC="$(date -u +%Y%m%dT%H%M%SZ)"
  DATE_PREFIX="$(date -u +%Y/%m/%d)"
  OBJECT_KEY="${MASKED_PREFIX%/}/${DATE_PREFIX}/qasker-masked-${NOW_UTC}.sql.gz"
  SHA_KEY="${OBJECT_KEY%.sql.gz}.sha256"
  SHA_FILE="${OUT%.sql.gz}.sha256"
  sha256 "$OUT" | awk '{print $1}' > "$SHA_FILE"

  log "업로드 → bucket=$BUCKET key=$OBJECT_KEY (profile=$OCI_PROFILE)"
  oci --profile "$OCI_PROFILE" os object put -bn "$BUCKET" --name "$OBJECT_KEY" --file "$OUT" --force >/dev/null 2>&1 \
    || { log "[ERR] 덤프 업로드 실패"; exit 12; }
  oci --profile "$OCI_PROFILE" os object put -bn "$BUCKET" --name "$SHA_KEY" --file "$SHA_FILE" --force >/dev/null 2>&1 \
    || { log "[ERR] sha256 업로드 실패"; exit 12; }
  log "✅ 업로드 완료: $OBJECT_KEY (+ .sha256)"
  log "   개발자: ./restore-local.sh --latest (기본 소스=masked) 로 이 마스킹본을 반입."
else
  log "   --no-upload 라 로컬에만 생성됨. 옵션 없이 실행하면 OCI 업로드까지 자동."
fi
