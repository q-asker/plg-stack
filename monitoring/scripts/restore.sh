#!/usr/bin/env bash
# =============================================================
# restore.sh — Prometheus/Loki 데이터 복원 단일 진입점 (T4)
# (plg-stack: specs/001-prometheus-loki-backup-recovery)
# =============================================================
# 사용법:
#   ./restore.sh --target=prometheus|loki|both --snapshot=YYYYMMDD-HHMM [--dry-run]
#
# 필수 인자:
#   --target    복원할 스토어 (prometheus | loki | both)
#   --snapshot  복원할 시점 (예: 20260701-1447). OCI 객체 목록에서 확인 가능.
#
# 선택 인자:
#   --dry-run   다운로드 + 무결성 검증만 수행. 실제 stop/rename/extract는 스킵.
#
# 흐름 (스토어별):
#   1. OCI에서 tar.gz + .sha256 다운로드
#   2. 로컬 해시 재계산 → 무결성 확인
#   3. docker compose stop <svc>
#   4. /mnt/monitoring/<store> → .bak.<unix_ts> rename  (롤백 안전망)
#   5. tar -xzf --strip-components=1 → /mnt/monitoring/<store>
#   6. chown -R <UID>:<UID>  (Prom 65534, Loki 10001)
#   7. docker compose start <svc>
#   8. 헬스 폴링 30회 × 10초 (Prom: /-/ready, Loki: /ready)
#   9. 성공: .bak.<ts> 보존 (자동 삭제 절대 X — 운영자 수동 정리)
#      실패: 자동 롤백 (새 dir 삭제 → .bak.<ts> mv back → start)
#
# 대응 FR: 006, 011, 014
# 대응 SC: 001 (RTO 4h), 007 (재현성)

set -euo pipefail

# ─── 경로 계산 ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/backup-common.sh
source "${SCRIPT_DIR}/lib/backup-common.sh"

# ─── 인자 파싱 ───
TARGET=""
SNAPSHOT=""
DRY_RUN=0

usage() {
    grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

while (( $# > 0 )); do
    case "$1" in
        --target=*)   TARGET="${1#--target=}" ;;
        --snapshot=*) SNAPSHOT="${1#--snapshot=}" ;;
        --dry-run)    DRY_RUN=1 ;;
        -h|--help)    usage ;;
        *)
            log ERROR "알 수 없는 옵션: $1"
            usage
            ;;
    esac
    shift
done

# ─── 필수 인자 검증 ───
if [[ -z "$TARGET" ]]; then
    log ERROR "--target 필수 (prometheus | loki | both)"
    exit 2
fi

case "$TARGET" in
    prometheus|loki|both) ;;
    *)
        log ERROR "--target 값 오류: '$TARGET'"
        exit 2
        ;;
esac

# ─── 환경 로드 ───
load_env "$MONITORING_DIR"
require_env OCI_BUCKET_NAME OCI_WRITER_PROFILE OCI_READER_PROFILE
require_cmd oci curl jq tar sha256sum chown

ensure_tmp_dir

BUCKET="$OCI_BUCKET_NAME"
READER="$OCI_READER_PROFILE"
COMPOSE_FILE="${MONITORING_DIR}/docker-compose.yml"

# ─── --snapshot 검증 (미지정 시 사용 가능한 목록 안내 후 exit) ───
if [[ -z "$SNAPSHOT" ]]; then
    log ERROR "--snapshot 필수 인자입니다. 사용 가능한 스냅샷:"
    for store in prometheus loki; do
        [[ "$TARGET" != "$store" && "$TARGET" != "both" ]] && continue
        printf '  # %s\n' "$store" >&2
        if ! list_available_snapshots "$READER" "$BUCKET" "$store" | sed 's/^/    /' >&2; then
            printf '    (조회 실패)\n' >&2
        fi
    done
    exit 2
fi

# 형식 검증
if [[ ! "$SNAPSHOT" =~ ^[0-9]{8}-[0-9]{4}$ ]]; then
    log ERROR "--snapshot 형식 오류: '${SNAPSHOT}' (기대: YYYYMMDD-HHMM)"
    exit 2
fi

# ─── 결과 누적 ───
declare -A STORE_STATUS STORE_DURATION STORE_BAK_DIR

# ═══════════════════════════════════════════════════════════
# 스토어 복원 handler (부분 롤백 포함)
# ═══════════════════════════════════════════════════════════

# restore_store <store> <uid> <health_url>
restore_store() {
    local store="$1"
    local uid="$2"
    local health_url="$3"
    local start_ts=$SECONDS

    log INFO "===== ${store} 복원 시작 (snapshot=${SNAPSHOT}) ====="

    local tar_key="${store}/${SNAPSHOT}-${store}.tar.gz"
    local sha_key="${store}/${SNAPSHOT}-${store}.sha256"
    local tar_file="${BACKUP_TMP_DIR}/restore-${store}-${SNAPSHOT}.tar.gz"
    local sha_file="${BACKUP_TMP_DIR}/restore-${store}-${SNAPSHOT}.sha256"

    # 1. 다운로드
    if ! download_object "$READER" "$BUCKET" "$tar_key" "$tar_file"; then
        log ERROR "[${store}] tar.gz 다운로드 실패: ${tar_key}"
        return 1
    fi
    if ! download_object "$READER" "$BUCKET" "$sha_key" "$sha_file"; then
        log ERROR "[${store}] sha256 다운로드 실패: ${sha_key}"
        rm -f "$tar_file"
        return 1
    fi

    # 2. 로컬 무결성 검증
    if ! verify_local_hash "$tar_file" "$sha_file"; then
        log ERROR "[${store}] 무결성 검증 실패 → 복원 중단 (원본 무영향)"
        rm -f "$tar_file" "$sha_file"
        return 1
    fi

    if (( DRY_RUN )); then
        log WARN "[${store}][DRY-RUN] stop/rename/extract/start 스킵. 원본 유지."
        rm -f "$tar_file" "$sha_file"
        STORE_STATUS[$store]=1
        STORE_DURATION[$store]=$(( SECONDS - start_ts ))
        return 0
    fi

    # 3. 정지 + rename (rollback 안전망)
    local data_dir="/mnt/monitoring/${store}"
    local bak_ts
    bak_ts="$(date +%s)"
    local bak_dir="${data_dir}.bak.${bak_ts}"

    log INFO "[${store}] docker compose stop"
    docker compose -f "$COMPOSE_FILE" stop "$store" >/dev/null

    log INFO "[${store}] rename: ${data_dir} → ${bak_dir}"
    if ! mv "$data_dir" "$bak_dir"; then
        log ERROR "[${store}] rename 실패 → 컨테이너 재기동만 시도"
        docker compose -f "$COMPOSE_FILE" start "$store" >/dev/null || true
        rm -f "$tar_file" "$sha_file"
        return 1
    fi

    # 4. extract
    mkdir -p "$data_dir"
    if ! tar -xzf "$tar_file" -C "$data_dir" --strip-components=1; then
        log ERROR "[${store}] tar 압축 해제 실패 → 롤백"
        _rollback "$store" "$data_dir" "$bak_dir"
        rm -f "$tar_file" "$sha_file"
        return 1
    fi

    # 5. 권한 복원
    log INFO "[${store}] chown ${uid}:${uid}"
    if ! chown -R "${uid}:${uid}" "$data_dir"; then
        log ERROR "[${store}] chown 실패 → 롤백"
        _rollback "$store" "$data_dir" "$bak_dir"
        rm -f "$tar_file" "$sha_file"
        return 1
    fi

    # 6. 재기동 + 헬스 폴링
    log INFO "[${store}] docker compose start"
    docker compose -f "$COMPOSE_FILE" start "$store" >/dev/null

    log INFO "[${store}] 헬스 폴링 시작: ${health_url} (30회 × 10초)"
    if ! health_poll "$health_url" 30 10; then
        log ERROR "[${store}] 헬스 미도달 → 롤백"
        docker compose -f "$COMPOSE_FILE" stop "$store" >/dev/null || true
        _rollback "$store" "$data_dir" "$bak_dir"
        rm -f "$tar_file" "$sha_file"
        return 1
    fi

    # 7. 성공: 임시 파일 정리, .bak 보존 (자동 삭제 절대 X)
    rm -f "$tar_file" "$sha_file"
    STORE_STATUS[$store]=1
    STORE_DURATION[$store]=$(( SECONDS - start_ts ))
    STORE_BAK_DIR[$store]="$bak_dir"

    log INFO "===== ${store} 복원 완료 (${STORE_DURATION[$store]}s) ====="
    log INFO "[${store}] 원본은 보존됨 (수동 확인 후 삭제): ${bak_dir}"
    return 0
}

# _rollback <store> <data_dir> <bak_dir>
#   실패 시 자동 롤백. 실패해도 최선의 노력.
_rollback() {
    local store="$1"
    local data_dir="$2"
    local bak_dir="$3"

    log WARN "[${store}] ── ROLLBACK 시작 ──"

    if [[ -d "$data_dir" ]]; then
        rm -rf "$data_dir" || log WARN "[${store}] 새 data_dir 삭제 실패: ${data_dir}"
    fi

    if [[ -d "$bak_dir" ]]; then
        if mv "$bak_dir" "$data_dir"; then
            log INFO "[${store}] 원본 복귀: ${bak_dir} → ${data_dir}"
        else
            log ERROR "[${store}] 롤백 mv 실패 — 수동 개입 필요: ${bak_dir} → ${data_dir}"
        fi
    else
        log ERROR "[${store}] bak_dir 부재 — 롤백 불가: ${bak_dir}"
    fi

    docker compose -f "$COMPOSE_FILE" start "$store" >/dev/null || \
        log WARN "[${store}] 롤백 후 재기동 실패"

    log WARN "[${store}] ── ROLLBACK 종료 ──"
}

# ═══════════════════════════════════════════════════════════
# 메인 실행 (스토어별 독립 시도 — Q3=B)
# ═══════════════════════════════════════════════════════════

TOTAL_START=$SECONDS
declare -i failures=0

trap 'log ERROR "예상치 못한 오류 (line=$LINENO)"; notify_slack ERROR "restore" "예상치 못한 오류 line=$LINENO"' ERR

if [[ "$TARGET" == "prometheus" || "$TARGET" == "both" ]]; then
    if ! restore_store prometheus 65534 "http://localhost:9090/-/ready"; then
        STORE_STATUS[prometheus]=0
        failures=$(( failures + 1 ))
        notify_slack ERROR "restore-prometheus" "복원 실패. snapshot=${SNAPSHOT}"
    fi
fi

if [[ "$TARGET" == "loki" || "$TARGET" == "both" ]]; then
    if ! restore_store loki 10001 "http://localhost:3100/ready"; then
        STORE_STATUS[loki]=0
        failures=$(( failures + 1 ))
        notify_slack ERROR "restore-loki" "복원 실패. snapshot=${SNAPSHOT}"
    fi
fi

# ─── 결과 요약 ───
TOTAL_DURATION=$(( SECONDS - TOTAL_START ))
log INFO "===== 총 소요 ${TOTAL_DURATION}s, 실패 store: ${failures} ====="

for store in prometheus loki; do
    if [[ "${STORE_STATUS[$store]:-0}" == "1" ]]; then
        if [[ -n "${STORE_BAK_DIR[$store]:-}" ]]; then
            log INFO "[${store}] ✅ 성공 (${STORE_DURATION[$store]}s). 원본 보존: ${STORE_BAK_DIR[$store]}"
        else
            log INFO "[${store}] ✅ dry-run 성공 (${STORE_DURATION[$store]}s)."
        fi
    fi
done

if (( failures > 0 )); then
    exit 1
fi

notify_slack SUCCESS "restore" "target=${TARGET} snapshot=${SNAPSHOT} 총 ${TOTAL_DURATION}s"
log INFO "restore.sh 정상 종료"
exit 0
