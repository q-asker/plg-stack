#!/usr/bin/env bash
# ============================================================
# masked-export.sh — 분석용 "마스킹된 export" 생성 (트러스트 존 전용)
# ============================================================
# backup.sh(DR, 원본) 와 별개. DR 백업을 훼손하지 않는다.
# 흐름(트러스트 존 = 원본 접근 허용 구역에서 실행):
#   1. (사전) staging 컨테이너에 DR 백업이 적재돼 있어야 함 — restore.sh/restore-local.sh 재사용
#   2. pii_classification + information_schema 를 조인해 컬럼별 마스킹 SQL 생성·적용
#      · HASH: 결정적 해시(같은 값→같은 해시, FK 정합) · FAKE: 가짜값 · REDACT/DROP: 원문 제거
#      · deny-by-default: 분류표에 없는 컬럼은 기본 마스킹(REDACT), SAFE 만 원본 유지
#   3. 마스킹된 staging 을 mysqldump → masked.sql.gz (분석용, 개발자 반입 허용)
# 개발자는 이후 restore-local.sh 로 이 마스킹본만 받는다(원본 PII 미도달).
#
# 사용법:
#   ./masked-export.sh --container=local-mysql-prod [--db=qaskerdb] [--root-pwd=password]
#                      [--salt=<고정 솔트>] [--out=/tmp/masked.sql.gz]
#                      [--check-only] [--dry-run]
#   --check-only : 커버리지 가드만(미분류 컬럼 있으면 실패). CI 용.
#   --dry-run    : 생성될 마스킹 SQL 미리보기(적용·덤프 안 함).
#
# 종료 코드: 0 성공 / 1 인자오류 / 2 미분류 컬럼(커버리지 실패) / 12 docker·덤프 오류
set -uo pipefail

CONTAINER="local-mysql-prod"
DB="qaskerdb"
ROOT_PWD="password"
SALT="${MASK_SALT:-qasker-mask-v1}"   # 고정 솔트 → 결정적(재현·FK 정합). 운영은 시크릿으로 주입 권장.
OUT="/tmp/masked-$(date +%Y%m%dT%H%M%SZ).sql.gz"
CHECK_ONLY=0
DRY_RUN=0
EXCLUDE="'flyway_schema_history','pii_classification'"   # 복제/마스킹 제외(메타)

usage() { grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

while (( $# > 0 )); do
  case "$1" in
    --container=*) CONTAINER="${1#--container=}" ;;
    --db=*)        DB="${1#--db=}" ;;
    --root-pwd=*)  ROOT_PWD="${1#--root-pwd=}" ;;
    --salt=*)      SALT="${1#--salt=}" ;;
    --out=*)       OUT="${1#--out=}" ;;
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

# pii_classification 존재 확인
if [ -z "$(mquery "SELECT 1 FROM information_schema.tables WHERE table_schema='$DB' AND table_name='pii_classification'")" ]; then
  log "[ERR] $DB.pii_classification 없음 — V15 마이그레이션 미적용?"; exit 1
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
log "   개발자는 restore-local.sh 로 이 파일(마스킹본)만 반입."
