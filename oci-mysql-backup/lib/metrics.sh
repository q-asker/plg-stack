#!/usr/bin/env bash
# ============================================================
# Prometheus textfile 메트릭 + 누적 카운터 state 관리
# ============================================================
# 사용: backup.sh / restore.sh / GameDay 모두 동일 함수 공유.
#
# state.json 스키마:
#   {
#     "fail_total":        누적 실패 횟수,
#     "skip_total":        누적 스킵 횟수 (락 점유),
#     "last_success_ts":   마지막 성공 unix timestamp,
#     "last_duration":     마지막 성공 소요시간(초),
#     "last_size":         마지막 성공 dump 크기(bytes),
#     "last_object_key":   마지막 업로드 객체 키
#   }

: "${STATE_FILE:=/var/lib/oci-mysql-backup/state.json}"
: "${METRIC_FILE:=/var/lib/node_exporter/textfile_collector/oci_mysql_backup.prom}"

_state_init() {
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
  if [[ ! -f "$STATE_FILE" ]]; then
    cat > "$STATE_FILE" <<'JSON'
{
  "fail_total": 0,
  "skip_total": 0,
  "last_success_ts": 0,
  "last_duration": 0,
  "last_size": 0,
  "last_object_key": ""
}
JSON
  fi
}

_state_read() {
  _state_init
  cat "$STATE_FILE"
}

_state_write() {
  # stdin → STATE_FILE (atomic via temp + rename)
  local tmp="${STATE_FILE}.tmp.$$"
  cat > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

metric_increment_fail() {
  _state_read | jq '.fail_total += 1' | _state_write
  metric_flush
}

metric_increment_skip() {
  _state_read | jq '.skip_total += 1' | _state_write
  metric_flush
}

metric_record_success() {
  # $1=size_bytes  $2=duration_seconds  $3=object_key
  local size="$1" dur="$2" key="$3"
  local ts
  ts=$(date +%s)
  _state_read | jq \
    --argjson ts "$ts" \
    --argjson size "$size" \
    --argjson dur "$dur" \
    --arg key "$key" \
    '.last_success_ts = $ts | .last_size = $size | .last_duration = $dur | .last_object_key = $key' \
    | _state_write
  metric_flush
}

metric_flush() {
  # state.json → Prometheus textfile (atomic via temp + rename)
  mkdir -p "$(dirname "$METRIC_FILE")" 2>/dev/null || true
  local state
  state=$(_state_read)
  local fail_total skip_total last_success_ts last_duration last_size last_object_key
  fail_total=$(echo "$state" | jq -r '.fail_total')
  skip_total=$(echo "$state" | jq -r '.skip_total')
  last_success_ts=$(echo "$state" | jq -r '.last_success_ts')
  last_duration=$(echo "$state" | jq -r '.last_duration')
  last_size=$(echo "$state" | jq -r '.last_size')
  last_object_key=$(echo "$state" | jq -r '.last_object_key')

  local tmp="${METRIC_FILE}.tmp.$$"
  cat > "$tmp" <<EOF
# HELP oci_mysql_backup_fail_total Cumulative L2 backup failures
# TYPE oci_mysql_backup_fail_total counter
oci_mysql_backup_fail_total $fail_total
# HELP oci_mysql_backup_skip_total Cumulative L2 backup skips (flock held by another process)
# TYPE oci_mysql_backup_skip_total counter
oci_mysql_backup_skip_total $skip_total
# HELP oci_mysql_backup_last_success_timestamp_seconds Last successful backup completion (unix seconds)
# TYPE oci_mysql_backup_last_success_timestamp_seconds gauge
oci_mysql_backup_last_success_timestamp_seconds $last_success_ts
# HELP oci_mysql_backup_last_duration_seconds Duration of last successful backup
# TYPE oci_mysql_backup_last_duration_seconds gauge
oci_mysql_backup_last_duration_seconds $last_duration
# HELP oci_mysql_backup_last_size_bytes Compressed size of last successful backup
# TYPE oci_mysql_backup_last_size_bytes gauge
oci_mysql_backup_last_size_bytes $last_size
# HELP oci_mysql_backup_last_object_info Last uploaded object key (label only)
# TYPE oci_mysql_backup_last_object_info gauge
oci_mysql_backup_last_object_info{key="$last_object_key"} 1
EOF
  mv "$tmp" "$METRIC_FILE"
}
