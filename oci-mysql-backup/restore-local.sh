#!/usr/bin/env bash
# ============================================================
# restore-local.sh — 프로덕션 MySQL 덤프를 "로컬 전용 컨테이너"에 복원
# (restore.sh 는 GameDay용 유니크 격리 컨테이너 / 이건 분석용 고정 컨테이너)
# ============================================================
# 목적:
#   OCI 버킷의 "마스킹본"(masked/ prefix)을 다운로드해, 스크립트가 관리하는 고정
#   로컬 MySQL 컨테이너(기본 local-mysql-prod:3307)에 qaskerdb로 적재한다.
#   개발용 q-asker-db(3306)는 건드리지 않는다. EXPLAIN·인덱스·테이블크기 분석용.
#
# 기본 소스는 마스킹본(--source=masked)이라 개발자는 옵션 없이 실행해도 원본 PII가
# 로컬에 닿지 않는다. 원본(DR) 적재는 트러스트 존 전용으로 --source=dr 를 명시해야 한다
# (masked-export.sh 에 먹일 staging 준비 등).
#
# 사용법:
#   ./restore-local.sh --latest                              # 최신 마스킹본 자동
#   ./restore-local.sh masked/2026/07/12/qasker-masked-...Z.sql.gz  # 특정 마스킹 객체
#   ./restore-local.sh --file=/tmp/masked.sql.gz             # 이미 받은 덤프
#   ./restore-local.sh --source=dr --latest                  # ⚠️ 트러스트 존: 원본 DR 적재
#   옵션: --source=masked|dr --container=NAME --port=N --database=DB --root-pwd=PW --no-verify --keep -h
#
# 흐름:
#   1. 덤프 확보(--file 그대로 / 아니면 OCI 다운로드) + sha256 검증
#   2. 전용 컨테이너 보장(없으면 docker run, 있으면 start) + ready 폴링
#   3. qaskerdb DROP+CREATE (--keep 이면 유지) 후 덤프 적재
#   4. row 카운트 검증 출력
#
# 종료 코드: 0 성공 / 1 인자오류 / 3 sha불일치 / 4 다운로드실패 / 6 백업없음
#            12 docker오류 / 13 적재실패
set -uo pipefail

: "${BUCKET:=qasker-mysql-backup}"
: "${OCI_PROFILE:=BACKUP_READER}"
: "${DOCKER_IMAGE:=mysql:8.0}"
: "${WORK_BASE_DIR:=/tmp}"
: "${MASKED_PREFIX:=masked/}"

CONTAINER="local-mysql-prod"
HOST_PORT="3307"
DATABASE="qaskerdb"
ROOT_PWD="${MYSQL_ROOT_PASSWORD:-password}"
NO_VERIFY=0
KEEP_DB=0
OBJECT_KEY=""
FILE=""
SOURCE="masked"   # 기본 소스: 마스킹본(masked/ prefix). dr 은 트러스트 존 전용 원본.

log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
fail() { log "[FAIL] stage=$1 exit=$2"; exit "$2"; }
usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

# sha256sum(GNU) 또는 shasum -a 256(macOS) 이식성 래퍼
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
  else shasum -a 256 "$@"; fi
}

while (( $# > 0 )); do
  case "$1" in
    --latest)      OBJECT_KEY="__LATEST__" ;;
    --file=*)      FILE="${1#--file=}" ;;
    --source=*)    SOURCE="${1#--source=}" ;;
    --dr)          SOURCE="dr" ;;
    --container=*) CONTAINER="${1#--container=}" ;;
    --port=*)      HOST_PORT="${1#--port=}" ;;
    --database=*)  DATABASE="${1#--database=}" ;;
    --root-pwd=*)  ROOT_PWD="${1#--root-pwd=}" ;;
    --no-verify)   NO_VERIFY=1 ;;
    --keep)        KEEP_DB=1 ;;
    -h|--help)     usage 0 ;;
    --*)           log "[ERR] 알 수 없는 옵션: $1"; usage 1 ;;
    *)             OBJECT_KEY="$1" ;;
  esac
  shift
done

command -v docker >/dev/null || fail "no-docker" 12
[[ -n "$FILE" || -n "$OBJECT_KEY" ]] || usage 1

# ─── 소스 검증 (기본 masked, dr 은 트러스트 존 전용) ───
case "$SOURCE" in
  masked)
    # masked 모드에서 명시 객체키는 반드시 masked/ 로 시작해야 함(실수로 DR 키 지정 차단)
    if [[ -n "$OBJECT_KEY" && "$OBJECT_KEY" != "__LATEST__" && "$OBJECT_KEY" != "$MASKED_PREFIX"* ]]; then
      log "[ERR] --source=masked 인데 객체키가 ${MASKED_PREFIX} 로 시작하지 않음: $OBJECT_KEY"
      log "      원본 DR 을 적재하려면 --source=dr 을 명시하세요(트러스트 존 전용)."
      exit 1
    fi ;;
  dr)
    log "[WARN] ⚠️  --source=dr: 원본(비마스킹) PII 를 로컬에 적재합니다. 트러스트 존에서만 사용하세요." ;;
  *)
    log "[ERR] 알 수 없는 --source: $SOURCE (masked|dr)"; exit 1 ;;
esac

WORK_DIR="$(mktemp -d "$WORK_BASE_DIR/oci-mysql-restore-local.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# ─── 1. 덤프 확보 + 검증 ───
if [[ -n "$FILE" ]]; then
  [[ -f "$FILE" ]] || fail "no-file" 1
  DUMP_FILE="$FILE"
  SHA_FILE="${FILE%.sql.gz}.sha256"
  log "[1/4] 로컬 덤프 사용: $DUMP_FILE"
else
  command -v oci >/dev/null || fail "no-oci" 1
  if [[ "$OBJECT_KEY" == "__LATEST__" ]]; then
    log "[1/4] --latest($SOURCE): 최신 sql.gz 조회..."
    # --all: 페이지네이션(기본 ≈1000개 컷)으로 최신이 잘리는 것 방지.
    # 정렬은 name 기준 — 키가 YYYY/MM/DD/...<UTC> 라 이름순=시간순이고, time-created 필드
    # 미반환 시 정렬이 깨지는 문제도 함께 피한다.
    if [[ "$SOURCE" == "masked" ]]; then
      # masked/ prefix 로 서버측 제한 → DR 객체는 애초에 조회 대상 아님
      OBJECT_KEY="$(oci --profile "$OCI_PROFILE" os object list -bn "$BUCKET" --prefix "$MASKED_PREFIX" --all \
        --query 'sort_by(data,&name)[?ends_with(name,`sql.gz`)]|[-1].name' \
        --raw-output 2>/dev/null)"
    else
      # dr: masked/ prefix 는 제외하고 DR 백업(YYYY/MM/DD/) 중 최신
      OBJECT_KEY="$(oci --profile "$OCI_PROFILE" os object list -bn "$BUCKET" --all \
        --query 'sort_by(data,&name)[?ends_with(name,`sql.gz`) && !starts_with(name,`masked/`)]|[-1].name' \
        --raw-output 2>/dev/null)"
    fi
    [[ -z "$OBJECT_KEY" || "$OBJECT_KEY" == "null" ]] && fail "no-backup" 6
    log "[1/4] 선택: $OBJECT_KEY"
  fi
  DUMP_FILE="$WORK_DIR/dump.sql.gz"
  SHA_FILE="$WORK_DIR/dump.sha256"
  oci --profile "$OCI_PROFILE" os object get -bn "$BUCKET" --name "$OBJECT_KEY"                --file "$DUMP_FILE" >/dev/null 2>&1 || fail "download-dump" 4
  oci --profile "$OCI_PROFILE" os object get -bn "$BUCKET" --name "${OBJECT_KEY%.sql.gz}.sha256" --file "$SHA_FILE"  >/dev/null 2>&1 || SHA_FILE=""
fi

if (( ! NO_VERIFY )) && [[ -n "$SHA_FILE" && -f "$SHA_FILE" ]]; then
  expected="$(awk '{print $1}' "$SHA_FILE")"
  actual="$(sha256 "$DUMP_FILE" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || fail "sha-mismatch" 3
  log "[1/4] sha256 OK"
else
  log "[1/4] sha 검증 건너뜀"
fi

# ─── 2. 전용 컨테이너 보장 ───
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  docker start "$CONTAINER" >/dev/null 2>&1 || true
  log "[2/4] 기존 컨테이너 사용: $CONTAINER"
else
  log "[2/4] 컨테이너 생성: $CONTAINER (image=$DOCKER_IMAGE, port=$HOST_PORT)"
  docker run -d --name "$CONTAINER" \
    -e MYSQL_ROOT_PASSWORD="$ROOT_PWD" \
    -p "$HOST_PORT:3306" \
    "$DOCKER_IMAGE" >/dev/null || fail "docker-run" 12
fi

log "[2/4] mysqld ready 대기..."
ready=0
for _ in $(seq 1 40); do
  # ping 은 초기화 중에도 alive 를 반환 → 인증 SELECT 성공까지 대기(직후 DROP/CREATE 레이스 방지)
  if docker exec "$CONTAINER" mysql -uroot -p"$ROOT_PWD" -N -e "SELECT 1" >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
(( ready )) || fail "mysql-not-ready" 12

# ─── 3. DB 준비 + 적재 ───
if (( ! KEEP_DB )); then
  log "[3/4] $DATABASE DROP+CREATE"
  docker exec "$CONTAINER" mysql -uroot -p"$ROOT_PWD" \
    -e "DROP DATABASE IF EXISTS \`$DATABASE\`; CREATE DATABASE \`$DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null \
    || fail "db-prepare" 13
else
  docker exec "$CONTAINER" mysql -uroot -p"$ROOT_PWD" \
    -e "CREATE DATABASE IF NOT EXISTS \`$DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
fi

log "[3/4] 덤프 적재 중..."
if ! gzip -dc "$DUMP_FILE" | docker exec -i "$CONTAINER" mysql -uroot -p"$ROOT_PWD" "$DATABASE" 2>/dev/null; then
  fail "load" 13
fi
log "[3/4] 적재 완료"

# ─── 4. 검증 ───
log "[4/4] row 카운트:"
docker exec "$CONTAINER" mysql -uroot -p"$ROOT_PWD" "$DATABASE" -N 2>/dev/null -e "
  SELECT CONCAT('  ', table_name, ' = ', table_rows)
  FROM information_schema.tables
  WHERE table_schema='$DATABASE' ORDER BY table_rows DESC LIMIT 8;" || true

log "✅ 복원 완료 — 접속: mysql -h127.0.0.1 -P$HOST_PORT -uroot -p$ROOT_PWD $DATABASE"
log "   컨테이너 정리: docker rm -f $CONTAINER"
exit 0
