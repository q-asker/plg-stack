#!/usr/bin/env bash
# ============================================================
# T8: OCI Object Storage → 격리 Docker 컨테이너 복구 스크립트
# ============================================================
# 동작 (spec FR-007 단일 명령):
#   1. flock으로 백업/복구/GameDay 직렬화
#   2. BACKUP_READER로 3종 객체 다운로드 (.sql.gz, .meta.json, .sha256)
#   3. sha256 검증 (실패 시 격리 환경 진입 전 중단)
#   4. Docker mysql 컨테이너 생성 (시각 기반 유니크 이름, FR-020)
#   5. dump 적재
#   6. T7 healthcheck.sh 호출
#   7. RTO 측정 (헬스체크 PASS 시점, FR-019)
#   8. 격리 컨테이너 자동 삭제 X (FR-020, 운영자 수동 정리)
#
# 종료 코드:
#   0   PASS (헬스체크 통과, RTO 기록)
#   1   사용법·환경변수 오류
#   3   sha256 불일치 (운영 무영향)
#   4   OCI 다운로드 실패
#   6   백업 객체 없음 (--latest 조회 실패)
#   10  헬스체크 FAIL
#   12  Docker 컨테이너 생성·pull·healthy 실패
#   13  dump 적재 실패
#   14  healthcheck 스크립트 없음
#
# 사용법:
#   restore.sh <OBJECT_KEY> [--env docker|schema]
#   restore.sh --latest [--env docker|schema]
#   restore.sh --list

set -uo pipefail

: "${BUCKET:=qasker-mysql-backup}"
: "${OCI_PROFILE:=BACKUP_READER}"
: "${OCI_CLI_CONFIG_FILE:=/var/lib/oci-mysql-backup/.oci/config}"
: "${LOCK_FILE:=/var/lock/oci-mysql-backup.lock}"
: "${WORK_BASE_DIR:=/tmp}"
: "${BASELINE_FILE:=/etc/oci-mysql-backup/healthcheck.baseline.yml}"
: "${HEALTHCHECK_SCRIPT:=/opt/oci-mysql-backup/healthcheck.sh}"
: "${DOCKER_IMAGE:=mysql:8.0}"

# OCI CLI가 sudo·root 환경에서도 시스템 사용자의 config를 쓰도록 강제
export OCI_CLI_CONFIG_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/metrics.sh
source "$SCRIPT_DIR/lib/metrics.sh"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
fail() {
  local stage="$1" code="$2"
  log "[FAIL] stage=$stage exit=$code"
  exit "$code"
}

# sha256sum(GNU/coreutils) 또는 shasum -a 256(macOS/BSD) 이식성 래퍼.
# 둘 다 "<hash>  <path>" 형식으로 출력하므로 downstream awk '{print $1}' 호환.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
  else shasum -a 256 "$@"; fi
}

usage() {
  cat <<EOF
사용법:
  $0 <OBJECT_KEY> [--env docker|schema]
  $0 --latest [--env docker|schema]
  $0 --list

OBJECT_KEY 예:
  2026/07/01/qasker-mysql-20260701T134701Z.sql.gz

옵션:
  --env docker   (기본) Docker mysql 컨테이너에 복구
  --env schema   원본 서버에 격리 스키마로 복구 (spec 대안, 미구현)
  --latest       버킷의 가장 최근 백업 자동 선택
  --list         사용 가능한 백업 목록만 표시 후 종료
  -h, --help     사용법 표시

환경변수:
  BUCKET(기본 qasker-mysql-backup), OCI_PROFILE(기본 BACKUP_READER),
  DOCKER_IMAGE(기본 mysql:8.0), BASELINE_FILE, HEALTHCHECK_SCRIPT
EOF
}

# ─── 인자 파싱 ───
OBJECT_KEY=""
ENV_TYPE="docker"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_TYPE="$2"; shift 2 ;;
    --latest) OBJECT_KEY="__LATEST__"; shift ;;
    --list)
      oci --profile "$OCI_PROFILE" os object list -bn "$BUCKET" \
        --query 'data[?ends_with(name,`sql.gz`)].name' --output table
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) OBJECT_KEY="$1"; shift ;;
  esac
done

[[ -z "$OBJECT_KEY" ]] && { usage; exit 1; }
if [[ "$ENV_TYPE" != "docker" ]]; then
  log "[ERR] --env schema는 미구현 (docker만 지원). spec 대안 방식은 향후 확장 여지."
  exit 1
fi

# ─── 사전 검증 ───
for cmd in flock oci jq mysql docker; do
  command -v "$cmd" >/dev/null || { log "[ERR] $cmd 미설치"; exit 1; }
done

# ─── flock 획득 (FR-017, backup과 공유) ───
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  log "[SKIP] lock $LOCK_FILE held by another process (backup/restore/gameday)"
  metric_increment_skip
  exit 0
fi

# ─── --latest 해석 ───
if [[ "$OBJECT_KEY" == "__LATEST__" ]]; then
  log "[INFO] --latest: 가장 최근 sql.gz 조회..."
  OBJECT_KEY=$(oci --profile "$OCI_PROFILE" os object list -bn "$BUCKET" \
    --query 'sort_by(data,&"time-created")[?ends_with(name,`sql.gz`)]|[-1].name' \
    --raw-output 2>/dev/null)
  if [[ -z "$OBJECT_KEY" || "$OBJECT_KEY" == "null" ]]; then
    fail "no-backup" 6
  fi
  log "[INFO] 선택: $OBJECT_KEY"
fi

# ─── 파생 키 계산 ───
META_KEY="${OBJECT_KEY%.sql.gz}.meta.json"
SHA_KEY="${OBJECT_KEY%.sql.gz}.sha256"

# ─── 작업 디렉터리 ───
WORK_DIR=$(mktemp -d "$WORK_BASE_DIR/oci-mysql-restore.XXXXXX")
DUMP_FILE="$WORK_DIR/dump.sql.gz"
META_FILE="$WORK_DIR/meta.json"
SHA_FILE="$WORK_DIR/dump.sha256"

# trap: 실패해도 컨테이너는 유지(FR-020), 임시 디렉터리만 정리
cleanup_temp() { rm -rf "$WORK_DIR"; }
trap cleanup_temp EXIT

# ─── RTO 측정 시작 ───
START_TS=$(date +%s)

# 컨테이너 이름 규칙: mysql-restore-<백업시각>-<unix_ts>
BASENAME=$(basename "$OBJECT_KEY")
BACKUP_TS=$(echo "$BASENAME" | sed -n 's/^qasker-mysql-\([0-9TZ]*\)\.sql\.gz$/\1/p')
[[ -z "$BACKUP_TS" ]] && BACKUP_TS="unknown"
UNIX_TS=$(date +%s)
CONTAINER_NAME="mysql-restore-${BACKUP_TS}-${UNIX_TS}"
ROOT_PWD="password"

log "[START] object_key=$OBJECT_KEY container=$CONTAINER_NAME"

# ─── Step 1: 다운로드 (3종) ───
log "[step 1/5] downloading dump + meta + sha256..."
download() {
  local key="$1" file="$2"
  oci --profile "$OCI_PROFILE" os object get \
    --bucket-name "$BUCKET" \
    --name "$key" \
    --file "$file" \
    >/dev/null 2>"$WORK_DIR/download.err"
}
download "$SHA_KEY" "$SHA_FILE" || { log "[ERR] $(cat "$WORK_DIR/download.err")"; fail "download-sha" 4; }
download "$META_KEY" "$META_FILE" || { log "[ERR] $(cat "$WORK_DIR/download.err")"; fail "download-meta" 4; }
download "$OBJECT_KEY" "$DUMP_FILE" || { log "[ERR] $(cat "$WORK_DIR/download.err")"; fail "download-dump" 4; }
log "[step 1/5] downloaded"

# ─── Step 2: sha256 검증 (운영 무영향 검증) ───
log "[step 2/5] verifying sha256..."
EXPECTED_SHA=$(cat "$SHA_FILE")
ACTUAL_SHA=$(sha256 "$DUMP_FILE" | awk '{print $1}')

if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
  log "[FAIL] checksum mismatch"
  log "       expected=$EXPECTED_SHA"
  log "       actual  =$ACTUAL_SHA"
  log "       (운영 인스턴스는 어떤 변경도 적용되지 않음)"
  fail "sha-mismatch" 3
fi
log "[step 2/5] sha256 OK"

# ─── Step 3: Docker 격리 컨테이너 생성 ───
log "[step 3/5] starting isolated container ($DOCKER_IMAGE)..."

# 이미지 없으면 pull (RTO에서 pull 시간은 START_TS 보정하여 제외)
if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
  log "[WARN] docker image 미캐시, pull 중... (RTO 산정에서 제외 대상)"
  PULL_START=$(date +%s)
  if ! docker pull "$DOCKER_IMAGE" >/dev/null 2>"$WORK_DIR/pull.err"; then
    log "[ERR] $(cat "$WORK_DIR/pull.err")"
    fail "docker-pull" 12
  fi
  PULL_DUR=$(($(date +%s) - PULL_START))
  START_TS=$((START_TS + PULL_DUR))
  log "[WARN] pull 완료 ${PULL_DUR}s, START_TS 보정"
fi

if ! docker run -d \
     --name "$CONTAINER_NAME" \
     -e "MYSQL_ROOT_PASSWORD=$ROOT_PWD" \
     -e "MYSQL_ROOT_HOST=%" \
     -e "MYSQL_DATABASE=qaskerdb" \
     -p 55000:3306 \
     --health-cmd="mysqladmin ping -uroot -p$ROOT_PWD --silent" \
     --health-interval=3s \
     --health-timeout=2s \
     --health-retries=30 \
     "$DOCKER_IMAGE" >/dev/null 2>"$WORK_DIR/docker.err"; then
  log "[ERR] $(cat "$WORK_DIR/docker.err")"
  fail "docker-run" 12
fi

# healthy 대기 (최대 90초)
log "[step 3/5] container=$CONTAINER_NAME, waiting for healthy..."
STATUS="unknown"
for _ in $(seq 1 30); do
  STATUS=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
  [[ "$STATUS" == "healthy" ]] && break
  sleep 3
done

if [[ "$STATUS" != "healthy" ]]; then
  log "[FAIL] container not healthy after 90s (status=$STATUS)"
  log "       container 보존: $CONTAINER_NAME (docker logs $CONTAINER_NAME 로 진단)"
  fail "container-unhealthy" 12
fi

# 호스트 포트 조회
HOST_PORT=$(docker port "$CONTAINER_NAME" 3306 | awk -F: '{print $NF}' | head -1)
log "[step 3/5] container healthy, host_port=$HOST_PORT"

# 호스트에서 TCP 접속 준비 대기 (mysqld가 소켓은 열었지만 TCP는 조금 늦음)
log "[step 3/5] waiting for TCP port readiness..."
for _ in $(seq 1 30); do
  if MYSQL_PWD="$ROOT_PWD" mysqladmin -h 127.0.0.1 -P "$HOST_PORT" --protocol=tcp -uroot ping --silent 2>/dev/null; then
    log "[step 3/5] TCP ready"
    break
  fi
  sleep 1
done

# ─── Step 4: dump 적재 ───
log "[step 4/5] loading dump.sql.gz..."
LOAD_START=$(date +%s)
if ! gzip -dc "$DUMP_FILE" | MYSQL_PWD="$ROOT_PWD" mysql \
     -h 127.0.0.1 -P "$HOST_PORT" --protocol=tcp -uroot qaskerdb 2>"$WORK_DIR/load.err"; then
  log "[FAIL] dump load failed"
  cat "$WORK_DIR/load.err" >&2
  log "       container 보존: $CONTAINER_NAME"
  fail "dump-load" 13
fi
LOAD_DUR=$(($(date +%s) - LOAD_START))
log "[step 4/5] dump loaded (${LOAD_DUR}s)"

# ─── Step 5: 헬스체크 (T7) ───
log "[step 5/5] running healthcheck (T7)..."
if [[ ! -x "$HEALTHCHECK_SCRIPT" ]]; then
  fail "healthcheck-not-found" 14
fi

set +e
HC_OUTPUT=$(RESTORED_HOST=127.0.0.1 \
  RESTORED_PORT="$HOST_PORT" \
  RESTORED_USER=root \
  RESTORED_PASSWORD="$ROOT_PWD" \
  RESTORED_DATABASE=qaskerdb \
  META_FILE="$META_FILE" \
  BASELINE_FILE="$BASELINE_FILE" \
  "$HEALTHCHECK_SCRIPT" 2>&1)
HC_EXIT=$?
set -e

# 결과 파일 보존 (GameDay 기록 첨부용)
HC_RESULT_FILE="/tmp/healthcheck-${CONTAINER_NAME}.json"
echo "$HC_OUTPUT" > "$HC_RESULT_FILE"

echo "──── healthcheck 결과 ────"
echo "$HC_OUTPUT" | jq . 2>/dev/null || echo "$HC_OUTPUT"
echo "──────────────────────"

if [[ $HC_EXIT -ne 0 ]]; then
  END_TS=$(date +%s)
  RTO_FAIL=$((END_TS - START_TS))
  log "[FAIL] healthcheck FAIL (exit=$HC_EXIT, elapsed=${RTO_FAIL}s)"
  log "       container 보존: $CONTAINER_NAME"
  log "       결과 파일: $HC_RESULT_FILE"
  fail "healthcheck-fail" 10
fi

# ─── RTO 종료 (헬스체크 PASS 시점, FR-019) ───
END_TS=$(date +%s)
RTO=$((END_TS - START_TS))

DUMP_SIZE=$(stat -c%s "$DUMP_FILE" 2>/dev/null || stat -f%z "$DUMP_FILE")

log ""
log "═══════════════ 복구 완료 ═══════════════"
log "  object_key:   $OBJECT_KEY"
log "  container:    $CONTAINER_NAME"
log "  host_port:    $HOST_PORT"
log "  dump_size:    ${DUMP_SIZE} bytes"
log "  load_time:    ${LOAD_DUR}s"
log "  RTO:          ${RTO}s  (SC-001 target ≤ 900s = 15분)"
log "  healthcheck:  PASS"
log "  hc_result:    $HC_RESULT_FILE"
log ""
log "▶ 격리 컨테이너는 유지됨 (FR-020). 분석 후 수동 정리:"
log "    docker rm -f $CONTAINER_NAME"
log ""

exit 0
