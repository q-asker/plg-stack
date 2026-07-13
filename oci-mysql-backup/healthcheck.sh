#!/usr/bin/env bash
# ============================================================
# T7: 복구된 격리 환경 헬스체크 (스키마/테이블/대표 테이블 row 카운트)
# ============================================================
# 사용법 (환경변수 기반):
#   RESTORED_HOST=127.0.0.1 \
#   RESTORED_PORT=3307 \
#   RESTORED_USER=root \
#   RESTORED_PASSWORD=xxx \
#   RESTORED_DATABASE=qaskerdb \
#   META_FILE=/tmp/meta.json \
#   BASELINE_FILE=/etc/oci-mysql-backup/healthcheck.baseline.yml \
#   ./healthcheck.sh
#
# 종료 코드:
#   0   PASS (모든 check 통과)
#   10  count 불일치 (어느 check FAIL)
#   11  DB 접속 실패 / baseline·meta 파일 누락
#   1   환경변수 오류
#
# 출력: JSON to stdout
#   {
#     "status": "PASS" | "FAIL",
#     "checks": [
#       {"check": "schemas",  "expected": 1,  "actual": 1,  "status": "PASS"},
#       {"check": "tables",   "expected": 42, "actual": 42, "status": "PASS"},
#       {"check": "user",     "expected": 100,"actual": 105,"tolerance": 100,"status": "PASS"},
#       ...
#     ]
#   }

set -uo pipefail

: "${RESTORED_HOST:?RESTORED_HOST 필수}"
: "${RESTORED_USER:?RESTORED_USER 필수}"
: "${RESTORED_PASSWORD:?RESTORED_PASSWORD 필수}"
: "${RESTORED_DATABASE:?RESTORED_DATABASE 필수}"

: "${RESTORED_PORT:=3306}"
: "${BASELINE_FILE:=/etc/oci-mysql-backup/healthcheck.baseline.yml}"
: "${META_FILE:?META_FILE 필수 (복구 대상 백업의 meta.json 경로)}"

# 필수 도구 검증
for cmd in mysql jq; do
  command -v "$cmd" >/dev/null || {
    echo "{\"status\":\"FAIL\",\"reason\":\"$cmd 미설치\"}"
    exit 11
  }
done

# baseline·meta 파일 존재 확인
[[ -f "$BASELINE_FILE" ]] || {
  echo "{\"status\":\"FAIL\",\"reason\":\"baseline 파일 없음: $BASELINE_FILE\"}"
  exit 11
}
[[ -f "$META_FILE" ]] || {
  echo "{\"status\":\"FAIL\",\"reason\":\"meta 파일 없음: $META_FILE\"}"
  exit 11
}

BASELINE=$(cat "$BASELINE_FILE")
META=$(cat "$META_FILE")

# MySQL 쿼리 헬퍼 (복구본 접속)
_query() {
  MYSQL_PWD="$RESTORED_PASSWORD" mysql \
    -h "$RESTORED_HOST" -P "$RESTORED_PORT" -u "$RESTORED_USER" \
    -B -N -e "$1" 2>/dev/null
}

# DB 접속 검증
if ! _query "SELECT 1;" >/dev/null; then
  echo "{\"status\":\"FAIL\",\"reason\":\"복구 DB 접속 실패: ${RESTORED_HOST}:${RESTORED_PORT}\"}"
  exit 11
fi

# system schema 제외 목록
_SYS="'mysql','information_schema','performance_schema','sys'"

CHECKS=()

# ─── Check 1: 스키마 수 ───
expected_schemas=$(echo "$BASELINE" | jq -r '.schemas.expected // 1')
schemas_tol=$(echo "$BASELINE" | jq -r '.schemas.tolerance_abs // 0')
actual_schemas=$(_query "SELECT COUNT(DISTINCT table_schema) FROM information_schema.tables WHERE table_schema NOT IN ($_SYS);")
actual_schemas=${actual_schemas:-0}

diff=$((actual_schemas - expected_schemas))
[[ "$diff" -lt 0 ]] && diff=$((-diff))
status="PASS"
[[ "$diff" -gt "$schemas_tol" ]] && status="FAIL"

CHECKS+=("$(jq -n \
  --argjson e "$expected_schemas" \
  --argjson a "$actual_schemas" \
  --argjson tol "$schemas_tol" \
  --arg s "$status" \
  '{check:"schemas", expected:$e, actual:$a, tolerance:$tol, status:$s}')")

# ─── Check 2: 테이블 수 (기대값 = meta.database_tables, 복구본 관점) ───
# meta.database_tables는 백업 대상 DB(qaskerdb) 안의 테이블만 카운트.
# 관리형 스키마(mysql_audit 등)는 mysqldump 대상에서 제외되어 복구본에도 없음.
expected_tables=$(echo "$META" | jq -r '.database_tables // .tables // 0')
tables_tol=$(echo "$BASELINE" | jq -r '.tables.tolerance_abs // 2')
actual_tables=$(_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${RESTORED_DATABASE}';")
actual_tables=${actual_tables:-0}

diff=$((actual_tables - expected_tables))
[[ "$diff" -lt 0 ]] && diff=$((-diff))
status="PASS"
[[ "$diff" -gt "$tables_tol" ]] && status="FAIL"

CHECKS+=("$(jq -n \
  --argjson e "$expected_tables" \
  --argjson a "$actual_tables" \
  --argjson tol "$tables_tol" \
  --arg s "$status" \
  '{check:"tables", expected:$e, actual:$a, tolerance:$tol, status:$s}')")

# ─── Check 3+: 대표 테이블 row 카운트 ───
n=$(echo "$BASELINE" | jq -r '.representative_tables | length')
for i in $(seq 0 $((n - 1))); do
  table_name=$(echo "$BASELINE" | jq -r ".representative_tables[$i].name")
  tol_abs=$(echo "$BASELINE" | jq -r ".representative_tables[$i].tolerance_abs // 0")
  tol_ratio=$(echo "$BASELINE" | jq -r ".representative_tables[$i].tolerance_ratio // 0")

  # meta.json.table_counts에 기대값 있어야 함
  expected=$(echo "$META" | jq -r ".table_counts.\"$table_name\" // \"null\"")
  if [[ "$expected" == "null" ]]; then
    CHECKS+=("$(jq -n \
      --arg t "$table_name" \
      --arg s "SKIP" \
      '{check:$t, status:$s, reason:"meta.json.table_counts에 기대값 없음"}')")
    continue
  fi

  actual=$(_query "SELECT COUNT(*) FROM \`${RESTORED_DATABASE}\`.\`${table_name}\`;")
  actual=${actual:-0}

  diff=$((actual - expected))
  [[ "$diff" -lt 0 ]] && diff=$((-diff))

  # tolerance = max(abs, ratio * expected)
  ratio_tol=$(awk -v e="$expected" -v r="$tol_ratio" 'BEGIN {printf "%.0f\n", e * r}')
  tol=$((tol_abs > ratio_tol ? tol_abs : ratio_tol))

  status="PASS"
  [[ "$diff" -gt "$tol" ]] && status="FAIL"

  CHECKS+=("$(jq -n \
    --arg t "$table_name" \
    --argjson e "$expected" \
    --argjson a "$actual" \
    --argjson tol "$tol" \
    --arg s "$status" \
    '{check:$t, expected:$e, actual:$a, tolerance:$tol, status:$s}')")
done

# ─── 결과 조립 ───
RESULT=$(printf '%s\n' "${CHECKS[@]}" | jq -s .)
overall_status="PASS"
if echo "$RESULT" | jq -e '[.[] | select(.status == "FAIL")] | length > 0' >/dev/null; then
  overall_status="FAIL"
fi

echo "$RESULT" | jq --arg s "$overall_status" '{status:$s, checks:.}'

[[ "$overall_status" == "PASS" ]] && exit 0 || exit 10
