#!/usr/bin/env bash
# =============================================================
# restore-local.sh — OCI Prometheus 스냅샷을 "로컬 Mac Docker" Prometheus에 복원
# (plg-stack: specs/001-prometheus-loki-backup-recovery, 로컬 분석용 보조 도구)
# =============================================================
# restore.sh 는 원격 호스트(/mnt/monitoring/prometheus) 재해복구 전용.
# 이 스크립트는 원격 스냅샷을 개발자 로컬 docker named 볼륨(local_prometheus-data)에
# 풀어넣어, 로컬 Grafana/MCP가 프로덕션 실측(job="integrations/mysql" 등)을 조회하게 한다.
#
# 사용법:
#   ./restore-local.sh --file=/tmp/prom-snap.tar.gz     # 이미 받은 tar 사용
#   ./restore-local.sh --latest                         # OCI에서 최신 자동
#   ./restore-local.sh --snapshot=20260713-1447         # 특정 시점
#   옵션: --bucket=NAME --profile=READER --strip=1 --no-verify --dry-run -h
#
# 흐름:
#   1. tar 확보(--file 그대로 / 아니면 OCI download_object) + sha256 검증
#   2. docker compose stop prometheus
#   3. 볼륨 비우고 스냅샷 추출(--strip-components=N)
#   4. chown 65534:65534 (Prometheus 실행 UID)
#   5. start → health_poll(/-/ready)
#
# 종료 코드: 0 성공 / 2 인자오류 / 3 sha불일치 / 4 다운로드실패 / 10 not ready / 12 docker오류
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/backup-common.sh
source "${SCRIPT_DIR}/lib/backup-common.sh"

# ─── 기본값 ───
COMPOSE_FILE="${COMPOSE_FILE:-$MONITORING_DIR/local/docker-compose.yml}"
SERVICE="prometheus"
CONTAINER="${PROM_CONTAINER:-local-prometheus}"
PROM_URL="${PROM_URL:-http://localhost:9091}"
PROM_UID="${PROM_UID:-65534}"
TMP_DIR="${TMP_DIR:-/tmp}"

# ─── 인자 ───
FILE="" SNAPSHOT="" LATEST=0 DRY_RUN=0 NO_VERIFY=0 STRIP=1
BUCKET="${OCI_BUCKET_NAME:-}"
PROFILE="${OCI_READER_PROFILE:-BACKUP_READER}"

usage() { grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while (( $# > 0 )); do
  case "$1" in
    --file=*)     FILE="${1#--file=}" ;;
    --snapshot=*) SNAPSHOT="${1#--snapshot=}" ;;
    --latest)     LATEST=1 ;;
    --bucket=*)   BUCKET="${1#--bucket=}" ;;
    --profile=*)  PROFILE="${1#--profile=}" ;;
    --strip=*)    STRIP="${1#--strip=}" ;;
    --no-verify)  NO_VERIFY=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)    usage ;;
    *) log ERROR "알 수 없는 옵션: $1"; usage ;;
  esac
  shift
done

# .env(있으면) 로드 → OCI_BUCKET_NAME / OCI_READER_PROFILE 보강
[[ -f "$MONITORING_DIR/.env" ]] && load_env "$MONITORING_DIR" || true
BUCKET="${BUCKET:-${OCI_BUCKET_NAME:-}}"
PROFILE="${PROFILE:-${OCI_READER_PROFILE:-BACKUP_READER}}"

require_cmd docker curl tar

# ─── 1. tar 확보 + 검증 ───
SHA_FILE=""
if [[ -n "$FILE" ]]; then
  [[ -f "$FILE" ]] || { log ERROR "파일 없음: $FILE"; exit 2; }
  TARBALL="$FILE"
  [[ -f "${FILE%.tar.gz}.sha256" ]] && SHA_FILE="${FILE%.tar.gz}.sha256"
  log INFO "로컬 tar 사용: $TARBALL"
else
  require_cmd oci jq
  [[ -n "$BUCKET" ]] || { log ERROR "--bucket 또는 OCI_BUCKET_NAME 필요"; exit 2; }
  key=""
  if (( LATEST )); then
    log INFO "OCI 최신 prometheus 스냅샷 조회 (bucket=$BUCKET)"
    key="$(list_object_keys "$PROFILE" "$BUCKET" "prometheus/" \
          | grep -E 'prometheus\.tar\.gz$' | sort | tail -1)"
  elif [[ -n "$SNAPSHOT" ]]; then
    key="prometheus/${SNAPSHOT}-prometheus.tar.gz"
  else
    log ERROR "--file | --latest | --snapshot 중 하나 필요"; exit 2
  fi
  [[ -n "$key" ]] || { log ERROR "스냅샷 객체를 찾지 못함"; exit 4; }
  log INFO "대상 객체: $key"
  TARBALL="$TMP_DIR/$(basename "$key")"
  SHA_FILE="${TARBALL%.tar.gz}.sha256"
  download_object "$PROFILE" "$BUCKET" "$key"                  "$TARBALL"  || { log ERROR "tar 다운로드 실패"; exit 4; }
  download_object "$PROFILE" "$BUCKET" "${key%.tar.gz}.sha256" "$SHA_FILE" || SHA_FILE=""
fi

if (( ! NO_VERIFY )) && [[ -n "$SHA_FILE" && -f "$SHA_FILE" ]]; then
  verify_local_hash "$TARBALL" "$SHA_FILE" || { log ERROR "sha256 불일치"; exit 3; }
  log INFO "sha256 OK"
else
  log WARN "sha 검증 건너뜀 (--no-verify 또는 .sha256 없음)"
fi

log INFO "tar 최상위 항목: $(tar tzf "$TARBALL" 2>/dev/null | head -1)"

if (( DRY_RUN )); then
  log INFO "[dry-run] 다운로드·검증까지만. 볼륨 변경 없음."
  exit 0
fi

# ─── 볼륨 확인 ───
VOL="$(docker inspect "$CONTAINER" --format '{{ range .Mounts }}{{ if eq .Destination "/prometheus" }}{{ .Name }}{{ end }}{{ end }}' 2>/dev/null || true)"
VOL="${VOL:-local_prometheus-data}"
docker volume inspect "$VOL" >/dev/null 2>&1 || { log ERROR "볼륨 없음: $VOL (먼저 docker compose up -d prometheus)"; exit 12; }
log INFO "복원 대상 볼륨: $VOL"

helper() { docker run --rm -v "$VOL":/prometheus -v "$TMP_DIR":/backup alpine "$@"; }
TARNAME="$(basename "$TARBALL")"

# ─── 2. stop ───
log INFO "docker compose stop $SERVICE"
docker compose -f "$COMPOSE_FILE" stop "$SERVICE" >/dev/null || { log ERROR "stop 실패"; exit 12; }

# ─── 3. 비우고 추출 ───
log INFO "볼륨 비우고 스냅샷 추출 (strip=$STRIP)"
helper sh -c "rm -rf /prometheus/* /prometheus/.[!.]* /prometheus/..?* 2>/dev/null; tar xzf /backup/$TARNAME -C /prometheus --strip-components=$STRIP" \
  || { log ERROR "추출 실패"; exit 12; }

# ─── 4. chown ───
log INFO "chown $PROM_UID:$PROM_UID"
helper chown -R "$PROM_UID:$PROM_UID" /prometheus

# ─── 5. start + health_poll ───
log INFO "docker compose start $SERVICE"
docker compose -f "$COMPOSE_FILE" start "$SERVICE" >/dev/null || { log ERROR "start 실패"; exit 12; }

if health_poll "$PROM_URL/-/ready" 30 2; then
  series="$(curl -s "$PROM_URL/api/v1/query?query=count(mysql_perf_schema_table_io_waits_total)" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo '?')"
  log INFO "✅ 복원 완료 — prometheus ready, table_io 시리즈=$series"
  exit 0
fi

log ERROR "prometheus not ready (원본 tar: $TARBALL)"
exit 10
