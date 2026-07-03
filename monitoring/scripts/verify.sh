#!/usr/bin/env bash
# =============================================================
# verify.sh — 백업 무결성 재검증 + 저장소 임계 알림 (T6)
# (plg-stack: specs/001-prometheus-loki-backup-recovery)
# =============================================================
# 사용법:
#   ./verify.sh [--scope=all|prometheus|loki] [--dry-run]
#
# 기본값: --scope=all
#
# 흐름 (스토어별 독립 시도, Q3=a):
#   1) list_available_snapshots로 timestamp 목록 획득
#   2) 각 timestamp에 대해:
#      - tar.gz + .sha256 다운로드
#      - verify_local_hash로 재계산 비교
#      - 성공: success 카운트 증가
#      - 실패: fail 카운트 증가 + rename_object로 quarantine/<원경로>로 이동
#              + Slack ERROR 알림
#   3) 저장소 사용량(approximate-size) 조회 → 한도 대비 ratio 계산
#      - 90% 초과 + 상태 파일 부재: Slack WARN + 상태 파일 생성 (Q2=b, 재발송 억제)
#      - 90% 회복 + 상태 파일 존재: 상태 파일 삭제 (다음 도달 시 다시 알림)
#   4) q_asker_verify.prom 에 메트릭 원자적 write (Q1=b, backup.sh와 파일 분리)
#   5) fail + download_error > 0 이면 exit 1, 아니면 exit 0
#
# quarantine/ 접두사는 T2 lifecycle rule 및 T3 retention_cleanup에서 제외되므로
# 자동 삭제되지 않는다. 운영자가 원인 분석 후 수동으로 처리한다 (RUNBOOK 등재 예정).
#
# 대응 FR: 009 (2단계 무결성 재검증), 013 (저장소 임계 알림)

set -euo pipefail

# ─── 경로 계산 ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/backup-common.sh
source "${SCRIPT_DIR}/lib/backup-common.sh"

# ─── 인자 파싱 ───
SCOPE="all"
DRY_RUN=0

while (( $# > 0 )); do
    case "$1" in
        --scope=*) SCOPE="${1#--scope=}" ;;
        --dry-run) DRY_RUN=1 ;;
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

case "$SCOPE" in
    all|prometheus|loki) ;;
    *)
        log ERROR "--scope 값 오류: '$SCOPE' (허용: all|prometheus|loki)"
        exit 2
        ;;
esac

# ─── 환경 로드 + 필수 검증 ───
load_env "$MONITORING_DIR"

require_env \
    OCI_BUCKET_NAME \
    OCI_WRITER_PROFILE \
    OCI_READER_PROFILE

require_cmd oci curl jq sha256sum awk

ensure_tmp_dir

BUCKET="$OCI_BUCKET_NAME"
WRITER="$OCI_WRITER_PROFILE"
READER="$OCI_READER_PROFILE"

# 저장소 한도 (기본 20 GiB)
BACKUP_FREE_LIMIT_BYTES="${BACKUP_FREE_LIMIT_BYTES:-21474836480}"
THRESHOLD_FLAG="${BACKUP_TMP_DIR}/threshold-alerted.flag"
THRESHOLD_RATIO="0.90"

# 결과 누적
declare -A SUCCESS FAIL DOWNLOAD_ERR
STORAGE_USAGE_BYTES=0
STORAGE_USAGE_RATIO=0

# ═══════════════════════════════════════════════════════════
# 스토어 verify handler
# ═══════════════════════════════════════════════════════════

verify_store() {
    local store="$1"
    log INFO "===== ${store} 재검증 시작 ====="

    local snapshots
    snapshots="$(list_available_snapshots "$READER" "$BUCKET" "$store" || true)"

    local success=0 fail=0 dl_err=0
    local total_bytes=0
    local timestamp

    if [[ -z "$snapshots" ]]; then
        log WARN "[${store}] 스냅샷 없음 — 재검증 대상 없음"
        SUCCESS[$store]=0
        FAIL[$store]=0
        DOWNLOAD_ERR[$store]=0
        return 0
    fi

    while IFS= read -r timestamp; do
        [[ -z "$timestamp" ]] && continue

        local tar_key="${store}/${timestamp}-${store}.tar.gz"
        local sha_key="${store}/${timestamp}-${store}.sha256"
        local tar_file="${BACKUP_TMP_DIR}/verify-${store}-${timestamp}.tar.gz"
        local sha_file="${BACKUP_TMP_DIR}/verify-${store}-${timestamp}.sha256"

        log INFO "[${store}] ${timestamp} 검증 시작"

        # 1. 다운로드
        if ! download_object "$READER" "$BUCKET" "$tar_key" "$tar_file"; then
            log ERROR "[${store}] tar.gz 다운로드 실패: ${tar_key}"
            dl_err=$(( dl_err + 1 ))
            rm -f "$tar_file" "$sha_file"
            continue
        fi

        if ! download_object "$READER" "$BUCKET" "$sha_key" "$sha_file"; then
            log ERROR "[${store}] sha256 다운로드 실패: ${sha_key}"
            dl_err=$(( dl_err + 1 ))
            rm -f "$tar_file" "$sha_file"
            continue
        fi

        # 2. 해시 재검증
        if verify_local_hash "$tar_file" "$sha_file"; then
            success=$(( success + 1 ))
            total_bytes=$(( total_bytes + $(stat -c '%s' "$tar_file" 2>/dev/null || echo 0) ))
        else
            fail=$(( fail + 1 ))
            log ERROR "[${store}] 무결성 실패: ${tar_key} → quarantine 이동"

            if (( DRY_RUN )); then
                log WARN "[${store}][DRY-RUN] quarantine 이동 스킵"
            else
                # quarantine 이동 (WRITER 프로필 필요)
                rename_object "$WRITER" "$BUCKET" "$tar_key" "quarantine/${tar_key}" \
                    || log WARN "[${store}] tar.gz quarantine 이동 실패: ${tar_key}"
                rename_object "$WRITER" "$BUCKET" "$sha_key" "quarantine/${sha_key}" \
                    || log WARN "[${store}] sha256 quarantine 이동 실패: ${sha_key}"
                notify_slack ERROR "verify-${store}" \
                    "무결성 검증 실패: ${tar_key} → quarantine/${tar_key} 이동"
            fi
        fi

        rm -f "$tar_file" "$sha_file"
    done <<< "$snapshots"

    SUCCESS[$store]=$success
    FAIL[$store]=$fail
    DOWNLOAD_ERR[$store]=$dl_err

    log INFO "===== ${store} 재검증 완료 (성공=${success}, 실패=${fail}, DL오류=${dl_err}) ====="
    return 0
}

# ═══════════════════════════════════════════════════════════
# 저장소 임계 확인 (Q2=b: 상태 파일로 1회 억제)
# ═══════════════════════════════════════════════════════════

check_storage_threshold() {
    log INFO "===== 저장소 사용량 확인 ====="

    STORAGE_USAGE_BYTES="$(get_bucket_usage_bytes "$READER" "$BUCKET" || echo 0)"
    [[ -z "$STORAGE_USAGE_BYTES" ]] && STORAGE_USAGE_BYTES=0

    STORAGE_USAGE_RATIO="$(awk -v u="$STORAGE_USAGE_BYTES" -v l="$BACKUP_FREE_LIMIT_BYTES" \
        'BEGIN { if (l > 0) printf "%.4f", u/l; else print "0" }')"

    log INFO "사용량: ${STORAGE_USAGE_BYTES} bytes / 한도 ${BACKUP_FREE_LIMIT_BYTES} bytes (ratio=${STORAGE_USAGE_RATIO})"

    local above_threshold
    above_threshold="$(awk -v r="$STORAGE_USAGE_RATIO" -v t="$THRESHOLD_RATIO" \
        'BEGIN { print (r >= t) ? 1 : 0 }')"

    if [[ "$above_threshold" == "1" ]]; then
        if [[ -f "$THRESHOLD_FLAG" ]]; then
            log INFO "임계 이미 알림됨 (재발송 억제, 회복 시 상태 파일 자동 삭제)"
        else
            if (( DRY_RUN )); then
                log WARN "[DRY-RUN] 임계 알림 스킵"
            else
                notify_slack WARN "storage-threshold" \
                    "저장소 사용량이 한도의 ${STORAGE_USAGE_RATIO} 도달 (${STORAGE_USAGE_BYTES} / ${BACKUP_FREE_LIMIT_BYTES} bytes)"
                touch "$THRESHOLD_FLAG"
                log INFO "임계 알림 발송 + 상태 파일 생성: ${THRESHOLD_FLAG}"
            fi
        fi
    else
        # 임계 회복
        if [[ -f "$THRESHOLD_FLAG" ]]; then
            rm -f "$THRESHOLD_FLAG"
            log INFO "임계 회복 → 상태 파일 삭제: ${THRESHOLD_FLAG}"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════
# 메트릭 조립 (별도 파일: q_asker_verify.prom, Q1=b)
# ═══════════════════════════════════════════════════════════

emit_verify_metrics() {
    local now_epoch
    now_epoch="$(date -u +%s)"

    local content=""
    content+="# HELP q_asker_backup_verify_success_total Successful integrity re-checks"$'\n'
    content+="# TYPE q_asker_backup_verify_success_total counter"$'\n'
    content+="# HELP q_asker_backup_verify_fail_total Failed integrity re-checks (moved to quarantine/)"$'\n'
    content+="# TYPE q_asker_backup_verify_fail_total counter"$'\n'
    content+="# HELP q_asker_backup_verify_download_error_total Download failures during verify"$'\n'
    content+="# TYPE q_asker_backup_verify_download_error_total counter"$'\n'
    content+="# HELP q_asker_backup_verify_last_run_timestamp Last verify.sh run epoch seconds"$'\n'
    content+="# TYPE q_asker_backup_verify_last_run_timestamp gauge"$'\n'
    content+="# HELP q_asker_backup_storage_usage_bytes Bucket approximate-size in bytes"$'\n'
    content+="# TYPE q_asker_backup_storage_usage_bytes gauge"$'\n'
    content+="# HELP q_asker_backup_storage_usage_ratio Usage / limit"$'\n'
    content+="# TYPE q_asker_backup_storage_usage_ratio gauge"$'\n'
    content+="# HELP q_asker_backup_storage_limit_bytes Configured free-tier limit"$'\n'
    content+="# TYPE q_asker_backup_storage_limit_bytes gauge"$'\n'

    local s
    for s in prometheus loki; do
        content+="q_asker_backup_verify_success_total{store=\"${s}\"} ${SUCCESS[$s]:-0}"$'\n'
        content+="q_asker_backup_verify_fail_total{store=\"${s}\"} ${FAIL[$s]:-0}"$'\n'
        content+="q_asker_backup_verify_download_error_total{store=\"${s}\"} ${DOWNLOAD_ERR[$s]:-0}"$'\n'
    done

    content+="q_asker_backup_verify_last_run_timestamp ${now_epoch}"$'\n'
    content+="q_asker_backup_storage_usage_bytes ${STORAGE_USAGE_BYTES}"$'\n'
    content+="q_asker_backup_storage_usage_ratio ${STORAGE_USAGE_RATIO}"$'\n'
    content+="q_asker_backup_storage_limit_bytes ${BACKUP_FREE_LIMIT_BYTES}"$'\n'

    write_metrics_atomic "$content" "q_asker_verify.prom"
}

# ═══════════════════════════════════════════════════════════
# 메인
# ═══════════════════════════════════════════════════════════

TOTAL_START=$SECONDS

trap 'log ERROR "예상치 못한 오류 (line=$LINENO)"; notify_slack ERROR "verify" "예상치 못한 오류 line=$LINENO"' ERR

if [[ "$SCOPE" == "all" || "$SCOPE" == "prometheus" ]]; then
    verify_store prometheus || true
fi

if [[ "$SCOPE" == "all" || "$SCOPE" == "loki" ]]; then
    verify_store loki || true
fi

check_storage_threshold

emit_verify_metrics

# ─── 종료 코드 결정 ───
TOTAL_FAIL=0
TOTAL_DL_ERR=0
TOTAL_SUCCESS=0
for s in prometheus loki; do
    TOTAL_FAIL=$(( TOTAL_FAIL + ${FAIL[$s]:-0} ))
    TOTAL_DL_ERR=$(( TOTAL_DL_ERR + ${DOWNLOAD_ERR[$s]:-0} ))
    TOTAL_SUCCESS=$(( TOTAL_SUCCESS + ${SUCCESS[$s]:-0} ))
done

TOTAL_DURATION=$(( SECONDS - TOTAL_START ))
log INFO "===== verify.sh 완료: 성공=${TOTAL_SUCCESS}, 실패=${TOTAL_FAIL}, DL오류=${TOTAL_DL_ERR}, 소요=${TOTAL_DURATION}s ====="

if (( TOTAL_FAIL > 0 || TOTAL_DL_ERR > 0 )); then
    exit 1
fi

log INFO "verify.sh 정상 종료"
exit 0
