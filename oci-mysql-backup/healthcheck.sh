#!/usr/bin/env bash
# ============================================================
# T7: 복구된 격리 환경 헬스체크 (baseline 기반 구조 확인)
# ============================================================
# 판정 기준: 복원본이 DB로서 성립하는가 —
#   스키마 수(baseline 기대값) + 대표 테이블 존재·비어있지 않음.
#   백업 시점 실측값 대조는 하지 않는다 (무결성 노선: 복원 리허설로 증명).
#
# 사용법 (환경변수 기반):
#   RESTORED_HOST=127.0.0.1 \
#   RESTORED_PORT=3307 \
#   RESTORED_USER=root \
#   RESTORED_PASSWORD=xxx \
#   RESTORED_DATABASE=qaskerdb \
#   BASELINE_FILE=/etc/oci-mysql-backup/healthcheck.baseline.yml \
#   ./healthcheck.sh
#
# 종료 코드:
#   0   PASS (모든 check 통과)
#   10  check FAIL (스키마 수 불일치 / 대표 테이블 부재·비어 있음)
#   11  DB 접속 실패 / baseline 파일 누락
#   1   환경변수 오류
#
# 출력: JSON to stdout
#   {
#     "status": "PASS" | "FAIL",
#     "checks": [
#       {"check": "schemas", "expected": 1, "actual": 1, "status": "PASS"},
#       {"check": "user",    "actual": 1523, "status": "PASS"},
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

# 필수 도구 검증
for cmd in mysql jq; do
  command -v "$cmd" >/dev/null || {
    echo "{\"status\":\"FAIL\",\"reason\":\"$cmd 미설치\"}"
    exit 11
  }
done

# baseline 파일 존재 확인
[[ -f "$BASELINE_FILE" ]] || {
  echo "{\"status\":\"FAIL\",\"reason\":\"baseline 파일 없음: $BASELINE_FILE\"}"
  exit 11
}

BASELINE=$(cat "$BASELINE_FILE")

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

# ─── Check 2+: 대표 테이블 존재 · 비어있지 않음 ───
# 절단된 덤프·부분 적재는 뒷순서 테이블이 통째로 빠지는 형태로 나타나므로,
# 핵심 테이블이 존재하고 row가 1건 이상인지로 구조 성립을 판정한다.
n=$(echo "$BASELINE" | jq -r '.representative_tables | length')
for i in $(seq 0 $((n - 1))); do
  table_name=$(echo "$BASELINE" | jq -r ".representative_tables[$i].name")

  exists=$(_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${RESTORED_DATABASE}' AND table_name = '${table_name}';")
  if [[ "${exists:-0}" -eq 0 ]]; then
    CHECKS+=("$(jq -n \
      --arg t "$table_name" \
      --arg s "FAIL" \
      '{check:$t, status:$s, reason:"테이블 없음"}')")
    continue
  fi

  actual=$(_query "SELECT COUNT(*) FROM \`${RESTORED_DATABASE}\`.\`${table_name}\`;")
  actual=${actual:-0}

  status="PASS"
  [[ "$actual" -eq 0 ]] && status="FAIL"

  CHECKS+=("$(jq -n \
    --arg t "$table_name" \
    --argjson a "$actual" \
    --arg s "$status" \
    '{check:$t, actual:$a, status:$s}')")
done

# ─── 결과 조립 ───
RESULT=$(printf '%s\n' "${CHECKS[@]}" | jq -s .)
overall_status="PASS"
if echo "$RESULT" | jq -e '[.[] | select(.status == "FAIL")] | length > 0' >/dev/null; then
  overall_status="FAIL"
fi

echo "$RESULT" | jq --arg s "$overall_status" '{status:$s, checks:.}'

[[ "$overall_status" == "PASS" ]] && exit 0 || exit 10
