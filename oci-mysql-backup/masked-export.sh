#!/usr/bin/env bash
# ============================================================
# masked-export.sh — 최신 원본 DR → 새 컨테이너 적재 → 마스킹 → 버킷 업로드 (트러스트 존 전용)
# ============================================================
# 무옵션 고정 파이프라인:
#   [1/4] 새 MySQL 컨테이너 생성(기존 있으면 제거 후 재생성)
#   [2/4] 버킷의 최신 원본 DR(sql.gz, masked/ 제외) 다운로드·sha256 검증·적재
#   [3/4] pii_classification 기준 마스킹(HASH/FAKE/REDACT, SAFE 원본 유지, 미분류=REDACT)
#   [4/4] 마스킹 덤프 → OCI 버킷 masked/ prefix 업로드(+ .sha256)
#   종료 시(성공·실패 무관) 컨테이너 docker rm -f 로 정리 → 원본 PII 남은 컨테이너 잔존 방지
# ⚠️ 원본(비마스킹) PII 를 로컬에 내려받으므로 원본 접근 허용 구역(트러스트 존)에서만 실행.
# 설정은 아래 상수로만 바꾼다(CLI 옵션 없음).
# 종료 코드: 0 성공 / 1 docker·oci 부재 / 12 다운로드·적재·마스킹·덤프·업로드 오류
set -uo pipefail

# ── 고정 설정 ──
CONTAINER="local-mysql-prod"
DB="qaskerdb"
ROOT_PWD="password"
PORT="3307"
SALT="qasker-mask-v1"                 # 고정 솔트 → 결정적(재현·FK 정합)
DOCKER_IMAGE="mysql:8.0"
BUCKET="qasker-mysql-backup"
DR_PROFILE="BACKUP_READER"            # DR 원본 읽기
OCI_PROFILE="BACKUP_WRITER"           # 마스킹본 업로드
MASKED_PREFIX="masked/"
EXCLUDE="'flyway_schema_history','pii_classification'"   # 복제/마스킹 제외(메타)
WORK_DIR="/tmp"
OUT="/tmp/masked-$(date +%Y%m%dT%H%M%SZ).sql.gz"

log()    { echo "[$(date -u +%H:%M:%SZ)] $*"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
mquery() { docker exec "$CONTAINER" mysql -uroot -p"$ROOT_PWD" "$DB" -N -e "$1" 2>/dev/null; }
# 성공·실패 무관 종료 시 정리: 임시 디렉터리 + 컨테이너 제거(원본 PII 남은 채 컨테이너 잔존 방지)
cleanup() { [ -n "${RDIR:-}" ] && rm -rf "$RDIR"; docker rm -f "$CONTAINER" >/dev/null 2>&1 && log "정리: $CONTAINER 제거"; }

command -v docker >/dev/null || { log "[ERR] docker 없음"; exit 1; }
command -v oci    >/dev/null || { log "[ERR] oci CLI 없음"; exit 1; }

# ── [1/4] 새 MySQL 컨테이너 ──
log "[1/4] 새 컨테이너 생성: $CONTAINER (image=$DOCKER_IMAGE, port=$PORT)"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -e MYSQL_ROOT_PASSWORD="$ROOT_PWD" -p "$PORT:3306" "$DOCKER_IMAGE" >/dev/null \
  || { log "[ERR] docker run 실패"; exit 12; }
trap cleanup EXIT   # 이 지점 이후 종료는 성공·실패 무관 컨테이너 정리
rdy=0
for _ in $(seq 1 40); do
  docker exec "$CONTAINER" mysql -uroot -p"$ROOT_PWD" -N -e "SELECT 1" >/dev/null 2>&1 && { rdy=1; break; }
  sleep 2
done
[ "$rdy" = 1 ] || { log "[ERR] mysqld ready 실패"; exit 12; }

# ── [2/4] 최신 원본 DR 적재 ──
log "[2/4] 최신 DR 조회(sql.gz, masked/ 제외, profile=$DR_PROFILE)..."
DR_KEY="$(oci --profile "$DR_PROFILE" os object list -bn "$BUCKET" --all \
  --query 'sort_by(data,&name)[?ends_with(name,`sql.gz`) && !starts_with(name,`masked/`)]|[-1].name' \
  --raw-output 2>/dev/null)"
[ -n "$DR_KEY" ] && [ "$DR_KEY" != "null" ] || { log "[ERR] DR 백업 없음"; exit 12; }
log "[2/4] 선택: $DR_KEY"
RDIR="$(mktemp -d "$WORK_DIR/masked-export-dr.XXXXXX")"
DR_DUMP="$RDIR/dr.sql.gz"; DR_SHA="$RDIR/dr.sha256"
oci --profile "$DR_PROFILE" os object get -bn "$BUCKET" --name "$DR_KEY" --file "$DR_DUMP" >/dev/null 2>&1 \
  || { log "[ERR] DR 다운로드 실패"; exit 12; }
if oci --profile "$DR_PROFILE" os object get -bn "$BUCKET" --name "${DR_KEY%.sql.gz}.sha256" --file "$DR_SHA" >/dev/null 2>&1; then
  [ "$(awk '{print $1}' "$DR_SHA")" = "$(sha256 "$DR_DUMP" | awk '{print $1}')" ] || { log "[ERR] sha256 불일치"; exit 12; }
  log "[2/4] sha256 OK"
fi
docker exec "$CONTAINER" mysql -uroot -p"$ROOT_PWD" \
  -e "CREATE DATABASE IF NOT EXISTS \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
gzip -dc "$DR_DUMP" | docker exec -i "$CONTAINER" mysql -uroot -p"$ROOT_PWD" "$DB" 2>/dev/null \
  || { log "[ERR] DR 적재 실패"; exit 12; }
[ -n "$(mquery "SELECT 1 FROM information_schema.tables WHERE table_schema='$DB' AND table_name='pii_classification'")" ] \
  || { log "[ERR] $DB.pii_classification 없음 — DR 이 오래됨(재백업 필요)"; exit 12; }
log "[2/4] DR 적재 완료"

# ── [3/4] 마스킹 (분류표 + information_schema, SAFE 제외, 미분류=REDACT) ──
SQL="$(mquery "
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
  done)"
log "[3/4] 마스킹 적용 ($(echo "$SQL" | grep -c UPDATE) UPDATE, salt 고정)"
# stderr 를 캡처해 실패 시 실제 MySQL 에러(어느 컬럼/문장인지)를 그대로 출력
apply_err="$(printf 'SET foreign_key_checks=0;\n%s\n' "$SQL" \
  | docker exec -i "$CONTAINER" mysql -uroot -p"$ROOT_PWD" "$DB" 2>&1 1>/dev/null)" \
  || { log "[ERR] 마스킹 적용 실패:"; echo "$apply_err" | sed 's/^/    /' >&2; exit 12; }

# ── [4/4] 덤프 + 업로드 ──
log "[4/4] mysqldump → $OUT (pii_classification 제외)"
docker exec "$CONTAINER" mysqldump -uroot -p"$ROOT_PWD" --single-transaction --no-tablespaces \
  --ignore-table="$DB.pii_classification" "$DB" 2>/dev/null | gzip > "$OUT" \
  || { log "[ERR] 덤프 실패"; exit 12; }
NOW_UTC="$(date -u +%Y%m%dT%H%M%SZ)"; DATE_PREFIX="$(date -u +%Y/%m/%d)"
OBJECT_KEY="${MASKED_PREFIX%/}/${DATE_PREFIX}/qasker-masked-${NOW_UTC}.sql.gz"
SHA_FILE="${OUT%.sql.gz}.sha256"; sha256 "$OUT" | awk '{print $1}' > "$SHA_FILE"
log "[4/4] 업로드 → $BUCKET/$OBJECT_KEY (profile=$OCI_PROFILE)"
oci --profile "$OCI_PROFILE" os object put -bn "$BUCKET" --name "$OBJECT_KEY" --file "$OUT" --force >/dev/null 2>&1 \
  || { log "[ERR] 덤프 업로드 실패"; exit 12; }
oci --profile "$OCI_PROFILE" os object put -bn "$BUCKET" --name "${OBJECT_KEY%.sql.gz}.sha256" --file "$SHA_FILE" --force >/dev/null 2>&1 \
  || { log "[ERR] sha256 업로드 실패"; exit 12; }
log "✅ 완료: $OBJECT_KEY (+ .sha256)"
