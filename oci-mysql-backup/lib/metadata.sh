#!/usr/bin/env bash
# ============================================================
# 백업 객체 메타데이터 수집·생성·머지 (FR-003)
# ============================================================
# 메타데이터 필드:
#   schemas, tables, approx_row_count,
#   source_id (DB host), source_host (적재 호스트), dump_tool_version,
#   created_at, size_bytes, sha256, duration_seconds, object_key
#
# 사용 환경변수:
#   MYSQL_HOST, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DATABASE, MYSQL_PORT,
#   MYSQL_CNF (mysql --defaults-extra-file 경로, password CLI 노출 회피용)

# system schema 제외 목록
_SYS_SCHEMAS="'mysql','information_schema','performance_schema','sys'"

# mysql 클라이언트 호출 헬퍼 (cnf 파일이 있으면 사용)
_mysql_query() {
  local sql="$1"
  if [[ -n "${MYSQL_CNF:-}" ]]; then
    mysql --defaults-extra-file="$MYSQL_CNF" -h "$MYSQL_HOST" -P "${MYSQL_PORT:-3306}" -B -N -e "$sql"
  else
    MYSQL_PWD="$MYSQL_PASSWORD" mysql -h "$MYSQL_HOST" -P "${MYSQL_PORT:-3306}" -u "$MYSQL_USER" -B -N -e "$sql"
  fi
}

# 적재 직전에 호출. DB 메타데이터를 수집해 JSON으로 stdout 출력.
collect_metadata() {
  local schemas tables row_counts dump_tool created_at db_tables
  # 원본 서버 전체 관점 (감사·통계용)
  schemas=$(_mysql_query "SELECT COUNT(DISTINCT table_schema) FROM information_schema.tables WHERE table_schema NOT IN ($_SYS_SCHEMAS);")
  tables=$(_mysql_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ($_SYS_SCHEMAS);")
  row_counts=$(_mysql_query "SELECT COALESCE(SUM(table_rows), 0) FROM information_schema.tables WHERE table_schema NOT IN ($_SYS_SCHEMAS);")
  # 백업 대상 DB(qaskerdb) 관점 (헬스체크 기대값)
  db_tables=$(_mysql_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${MYSQL_DATABASE}';")
  dump_tool=$(mysqldump --version 2>/dev/null | head -1)
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  jq -n \
    --argjson schemas "${schemas:-0}" \
    --argjson tables "${tables:-0}" \
    --argjson db_tables "${db_tables:-0}" \
    --argjson rows "${row_counts:-0}" \
    --arg source_id "${MYSQL_HOST}:${MYSQL_PORT:-3306}/${MYSQL_DATABASE}" \
    --arg source_host "$(hostname)" \
    --arg source_database "${MYSQL_DATABASE}" \
    --arg dump_tool "$dump_tool" \
    --arg created_at "$created_at" \
    '{
      schemas: $schemas,
      tables: $tables,
      database_tables: $db_tables,
      approx_row_count: $rows,
      source_id: $source_id,
      source_host: $source_host,
      source_database: $source_database,
      dump_tool_version: $dump_tool,
      created_at: $created_at
    }'
}

# baseline yml에서 대표 테이블 이름 추출 (JSON in yml)
_baseline_table_names() {
  local baseline_file="${1:-${BASELINE_FILE:-/etc/oci-mysql-backup/healthcheck.baseline.yml}}"
  [[ -f "$baseline_file" ]] || return
  jq -r '.representative_tables[]?.name // empty' "$baseline_file" 2>/dev/null
}

# 대표 테이블별 정확 COUNT(*) → JSON {table_name: count}
# baseline이 없거나 테이블이 없으면 빈 JSON {} 반환.
collect_table_counts() {
  local baseline_file="${1:-${BASELINE_FILE:-/etc/oci-mysql-backup/healthcheck.baseline.yml}}"
  local tables count json_body='{}'

  tables=$(_baseline_table_names "$baseline_file")
  [[ -z "$tables" ]] && { echo '{}'; return; }

  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    count=$(_mysql_query "SELECT COUNT(*) FROM \`${MYSQL_DATABASE}\`.\`${table}\`;" 2>/dev/null || echo 0)
    count=${count:-0}
    json_body=$(echo "$json_body" | jq --arg t "$table" --argjson c "$count" '. + {($t): $c}')
  done <<< "$tables"

  echo "$json_body"
}

# 적재 후 확정 정보 머지: 크기·체크섬·소요시간·객체 키
# $1=meta_file_path  $2=size_bytes  $3=sha256  $4=duration_seconds  $5=object_key
finalize_metadata() {
  local meta_file="$1" size="$2" sha="$3" dur="$4" key="$5"
  local tmp="${meta_file}.tmp.$$"
  jq \
    --argjson size "$size" \
    --arg sha "$sha" \
    --argjson dur "$dur" \
    --arg key "$key" \
    '. + {size_bytes: $size, sha256: $sha, duration_seconds: $dur, object_key: $key}' \
    "$meta_file" > "$tmp"
  mv "$tmp" "$meta_file"
}
