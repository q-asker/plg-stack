#!/usr/bin/env bash
# =============================================================
# backup.sh — Prometheus/Loki 데이터 백업 단일 진입점 (T3)
# (plg-stack: specs/001-prometheus-loki-backup-recovery)
# =============================================================
# 사용법:
#   ./backup.sh [--target=prometheus|loki|both] [--dry-run] [--debug]
#
# 기본값: --target=both
#
# 흐름:
#   1) .env 로드 + 필수 검증
#   2) --target 별 handler 호출 (독립 시도, 하나 실패해도 다른 것 계속)
#   3) 인라인 무결성 검증(FR-009 1단계): 업로드 직후 GET + 해시 재비교
#   4) retention_cleanup (FR-008): 7일 초과 객체 자동 삭제
#   5) textfile collector 메트릭 갱신 (FR-010, T5에서 활성화됨)
#   6) 하나라도 실패했으면 Slack ERROR + exit 1
#
# 대응 FR: 001, 002, 003, 004, 007, 008, 009(1단계), 010, 012, 013

set -euo pipefail

# ─── 경로 계산 ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/backup-common.sh
source "${SCRIPT_DIR}/lib/backup-common.sh"

# ─── 인자 파싱 ───
TARGET="both"
DRY_RUN=0
DEBUG=0

while (( $# > 0 )); do
    case "$1" in
        --target=*) TARGET="${1#--target=}" ;;
        --dry-run)  DRY_RUN=1 ;;
        --debug)    DEBUG=1 ;;
        -h|--help)
            grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            log ERROR "알 수 없는 옵션: $1"
            exit 2
            ;;
    esac
    shift
done

case "$TARGET" in
    prometheus|loki|both) ;;
    *)
        log ERROR "--target 값 오류: '$TARGET' (허용: prometheus|loki|both)"
        exit 2
        ;;
esac

(( DEBUG )) && set -x

# ─── 환경 로드 + 필수 검증 ───
load_env "$MONITORING_DIR"

require_env \
    OCI_BUCKET_NAME \
    OCI_WRITER_PROFILE \
    OCI_READER_PROFILE \
    BACKUP_RETENTION_DAYS

require_cmd oci curl jq tar gzip sha256sum

ensure_tmp_dir

# ─── 공통 상수 ───
TIMESTAMP="$(date -u +%Y%m%d-%H%M)"
BUCKET="$OCI_BUCKET_NAME"
WRITER="$OCI_WRITER_PROFILE"
READER="$OCI_READER_PROFILE"
COMPOSE_FILE="${MONITORING_DIR}/docker-compose.yml"

# 결과 누적 (메트릭 조립용)
declare -A STORE_STATUS STORE_SIZE STORE_HASH STORE_DURATION STORE_DOWNTIME

# ═══════════════════════════════════════════════════════════
# Prometheus 핸들러
# ═══════════════════════════════════════════════════════════

backup_prometheus() {
    local store="prometheus"
    local start_ts snap_json snap_id snap_dir tar_file key sha_file expected size
    start_ts=$SECONDS

    log INFO "===== Prometheus 백업 시작 (ts=${TIMESTAMP}) ====="

    # 1) snapshot API 호출
    snap_json="$(curl -sf -X POST http://localhost:9090/api/v1/admin/tsdb/snapshot)"
    snap_id="$(echo "$snap_json" | jq -r '.data.name')"
    if [[ -z "$snap_id" || "$snap_id" == "null" ]]; then
        log ERROR "Prometheus snapshot 실패. 응답: ${snap_json}"
        return 1
    fi
    snap_dir="/mnt/monitoring/prometheus/snapshots/${snap_id}"
    log INFO "snapshot 생성: ${snap_dir}"

    # 2) tar+gzip
    tar_file="${BACKUP_TMP_DIR}/prometheus-${TIMESTAMP}.tar.gz"
    log INFO "tar+gzip: ${tar_file}"
    tar -czf "$tar_file" -C "/mnt/monitoring/prometheus/snapshots" "$snap_id"

    # 3) hash
    expected="$(hash_file "$tar_file")"
    size="$(stat -c '%s' "$tar_file")"
    log INFO "sha256=${expected}, size=${size}B"

    # 4) upload (tar.gz + .sha256 metadata)
    key="prometheus/${TIMESTAMP}-prometheus.tar.gz"
    sha_file="${BACKUP_TMP_DIR}/prometheus-${TIMESTAMP}.sha256"
    printf '%s  %s\n' "$expected" "$(basename "$key")" > "$sha_file"

    if (( DRY_RUN )); then
        log WARN "[DRY-RUN] upload 스킵: ${key}"
    else
        upload_object "$WRITER" "$BUCKET" "$key" "$tar_file"
        upload_object "$WRITER" "$BUCKET" "prometheus/${TIMESTAMP}-prometheus.sha256" "$sha_file"

        # 5) 인라인 무결성 검증 (READER 프로필로 GET, 권한 분리도 함께 검증)
        local verify_tmp="${BACKUP_TMP_DIR}/verify-prometheus-${TIMESTAMP}.tar.gz"
        if ! verify_object "$READER" "$BUCKET" "$key" "$expected" "$verify_tmp"; then
            log ERROR "Prometheus 무결성 검증 실패 → quarantine 이동"
            rename_object "$WRITER" "$BUCKET" "$key" "quarantine/${key}"
            rename_object "$WRITER" "$BUCKET" "prometheus/${TIMESTAMP}-prometheus.sha256" \
                "quarantine/prometheus/${TIMESTAMP}-prometheus.sha256" || true
            return 1
        fi
    fi

    # 6) 로컬 cleanup
    rm -rf "$snap_dir"
    rm -f "$tar_file" "$sha_file"
    log INFO "로컬 정리 완료"

    # 7) 결과 기록
    STORE_STATUS[$store]=1
    STORE_SIZE[$store]=$size
    STORE_HASH[$store]="$expected"
    STORE_DURATION[$store]=$(( SECONDS - start_ts ))

    log INFO "===== Prometheus 백업 완료 (${STORE_DURATION[$store]}s) ====="
    return 0
}

# ═══════════════════════════════════════════════════════════
# Loki 핸들러
# ═══════════════════════════════════════════════════════════

backup_loki() {
    local store="loki"
    local start_ts stop_ts start_time_ts hardlink_dir tar_file key sha_file expected size downtime
    start_ts=$SECONDS

    log INFO "===== Loki 백업 시작 (ts=${TIMESTAMP}) ====="

    # 1) flush API 로 인메모리 청크를 disk로 밀어냄
    curl -sf -X POST http://localhost:3100/flush >/dev/null \
        || log WARN "Loki flush API 응답 이상, 계속 진행"
    sleep 3

    # 2) 최단 정지 → cp -al hardlink → 재시작
    hardlink_dir="${BACKUP_TMP_DIR}/loki-${TIMESTAMP}"
    log INFO "Loki 정지 → hardlink copy → 재시작"

    stop_ts=$SECONDS
    docker compose -f "$COMPOSE_FILE" stop loki >/dev/null
    cp -al /mnt/monitoring/loki "$hardlink_dir"
    docker compose -f "$COMPOSE_FILE" start loki >/dev/null
    start_time_ts=$SECONDS

    downtime=$(( start_time_ts - stop_ts ))
    STORE_DOWNTIME[$store]=$downtime
    log INFO "Loki 정지 시간: ${downtime}s"

    if (( downtime > LOKI_DOWNTIME_LIMIT_SEC )); then
        log ERROR "Loki 정지 시간 ${downtime}s > ${LOKI_DOWNTIME_LIMIT_SEC}s (SC-005 위반)"
        notify_slack WARN "loki-downtime" "정지 ${downtime}s (한계 ${LOKI_DOWNTIME_LIMIT_SEC}s 초과)"
        # 정지 시간이 길어도 백업 자체는 완료했으니 계속 진행
    fi

    # 3) tar+gzip
    tar_file="${BACKUP_TMP_DIR}/loki-${TIMESTAMP}.tar.gz"
    log INFO "tar+gzip: ${tar_file}"
    tar -czf "$tar_file" -C "$BACKUP_TMP_DIR" "loki-${TIMESTAMP}"

    # 4) hash
    expected="$(hash_file "$tar_file")"
    size="$(stat -c '%s' "$tar_file")"
    log INFO "sha256=${expected}, size=${size}B"

    # 5) upload
    key="loki/${TIMESTAMP}-loki.tar.gz"
    sha_file="${BACKUP_TMP_DIR}/loki-${TIMESTAMP}.sha256"
    printf '%s  %s\n' "$expected" "$(basename "$key")" > "$sha_file"

    if (( DRY_RUN )); then
        log WARN "[DRY-RUN] upload 스킵: ${key}"
    else
        upload_object "$WRITER" "$BUCKET" "$key" "$tar_file"
        upload_object "$WRITER" "$BUCKET" "loki/${TIMESTAMP}-loki.sha256" "$sha_file"

        # 6) 인라인 무결성 검증
        local verify_tmp="${BACKUP_TMP_DIR}/verify-loki-${TIMESTAMP}.tar.gz"
        if ! verify_object "$READER" "$BUCKET" "$key" "$expected" "$verify_tmp"; then
            log ERROR "Loki 무결성 검증 실패 → quarantine 이동"
            rename_object "$WRITER" "$BUCKET" "$key" "quarantine/${key}"
            rename_object "$WRITER" "$BUCKET" "loki/${TIMESTAMP}-loki.sha256" \
                "quarantine/loki/${TIMESTAMP}-loki.sha256" || true
            return 1
        fi
    fi

    # 7) 로컬 cleanup (hardlink dir은 inode 참조라 원본 손상 없음)
    rm -rf "$hardlink_dir"
    rm -f "$tar_file" "$sha_file"
    log INFO "로컬 정리 완료"

    # 8) 결과 기록
    STORE_STATUS[$store]=1
    STORE_SIZE[$store]=$size
    STORE_HASH[$store]="$expected"
    STORE_DURATION[$store]=$(( SECONDS - start_ts ))

    log INFO "===== Loki 백업 완료 (${STORE_DURATION[$store]}s, downtime ${downtime}s) ====="
    return 0
}

# ═══════════════════════════════════════════════════════════
# 메트릭 조립
# ═══════════════════════════════════════════════════════════

emit_metrics() {
    local now_epoch
    now_epoch="$(date -u +%s)"

    local content
    content=""
    content+="# HELP q_asker_backup_last_success_timestamp Last successful backup epoch seconds"$'\n'
    content+="# TYPE q_asker_backup_last_success_timestamp gauge"$'\n'
    content+="# HELP q_asker_backup_duration_seconds Backup duration seconds"$'\n'
    content+="# TYPE q_asker_backup_duration_seconds gauge"$'\n'
    content+="# HELP q_asker_backup_size_bytes Backup tar.gz size bytes"$'\n'
    content+="# TYPE q_asker_backup_size_bytes gauge"$'\n'
    content+="# HELP q_asker_backup_loki_downtime_seconds Loki container downtime during backup"$'\n'
    content+="# TYPE q_asker_backup_loki_downtime_seconds gauge"$'\n'

    local s
    for s in prometheus loki; do
        if [[ "${STORE_STATUS[$s]:-0}" == "1" ]]; then
            content+="q_asker_backup_last_success_timestamp{store=\"${s}\"} ${now_epoch}"$'\n'
            content+="q_asker_backup_duration_seconds{store=\"${s}\"} ${STORE_DURATION[$s]}"$'\n'
            content+="q_asker_backup_size_bytes{store=\"${s}\"} ${STORE_SIZE[$s]}"$'\n'
        fi
    done

    if [[ -n "${STORE_DOWNTIME[loki]:-}" ]]; then
        content+="q_asker_backup_loki_downtime_seconds ${STORE_DOWNTIME[loki]}"$'\n'
    fi

    write_metrics_atomic "$content"
}

# ═══════════════════════════════════════════════════════════
# 메인 실행 (독립 시도 + 실패 취합)
# ═══════════════════════════════════════════════════════════

TOTAL_START=$SECONDS
declare -i failures=0

# trap ERR로 예외 상황도 Slack에 알림
trap 'log ERROR "예상치 못한 오류 (line=$LINENO)"; notify_slack ERROR "backup" "예상치 못한 오류 line=$LINENO"' ERR

if [[ "$TARGET" == "prometheus" || "$TARGET" == "both" ]]; then
    if ! backup_prometheus; then
        log ERROR "Prometheus 백업 실패"
        STORE_STATUS[prometheus]=0
        failures=$((failures + 1))
        notify_slack ERROR "prometheus" "백업 또는 검증 실패. TIMESTAMP=${TIMESTAMP}"
    fi
fi

if [[ "$TARGET" == "loki" || "$TARGET" == "both" ]]; then
    if ! backup_loki; then
        log ERROR "Loki 백업 실패"
        STORE_STATUS[loki]=0
        failures=$((failures + 1))
        notify_slack ERROR "loki" "백업 또는 검증 실패. TIMESTAMP=${TIMESTAMP}"
    fi
fi

# ─── retention 정리 (실패해도 백업 자체가 성공했으면 exit 0 유지) ───
if (( DRY_RUN )); then
    log WARN "[DRY-RUN] retention_cleanup 스킵"
else
    for prefix in prometheus/ loki/; do
        retention_cleanup "$WRITER" "$BUCKET" "$prefix" "$BACKUP_RETENTION_DAYS" \
            || log WARN "retention_cleanup 실패: ${prefix} (계속 진행)"
    done
fi

# ─── 메트릭 노출 ───
emit_metrics

TOTAL_DURATION=$(( SECONDS - TOTAL_START ))
log INFO "총 소요: ${TOTAL_DURATION}s, 실패 store: ${failures}"

if (( failures > 0 )); then
    exit 1
fi

# 정상 종료 시에도 성공 알림은 옵션 (매일 스팸 방지). WARN 상태만 알림.
log INFO "backup.sh 정상 종료"
exit 0
