#!/usr/bin/env bash
# =============================================================
# backup-common.sh — Prometheus/Loki 백업·복구·검증 공통 함수 라이브러리
# (plg-stack: specs/001-prometheus-loki-backup-recovery)
# =============================================================
# 사용법:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/backup-common.sh"
#
# 이 파일은 스탠드얼론 실행하지 않는다. backup.sh / restore.sh / verify.sh가
# source 로 불러다 쓴다.
#
# 의존:
#   - bash 4+
#   - oci CLI (--profile 기능)
#   - curl, jq, tar, gzip, sha256sum (coreutils)
#
# 규칙:
#   - bash -euo pipefail (호출 스크립트가 설정)
#   - snake_case, 4-space indentation, shellcheck 호환
#   - 한국어 주석
#   - 표준 출력에는 스크립트 결과만, 로그는 stderr로 (Alloy가 stdout/stderr 모두 수집)

# ═══════════════════════════════════════════════════════════
# 상수 (호출 스크립트가 override 가능)
# ═══════════════════════════════════════════════════════════

: "${BACKUP_TMP_DIR:=/mnt/monitoring/backup-tmp}"
: "${TEXTFILE_DIR:=/var/lib/node_exporter/textfile_collector}"
: "${OCI_RETRY_MAX:=3}"
: "${OCI_RETRY_BASE_SLEEP:=5}"
: "${LOKI_DOWNTIME_LIMIT_SEC:=60}"

# ═══════════════════════════════════════════════════════════
# ① 로깅
# ═══════════════════════════════════════════════════════════

# log <LEVEL> <MSG...>
# 표준 에러로 [ISO8601 UTC] [LEVEL] [pid] MSG 형식 출력
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '[%s] [%-5s] [pid=%d] %s\n' "$ts" "$level" "$$" "$msg" >&2
}

# ═══════════════════════════════════════════════════════════
# ② 환경 변수 검증
# ═══════════════════════════════════════════════════════════

# require_env VAR1 VAR2 ...
# 미설정 변수가 있으면 로그 남기고 exit 1
require_env() {
    local missing=()
    local v
    for v in "$@"; do
        if [[ -z "${!v:-}" ]]; then
            missing+=("$v")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        log ERROR "필수 환경 변수 누락: ${missing[*]}"
        return 1
    fi
}

# require_cmd CMD1 CMD2 ...
# 명령이 PATH에 없으면 exit 1
require_cmd() {
    local missing=()
    local c
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            missing+=("$c")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        log ERROR "필수 명령 미설치: ${missing[*]}"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════
# ③ 해시 (SHA-256)
# ═══════════════════════════════════════════════════════════

# hash_file <path> → stdout: 64자 hex
hash_file() {
    local file="$1"
    sha256sum "$file" | awk '{print $1}'
}

# ═══════════════════════════════════════════════════════════
# ④ 재시도 유틸
# ═══════════════════════════════════════════════════════════

# run_with_retry <max_attempts> <cmd...>
# 실패 시 지수 백오프. 최종 실패 시 마지막 exit code 리턴.
run_with_retry() {
    local max="$1"; shift
    local attempt=1
    local sleep_sec="$OCI_RETRY_BASE_SLEEP"
    local rc=0

    while (( attempt <= max )); do
        if "$@"; then
            return 0
        fi
        rc=$?
        if (( attempt < max )); then
            log WARN "명령 실패 (exit=$rc, 시도 $attempt/$max), ${sleep_sec}s 후 재시도: $*"
            sleep "$sleep_sec"
            sleep_sec=$(( sleep_sec * 2 ))
        fi
        attempt=$(( attempt + 1 ))
    done
    log ERROR "명령 최종 실패 (${max}회 시도): $*"
    return "$rc"
}

# ═══════════════════════════════════════════════════════════
# ⑤ OCI Object Storage 래퍼
# ═══════════════════════════════════════════════════════════

# _oci_call <profile> <cmd...>
# oci CLI 호출을 재시도로 감싸는 내부 함수
_oci_call() {
    local profile="$1"; shift
    run_with_retry "$OCI_RETRY_MAX" oci --profile "$profile" "$@"
}

# upload_object <profile> <bucket> <key> <local_file>
upload_object() {
    local profile="$1" bucket="$2" key="$3" file="$4"
    log INFO "업로드: ${bucket}/${key} ← ${file}"
    _oci_call "$profile" os object put \
        --bucket-name "$bucket" \
        --name "$key" \
        --file "$file" \
        --force >/dev/null
}

# download_object <profile> <bucket> <key> <local_file>
download_object() {
    local profile="$1" bucket="$2" key="$3" file="$4"
    log INFO "다운로드: ${bucket}/${key} → ${file}"
    _oci_call "$profile" os object get \
        --bucket-name "$bucket" \
        --name "$key" \
        --file "$file" >/dev/null
}

# delete_object <profile> <bucket> <key>
delete_object() {
    local profile="$1" bucket="$2" key="$3"
    log INFO "삭제: ${bucket}/${key}"
    _oci_call "$profile" os object delete \
        --bucket-name "$bucket" \
        --name "$key" \
        --force >/dev/null
}

# rename_object <profile> <bucket> <src_key> <dst_key>
# 무결성 검증 실패 시 quarantine/ 이동 등에 사용
rename_object() {
    local profile="$1" bucket="$2" src="$3" dst="$4"
    log INFO "이름 변경: ${bucket}/${src} → ${dst}"
    _oci_call "$profile" os object rename \
        --bucket-name "$bucket" \
        --source-name "$src" \
        --new-name "$dst" >/dev/null
}

# list_object_keys <profile> <bucket> <prefix>
# stdout: 객체 키를 한 줄에 하나씩 (jq로 안전 파싱)
list_object_keys() {
    local profile="$1" bucket="$2" prefix="$3"
    _oci_call "$profile" os object list \
        --bucket-name "$bucket" \
        --prefix "$prefix" \
        --all \
        --output json 2>/dev/null \
        | jq -r '.data[]?.name // empty' \
        || true
}

# ═══════════════════════════════════════════════════════════
# ⑥ 인라인 무결성 검증 (FR-009 1단계)
# ═══════════════════════════════════════════════════════════

# verify_object <profile> <bucket> <key> <expected_hash> <verify_tmp_file>
#   업로드 직후 즉시 GET → 로컬 해시 재계산 → 비교
#   일치: 0, 불일치: 1 (호출자가 quarantine 처리)
verify_object() {
    local profile="$1" bucket="$2" key="$3" expected="$4" tmp="$5"

    download_object "$profile" "$bucket" "$key" "$tmp"

    local actual
    actual="$(hash_file "$tmp")"

    if [[ "$actual" == "$expected" ]]; then
        log INFO "무결성 OK: ${key} (sha256=${actual})"
        rm -f "$tmp"
        return 0
    fi

    log ERROR "무결성 불일치: ${key}"
    log ERROR "  기대: ${expected}"
    log ERROR "  실제: ${actual}"
    rm -f "$tmp"
    return 1
}

# ═══════════════════════════════════════════════════════════
# ⑦ Slack 알림 (SLACK_WEBHOOK_URL 부재 시 로그만 남기고 스킵)
# ═══════════════════════════════════════════════════════════

# notify_slack <status> <target> <detail>
#   status: SUCCESS|WARN|ERROR
notify_slack() {
    local status="$1" target="$2" detail="$3"

    if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
        log WARN "SLACK_WEBHOOK_URL 미설정 — Slack 알림 스킵: [${status}] ${target} — ${detail}"
        return 0
    fi

    local emoji="ℹ️"
    case "$status" in
        SUCCESS) emoji="✅" ;;
        WARN)    emoji="⚠️" ;;
        ERROR)   emoji="❌" ;;
    esac

    local host
    host="$(hostname -s)"

    local payload
    payload=$(jq -n \
        --arg text "${emoji} *[q-asker-backup]* ${status} — ${target}" \
        --arg detail "${detail}" \
        --arg host "${host}" \
        '{
            text: $text,
            attachments: [{
                color: (if $text | contains("ERROR") then "#e01e5a"
                        elif $text | contains("WARN") then "#ecb22e"
                        else "#2eb67d" end),
                fields: [
                    {title: "Host",   value: $host, short: true},
                    {title: "Detail", value: $detail, short: false}
                ]
            }]
        }')

    curl -sf -X POST \
        -H 'Content-Type: application/json' \
        --data "$payload" \
        "$SLACK_WEBHOOK_URL" >/dev/null \
        || log WARN "Slack 알림 전송 실패 (webhook 응답 이상)"
}

# ═══════════════════════════════════════════════════════════
# ⑧ Prometheus textfile collector 메트릭 노출
# ═══════════════════════════════════════════════════════════

# write_metrics_atomic <metrics_content> [filename]
#   TEXTFILE_DIR/<filename> 을 atomic write.
#   filename 기본값: q_asker_backup.prom (backup.sh 산출물).
#   verify.sh 등 다른 스크립트는 별도 파일명(예: q_asker_verify.prom) 지정하여
#   backup.sh와의 파일 쓰기 충돌을 회피한다 (T6 Q1=b).
write_metrics_atomic() {
    local content="$1"
    local filename="${2:-q_asker_backup.prom}"
    local target="${TEXTFILE_DIR}/${filename}"
    local tmp

    if [[ ! -d "$TEXTFILE_DIR" ]]; then
        log WARN "TEXTFILE_DIR 부재 (${TEXTFILE_DIR}) — 메트릭 노출 스킵. T5에서 alloy volume 마운트 필요."
        return 0
    fi

    tmp="$(mktemp "${target}.XXXXXX")"
    printf '%s\n' "$content" > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$target"
    log INFO "메트릭 갱신: ${target}"
}

# ═══════════════════════════════════════════════════════════
# ⑨ 보존 정리 (FR-008: 7일 초과 객체 자동 삭제)
# ═══════════════════════════════════════════════════════════

# retention_cleanup <profile> <bucket> <prefix> <days>
#   객체 키의 <YYYYMMDD>-<HHMM> 접두 날짜 기준으로 <days>일 초과 객체 삭제.
#   quarantine/ 접두는 대상 제외.
#   .sha256 metadata도 함께 삭제.
retention_cleanup() {
    local profile="$1" bucket="$2" prefix="$3" days="$4"

    if [[ "$prefix" == quarantine/* ]]; then
        log WARN "quarantine/ 접두는 retention 대상 아님. 스킵."
        return 0
    fi

    local cutoff
    cutoff="$(date -u -d "${days} days ago" +%Y%m%d 2>/dev/null || true)"
    if [[ -z "$cutoff" ]]; then
        log ERROR "cutoff 계산 실패 (GNU date 필요)."
        return 1
    fi

    log INFO "retention 정리: prefix=${prefix}, cutoff=${cutoff}, days=${days}"

    local deleted=0
    local key date_part
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        [[ "$key" == quarantine/* ]] && continue

        date_part="$(echo "$key" | grep -oE '[0-9]{8}-[0-9]{4}' | head -1 | cut -d- -f1)"
        if [[ -z "$date_part" ]]; then
            log WARN "날짜 파싱 실패, 스킵: ${key}"
            continue
        fi

        if [[ "$date_part" < "$cutoff" ]]; then
            delete_object "$profile" "$bucket" "$key" || {
                log WARN "삭제 실패 계속 진행: ${key}"
                continue
            }
            deleted=$(( deleted + 1 ))
        fi
    done < <(list_object_keys "$profile" "$bucket" "$prefix")

    log INFO "retention 완료: ${deleted}개 객체 삭제"
    return 0
}

# ═══════════════════════════════════════════════════════════
# ⑩ 복원용 유틸 (restore.sh / verify.sh 공용)
# ═══════════════════════════════════════════════════════════

# verify_local_hash <tar_file> <sha_file>
#   .sha256 파일 형식은 `<hex>  <basename>` (sha256sum 표준).
#   tar_file의 로컬 재계산 해시와 비교하여 일치 확인.
verify_local_hash() {
    local tar_file="$1"
    local sha_file="$2"
    local expected actual
    expected="$(awk '{print $1}' "$sha_file")"
    actual="$(hash_file "$tar_file")"
    if [[ "$expected" != "$actual" ]]; then
        log ERROR "로컬 해시 불일치: 기대=$expected, 실제=$actual"
        return 1
    fi
    log INFO "로컬 해시 일치: $actual"
    return 0
}

# health_poll <url> <max_attempts> <sleep_sec>
#   curl -sf 성공까지 폴링. 매 시도 사이에 sleep_sec 대기.
health_poll() {
    local url="$1"
    local max_attempts="$2"
    local sleep_sec="$3"
    local attempt

    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
            log INFO "헬스 OK (${url}, ${attempt}/${max_attempts})"
            return 0
        fi
        (( attempt < max_attempts )) && sleep "$sleep_sec"
    done
    log ERROR "헬스 미도달 (${url}, ${max_attempts}회 × ${sleep_sec}s)"
    return 1
}

# list_available_snapshots <profile> <bucket> <store>
#   stdout: 해당 스토어의 스냅샷 timestamp(YYYYMMDD-HHMM)를 정렬해 한 줄에 하나씩.
list_available_snapshots() {
    local profile="$1"
    local bucket="$2"
    local store="$3"

    list_object_keys "$profile" "$bucket" "${store}/" \
        | grep -E "\.tar\.gz$" \
        | grep -oE '[0-9]{8}-[0-9]{4}' \
        | sort -u
}

# get_bucket_usage_bytes <profile> <bucket>
#   stdout: 버킷의 approximate-size (bytes). 오류 시 0.
#   T6 verify.sh의 저장소 사용량 임계 알림 및 메트릭용.
get_bucket_usage_bytes() {
    local profile="$1"
    local bucket="$2"

    _oci_call "$profile" os bucket get \
        --bucket-name "$bucket" \
        --fields approximateSize \
        --output json 2>/dev/null \
        | jq -r '.data."approximate-size" // 0' \
        || echo 0
}

# ═══════════════════════════════════════════════════════════
# ⑪ 초기화
# ═══════════════════════════════════════════════════════════

# ensure_tmp_dir
#   BACKUP_TMP_DIR 없으면 생성 (호출 스크립트 시작 시)
ensure_tmp_dir() {
    if [[ ! -d "$BACKUP_TMP_DIR" ]]; then
        mkdir -p "$BACKUP_TMP_DIR"
        log INFO "임시 디렉토리 생성: $BACKUP_TMP_DIR"
    fi
}

# load_env <monitoring_dir>
#   monitoring/.env 파일을 export 형태로 로드. 파일 부재 시 스킵.
#   bash source 방식은 값에 `(`, `` ` ``, `$` 같은 특수문자가 있을 때
#   subshell로 해석되어 syntax error를 낸다 (예: MYSQL_DSN=user:pw@tcp(host:3306)/db).
#   정규식 라인 파싱으로 값 원문 그대로 export 하여 특수문자 안전.
load_env() {
    local mon_dir="$1"
    local env_file="${mon_dir}/.env"

    if [[ ! -f "$env_file" ]]; then
        log WARN "환경 파일 부재: ${env_file}"
        return 0
    fi

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 주석·빈 라인 스킵
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        # KEY=VALUE 패턴만 수용
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # 양끝 큰따옴표/작은따옴표 제거 (있으면)
            if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
                value="${BASH_REMATCH[1]}"
            fi
            export "$key=$value"
        fi
    done < "$env_file"
    log INFO "환경 파일 로드: ${env_file}"
}
