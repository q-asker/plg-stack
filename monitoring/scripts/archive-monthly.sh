#!/usr/bin/env bash
# =============================================================
# archive-monthly.sh — 월간 아카이브 (Standard → monthly-archive/ Archive tier)
# (plg-stack: specs/001-prometheus-loki-backup-recovery)
# =============================================================
# 목적:
#   Prometheus/Loki의 자체 retention(180일)을 넘는 옛날 로그를 장기 보존.
#   매월 1일에 전월 마지막 백업 4개(prom+loki tar.gz + sha256)를
#   monthly-archive/ prefix로 복사한 뒤 즉시 Archive tier로 이관한다.
#
# 흐름:
#   1) 전월의 가장 최신 backup timestamp 조회 (prometheus/, loki/)
#   2) 4개 객체(prom tar.gz + sha256 + loki tar.gz + sha256) 각각을
#      monthly-archive/YYYYMM-<store>.<ext>로 os object copy
#   3) 4개 객체 Archive tier로 update-storage-tier
#   4) 성공/실패 Slack 알림 + 종료
#
# 자동 삭제 정책:
#   - 버킷 lifecycle(delete-after-7d)의 exclusion-patterns에 monthly-archive/* 포함
#     → 매일 백업(prometheus/, loki/)과 달리 자동 삭제 대상에서 제외되어 영구 보존
#   - backup.sh의 80/90% 2단계 임계 알림이 저장소 압박 감지 시 알림 → 운영자 수동 정리
#   - 자동 삭제 없음 (사고 방지, 실무 표준 안전 정책)
#
# 실행: /etc/cron.d/q-asker-backup에서 매월 1일 KST 05:00 자동 실행
#      (backup.sh 03:00 이후)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/backup-common.sh
source "${SCRIPT_DIR}/lib/backup-common.sh"

load_env "$MONITORING_DIR"
require_env OCI_BUCKET_NAME OCI_WRITER_PROFILE OCI_READER_PROFILE OCI_NAMESPACE OCI_REGION
require_cmd oci jq

BUCKET="$OCI_BUCKET_NAME"
WRITER="$OCI_WRITER_PROFILE"
READER="$OCI_READER_PROFILE"

# 전월 태그 (YYYYMM). 매월 1일 실행 기준 어제 = 전월 마지막 날.
YYYY_MM="$(TZ=Asia/Seoul date --date='1 day ago' +%Y%m)"
log INFO "===== 월간 아카이브 시작 (대상: ${YYYY_MM}) ====="

archive_store() {
    local store="$1"

    # 전월 이내의 가장 최신 timestamp 찾기 (YYYYMMDD가 YYYY_MM으로 시작하는 것)
    local latest_ts
    latest_ts="$(list_available_snapshots "$READER" "$BUCKET" "$store" \
        | grep -E "^${YYYY_MM}" \
        | sort | tail -1 || true)"

    if [[ -z "$latest_ts" ]]; then
        log WARN "[${store}] 전월(${YYYY_MM}) 백업 없음 — 스킵"
        return 0
    fi

    log INFO "[${store}] 아카이브 원본 timestamp: ${latest_ts}"

    local src_tar="${store}/${latest_ts}-${store}.tar.gz"
    local src_sha="${store}/${latest_ts}-${store}.sha256"
    local dst_tar="monthly-archive/${YYYY_MM}-${store}.tar.gz"
    local dst_sha="monthly-archive/${YYYY_MM}-${store}.sha256"

    # 1) tar.gz 복사
    log INFO "[${store}] copy: ${src_tar} → ${dst_tar}"
    if ! _oci_call "$WRITER" os object copy \
            --bucket-name "$BUCKET" \
            --source-object-name "$src_tar" \
            --destination-namespace "$OCI_NAMESPACE" \
            --destination-region "$OCI_REGION" \
            --destination-bucket "$BUCKET" \
            --destination-object-name "$dst_tar" >/dev/null; then
        log ERROR "[${store}] tar.gz 복사 실패"
        return 1
    fi

    # 2) sha256 복사
    log INFO "[${store}] copy: ${src_sha} → ${dst_sha}"
    if ! _oci_call "$WRITER" os object copy \
            --bucket-name "$BUCKET" \
            --source-object-name "$src_sha" \
            --destination-namespace "$OCI_NAMESPACE" \
            --destination-region "$OCI_REGION" \
            --destination-bucket "$BUCKET" \
            --destination-object-name "$dst_sha" >/dev/null; then
        log ERROR "[${store}] sha256 복사 실패"
        return 1
    fi

    # 3) Archive tier로 이관 (tar.gz + sha256)
    for key in "$dst_tar" "$dst_sha"; do
        log INFO "[${store}] Archive tier 이관: ${key}"
        if ! _oci_call "$WRITER" os object update-storage-tier \
                --bucket-name "$BUCKET" \
                --name "$key" \
                --storage-tier Archive >/dev/null; then
            log WARN "[${store}] Archive 이관 실패(무해, 다음 실행에서 재시도): ${key}"
        fi
    done

    log INFO "[${store}] 완료: ${dst_tar}, ${dst_sha}"
    return 0
}

# ─── 실행 ───
declare -i failures=0
if ! archive_store prometheus; then
    failures=$((failures + 1))
    notify_slack ERROR "archive-monthly-prometheus" "${YYYY_MM} 아카이브 실패"
fi
if ! archive_store loki; then
    failures=$((failures + 1))
    notify_slack ERROR "archive-monthly-loki" "${YYYY_MM} 아카이브 실패"
fi

if (( failures > 0 )); then
    log ERROR "월간 아카이브 실패 store: ${failures}"
    exit 1
fi

notify_slack SUCCESS "archive-monthly" "${YYYY_MM} 월간 아카이브 완료 (prom + loki)"
log INFO "===== 월간 아카이브 정상 종료 ====="
exit 0
