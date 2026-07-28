#!/usr/bin/env bash
# ============================================================
# T8: OCI Object Storage → 격리 Docker 컨테이너 복구 스크립트
# ============================================================
# 동작 (spec FR-007 단일 명령):
#   1. flock으로 백업/복구/GameDay 직렬화
#   2. BACKUP_READER로 .sql.gz 다운로드
#   3. Docker mysql 컨테이너 생성 (시각 기반 유니크 이름, FR-020)
#   4. dump 적재
#   5. T7 healthcheck.sh 호출 (baseline 기반 구조 확인)
#   6. RTO 측정 (헬스체크 PASS 시점, FR-019)
#   7. (--app-check) 실제 앱 부팅 검증 — 복원 DB에 Spring Boot를 붙여
#      Flyway 이력 검증 + Hibernate ddl-auto:validate(전체 엔티티↔스키마 대조) +
#      actuator/health UP까지 확인. 소비자 관점의 최종 판정.
#   8. 격리 컨테이너 자동 삭제 X (FR-020, 운영자 수동 정리)
#
# 종료 코드:
#   0   PASS (헬스체크 통과, RTO 기록)
#   1   사용법·환경변수 오류
#   4   OCI 다운로드 실패
#   6   백업 객체 없음 (--latest 조회 실패)
#   10  헬스체크 FAIL
#   12  Docker 컨테이너 생성·pull·healthy 실패
#   13  dump 적재 실패
#   14  healthcheck 스크립트 없음
#   15  앱 부팅 검증 FAIL (--app-check)
#
# 사용법:
#   restore.sh <OBJECT_KEY> [--env docker|schema] [--app-check]
#   restore.sh --latest [--env docker|schema] [--app-check]
#   restore.sh --list
#
# --app-check 요구사항:
#   APP_IMAGE                   기본 qasker/api:latest (pull 가능해야 함)
#   JASYPT_ENCRYPTOR_PASSWORD   application-secrets.yml 복호화 키 (env로 전달)

set -uo pipefail

: "${BUCKET:=qasker-mysql-backup}"
: "${OCI_PROFILE:=BACKUP_READER}"
: "${OCI_CLI_CONFIG_FILE:=/var/lib/oci-mysql-backup/.oci/config}"
: "${LOCK_FILE:=/var/lock/oci-mysql-backup.lock}"
: "${WORK_BASE_DIR:=/tmp}"
: "${BASELINE_FILE:=/etc/oci-mysql-backup/healthcheck.baseline.yml}"
: "${HEALTHCHECK_SCRIPT:=/opt/oci-mysql-backup/healthcheck.sh}"
: "${DOCKER_IMAGE:=mysql:8.0}"
: "${APP_IMAGE:=qasker/api:latest}"
: "${APP_SERVER_PORT:=18080}"    # 앱 서버 포트 (호스트 네트워크 — 8080 등과 충돌 회피)
: "${APP_MGMT_PORT:=19090}"      # actuator 포트 (앱 기본 9090은 OCI-3 Prometheus와 충돌)

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
  --app-check    복원 DB에 실제 앱(Spring Boot)을 부팅시켜 최종 검증
                 (JASYPT_ENCRYPTOR_PASSWORD env 필요)
  --latest       버킷의 가장 최근 백업 자동 선택
  --list         사용 가능한 백업 목록만 표시 후 종료
  -h, --help     사용법 표시

환경변수:
  BUCKET(기본 qasker-mysql-backup), OCI_PROFILE(기본 BACKUP_READER),
  DOCKER_IMAGE(기본 mysql:8.0), BASELINE_FILE, HEALTHCHECK_SCRIPT,
  APP_IMAGE(기본 qasker/api:latest), JASYPT_ENCRYPTOR_PASSWORD(--app-check 시)
EOF
}

# ─── 인자 파싱 ───
OBJECT_KEY=""
ENV_TYPE="docker"
APP_CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_TYPE="$2"; shift 2 ;;
    --app-check) APP_CHECK=1; shift ;;
    --latest) OBJECT_KEY="__LATEST__"; shift ;;
    --list)
      # --all: 페이지네이션으로 최신 목록이 잘리는 것 방지. masked/ 는 DR 대상 아니라 제외.
      oci --profile "$OCI_PROFILE" os object list -bn "$BUCKET" --all \
        --query 'sort_by(data[?ends_with(name,`sql.gz`) && !starts_with(name,`masked/`)],&name)[].name' --output table
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
  # --all: 페이지네이션(≈1000개 컷)으로 최신이 잘리는 것 방지. 정렬은 name 기준(이름순=시간순).
  # masked/ 는 DR 복구 대상이 아니므로 제외.
  OBJECT_KEY=$(oci --profile "$OCI_PROFILE" os object list -bn "$BUCKET" --all \
    --query 'sort_by(data,&name)[?ends_with(name,`sql.gz`) && !starts_with(name,`masked/`)]|[-1].name' \
    --raw-output 2>/dev/null)
  if [[ -z "$OBJECT_KEY" || "$OBJECT_KEY" == "null" ]]; then
    fail "no-backup" 6
  fi
  log "[INFO] 선택: $OBJECT_KEY"
fi

# ─── 작업 디렉터리 ───
WORK_DIR=$(mktemp -d "$WORK_BASE_DIR/oci-mysql-restore.XXXXXX")
DUMP_FILE="$WORK_DIR/dump.sql.gz"

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

# ─── Step 1: 다운로드 ───
log "[step 1/4] downloading dump..."
download() {
  local key="$1" file="$2"
  oci --profile "$OCI_PROFILE" os object get \
    --bucket-name "$BUCKET" \
    --name "$key" \
    --file "$file" \
    >/dev/null 2>"$WORK_DIR/download.err"
}
download "$OBJECT_KEY" "$DUMP_FILE" || { log "[ERR] $(cat "$WORK_DIR/download.err")"; fail "download-dump" 4; }
log "[step 1/4] downloaded"

# ─── Step 2: Docker 격리 컨테이너 생성 ───
log "[step 2/4] starting isolated container ($DOCKER_IMAGE)..."

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
log "[step 2/4] container=$CONTAINER_NAME, waiting for healthy..."
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
log "[step 2/4] container healthy, host_port=$HOST_PORT"

# 호스트에서 TCP 접속 준비 대기 (mysqld가 소켓은 열었지만 TCP는 조금 늦음)
log "[step 2/4] waiting for TCP port readiness..."
for _ in $(seq 1 30); do
  if MYSQL_PWD="$ROOT_PWD" mysqladmin -h 127.0.0.1 -P "$HOST_PORT" --protocol=tcp -uroot ping --silent 2>/dev/null; then
    log "[step 2/4] TCP ready"
    break
  fi
  sleep 1
done

# ─── Step 3: dump 적재 ───
log "[step 3/4] loading dump.sql.gz..."
LOAD_START=$(date +%s)
if ! gzip -dc "$DUMP_FILE" | MYSQL_PWD="$ROOT_PWD" mysql \
     -h 127.0.0.1 -P "$HOST_PORT" --protocol=tcp -uroot qaskerdb 2>"$WORK_DIR/load.err"; then
  log "[FAIL] dump load failed"
  cat "$WORK_DIR/load.err" >&2
  log "       container 보존: $CONTAINER_NAME"
  fail "dump-load" 13
fi
LOAD_DUR=$(($(date +%s) - LOAD_START))
log "[step 3/4] dump loaded (${LOAD_DUR}s)"

# ─── Step 4: 헬스체크 (T7) ───
log "[step 4/4] running healthcheck (T7)..."
if [[ ! -x "$HEALTHCHECK_SCRIPT" ]]; then
  fail "healthcheck-not-found" 14
fi

set +e
HC_OUTPUT=$(RESTORED_HOST=127.0.0.1 \
  RESTORED_PORT="$HOST_PORT" \
  RESTORED_USER=root \
  RESTORED_PASSWORD="$ROOT_PWD" \
  RESTORED_DATABASE=qaskerdb \
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

# ─── (선택) 앱 부팅 검증: 소비자 관점 최종 판정 ───
# 복원 DB에 실제 앱을 붙여 부팅한다. 부팅 성공 = Flyway 마이그레이션 이력 검증 +
# Hibernate ddl-auto:validate(앱이 쓰는 전체 엔티티↔스키마 대조) + health UP.
# baseline 구조 확인(대표 테이블 샘플)보다 검증 범위가 넓고, 앱 코드가 진화하면
# 검증 기준도 자동으로 따라온다.
APP_CHECK_RESULT="skip"
if [[ $APP_CHECK -eq 1 ]]; then
  [[ -n "${JASYPT_ENCRYPTOR_PASSWORD:-}" ]] \
    || { log "[ERR] --app-check는 JASYPT_ENCRYPTOR_PASSWORD env 필요"; fail "app-check-env" 1; }

  APP_NAME="qasker-appcheck-${UNIX_TS}"
  log "[app-check] 앱 부팅 검증 시작: image=$APP_IMAGE port=$APP_SERVER_PORT mgmt=$APP_MGMT_PORT"

  # host 네트워크: 격리 MySQL의 호스트 포트(127.0.0.1:$HOST_PORT)로 바로 접속.
  # mock 프로필(local,mock): 외부 호출·실쓰기 mock, datasource는 env로 재정의(공식 관행).
  if ! docker run -d \
       --name "$APP_NAME" \
       --network host \
       -e SPRING_PROFILES_ACTIVE=local,mock \
       -e SPRING_DATASOURCE_URL="jdbc:mysql://127.0.0.1:${HOST_PORT}/qaskerdb" \
       -e SPRING_DATASOURCE_USERNAME=root \
       -e SPRING_DATASOURCE_PASSWORD="$ROOT_PWD" \
       -e SERVER_PORT="$APP_SERVER_PORT" \
       -e MANAGEMENT_SERVER_PORT="$APP_MGMT_PORT" \
       -e JASYPT_ENCRYPTOR_PASSWORD \
       "$APP_IMAGE" >/dev/null 2>"$WORK_DIR/appcheck.err"; then
    log "[ERR] 앱 컨테이너 기동 실패: $(cat "$WORK_DIR/appcheck.err")"
    fail "app-check-run" 15
  fi

  # health UP 폴링 (Spring Boot 기동 + Flyway/Hibernate 검증 시간 고려, 최대 180s)
  APP_UP=0
  for _ in $(seq 1 36); do
    if ! docker inspect "$APP_NAME" >/dev/null 2>&1; then
      break   # 부팅 실패로 컨테이너 종료 (Flyway/Hibernate validate 실패 등)
    fi
    HEALTH=$(curl -sf --max-time 3 "http://127.0.0.1:${APP_MGMT_PORT}/actuator/health" \
             | jq -r '.status // empty' 2>/dev/null)
    [[ "$HEALTH" == "UP" ]] && { APP_UP=1; break; }
    sleep 5
  done

  if [[ $APP_UP -ne 1 ]]; then
    log "[FAIL] 앱 부팅 검증 실패 — 복원 DB로 앱이 기동하지 못함"
    log "       원인 확인: docker logs $APP_NAME (Flyway/Hibernate validate 로그 확인)"
    fail "app-check-fail" 15
  fi

  APP_CHECK_RESULT="PASS"
  log "[app-check] PASS — Flyway 이력·Hibernate 스키마 검증·health UP"
  docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
fi

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
log "  app-check:    ${APP_CHECK_RESULT}"
log "  hc_result:    $HC_RESULT_FILE"
log ""
log "▶ 격리 컨테이너는 유지됨 (FR-020). 분석 후 수동 정리:"
log "    docker rm -f $CONTAINER_NAME"
log ""

exit 0
