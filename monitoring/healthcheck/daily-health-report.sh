#!/usr/bin/env bash
# =============================================================
# daily-health-report.sh — Q-Asker 스택 일일 헬스 리포트 (Slack 발송)
# =============================================================
# 사용법:
#   ./daily-health-report.sh [--dry-run] [--debug]
#
#   --dry-run : Slack 발송·메트릭 기록 없이 리포트 본문만 stdout으로 출력
#   --debug   : set -x
#
# 흐름:
#   1) monitoring/.env 로드
#   2) Prometheus / Loki 에 항목별 쿼리를 던져 값을 얻는다
#   3) 항목마다 정상(0)·주의(1)·위험(2)·확인 불가(3)를 판정한다
#   4) 그룹별로 한 줄씩 요약한 Slack 메시지를 만들어 발송한다 (정상이어도 매일 발송)
#   5) 판정 결과를 textfile collector 메트릭으로 노출한다
#      → 헬스체크 대시보드(q-asker-health-overview)의 ⑤ 행이 이 값을 읽는다
#
# 이 리포트는 "장애 알림"이 아니라 "매일 살아있음을 확인하는 정기 보고"다.
# 즉시성이 필요한 에러 알림은 Grafana 알림 규칙(#알림-에러)이 따로 담당한다.
#
# 종료 코드: 0=리포트 발송 성공(내용이 위험이어도 0), 1=발송 실패, 2=인자 오류

set -euo pipefail

# ─── 경로 계산 ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 로깅·환경 로드·메트릭 기록은 백업 스크립트의 공통 라이브러리를 재사용한다.
# shellcheck source=../backup-scripts/lib/backup-common.sh
source "${MONITORING_DIR}/backup-scripts/lib/backup-common.sh"

# ─── 인자 파싱 ───
DRY_RUN=0
DEBUG=0

while (( $# > 0 )); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --debug)   DEBUG=1 ;;
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

(( DEBUG )) && set -x

load_env "$MONITORING_DIR"
require_cmd curl jq awk

# ═══════════════════════════════════════════════════════════
# 설정 (.env 또는 환경 변수로 override 가능)
# ═══════════════════════════════════════════════════════════

# 조회 대상 — OCI-3 호스트에서 실행하므로 localhost 포트 매핑을 쓴다.
: "${HEALTH_PROM_URL:=http://localhost:9090}"
: "${HEALTH_LOKI_URL:=http://localhost:3100}"
: "${HEALTH_QUERY_TIMEOUT:=15}"
: "${HEALTH_DASHBOARD_URL:=https://mon.q-asker.com/d/q-asker-health-overview}"

# Slack 웹훅 — 전용 채널이 없으면 백업 채널로 보낸다(웹훅 미설정 시 로그만 남기고 스킵).
: "${SLACK_HEALTH_WEBHOOK_URL:=${SLACK_BACKUP_WEBHOOK_URL:-}}"

# 임계값 — 주의(WARN) / 위험(CRIT)
: "${HEALTH_FRESHNESS_WARN_S:=60}"      # 노드 메트릭 지연
: "${HEALTH_FRESHNESS_CRIT_S:=300}"
: "${HEALTH_5XX_WARN_PCT:=1}"           # 24시간 5xx 비율
: "${HEALTH_5XX_CRIT_PCT:=5}"
: "${HEALTH_ERRORLOG_WARN:=1}"          # 24시간 ERROR 로그 건수
: "${HEALTH_ERRORLOG_CRIT:=50}"
: "${HEALTH_RESTART_WARN:=1}"           # 24시간 API 재시작 횟수
: "${HEALTH_RESTART_CRIT:=3}"
: "${HEALTH_CPU_WARN_PCT:=80}"          # 24시간 평균 CPU
: "${HEALTH_CPU_CRIT_PCT:=90}"
: "${HEALTH_MEM_WARN_PCT:=85}"
: "${HEALTH_MEM_CRIT_PCT:=93}"
: "${HEALTH_DISK_WARN_PCT:=85}"
: "${HEALTH_DISK_CRIT_PCT:=92}"
: "${HEALTH_PLG_BACKUP_WARN_S:=172800}" # PLG 백업 경과 (48시간 / 60시간)
: "${HEALTH_PLG_BACKUP_CRIT_S:=216000}"
: "${HEALTH_MYSQL_BACKUP_WARN_S:=32400}" # MySQL L2 백업 경과 (9시간 / 24시간)
: "${HEALTH_MYSQL_BACKUP_CRIT_S:=86400}"
: "${HEALTH_STORAGE_WARN_PCT:=80}"      # 백업 버킷 사용률
: "${HEALTH_STORAGE_CRIT_PCT:=90}"
: "${HEALTH_LOGINGEST_WARN:=1}"         # 24시간 로그 유입 줄 수 (적을수록 나쁨)
: "${HEALTH_LOGINGEST_CRIT:=1}"

# 애플리케이션 메트릭의 application 라벨 (actuator.yml의 management.metrics.tags.application)
: "${HEALTH_APP_LABEL:=q-asker-api}"

readonly ST_OK=0 ST_WARN=1 ST_CRIT=2 ST_UNKNOWN=3

# ═══════════════════════════════════════════════════════════
# ① 쿼리 헬퍼
# ═══════════════════════════════════════════════════════════

# promql <query>
#   stdout: 첫 결과의 스칼라 값. 조회 실패·빈 결과·NaN이면 비어 있고 exit 1.
promql() {
    local query="$1" out status value
    out="$(curl -sfG --max-time "$HEALTH_QUERY_TIMEOUT" \
        --data-urlencode "query=${query}" \
        "${HEALTH_PROM_URL}/api/v1/query" 2>/dev/null)" || {
        log WARN "Prometheus 조회 실패: ${query}"
        return 1
    }
    status="$(jq -r '.status // "error"' <<<"$out")"
    [[ "$status" == "success" ]] || { log WARN "Prometheus 응답 오류: ${query}"; return 1; }
    value="$(jq -r '.data.result[0].value[1] // empty' <<<"$out")"
    [[ -n "$value" && "$value" != "NaN" ]] || return 1
    printf '%s' "$value"
}

# promql_label <query> <label>
#   stdout: 첫 결과의 라벨 값 (topk 결과에서 "어느 노드인지"를 뽑는 용도)
promql_label() {
    local query="$1" label="$2" out
    out="$(curl -sfG --max-time "$HEALTH_QUERY_TIMEOUT" \
        --data-urlencode "query=${query}" \
        "${HEALTH_PROM_URL}/api/v1/query" 2>/dev/null)" || return 1
    jq -r --arg l "$label" '.data.result[0].metric[$l] // empty' <<<"$out"
}

# logql <query>
#   Loki instant query. stdout: 첫 결과의 스칼라 값.
logql() {
    local query="$1" out status value
    out="$(curl -sfG --max-time "$HEALTH_QUERY_TIMEOUT" \
        --data-urlencode "query=${query}" \
        "${HEALTH_LOKI_URL}/loki/api/v1/query" 2>/dev/null)" || {
        log WARN "Loki 조회 실패: ${query}"
        return 1
    }
    status="$(jq -r '.status // "error"' <<<"$out")"
    [[ "$status" == "success" ]] || { log WARN "Loki 응답 오류: ${query}"; return 1; }
    # 결과가 비어 있으면(=해당 로그가 한 줄도 없음) 0으로 본다.
    value="$(jq -r '.data.result[0].value[1] // "0"' <<<"$out")"
    [[ -n "$value" && "$value" != "NaN" ]] || return 1
    printf '%s' "$value"
}

# ═══════════════════════════════════════════════════════════
# ② 수치 유틸 (bash 정수 연산으로는 부족해 awk를 쓴다)
# ═══════════════════════════════════════════════════════════

# ge <a> <b> — a >= b 이면 참
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

# fmt_num <value> [소수 자릿수]
fmt_num() { awk -v v="$1" -v d="${2:-1}" 'BEGIN{printf "%.*f", d, v}'; }

# fmt_pct <value> — "12.3%"
fmt_pct() { printf '%s%%' "$(fmt_num "$1" 1)"; }

# fmt_pct2 <value> — "0.04%" (0에 가까운 비율은 소수 두 자리라야 의미가 보인다)
fmt_pct2() { printf '%s%%' "$(fmt_num "$1" 2)"; }

# fmt_cnt <value> — "3건"
fmt_cnt() { awk -v v="$1" 'BEGIN{printf "%d건", v}'; }

# fmt_times <value> — "2회"
fmt_times() { awk -v v="$1" 'BEGIN{printf "%d회", v}'; }

# fmt_count <value> — 큰 수는 만/억 단위로 줄여 읽기 쉽게
fmt_count() {
    awk -v v="$1" 'BEGIN{
        if (v >= 100000000) printf "%.1f억줄", v/100000000;
        else if (v >= 10000) printf "%.1f만줄", v/10000;
        else printf "%d줄", v;
    }'
}

# fmt_secs <seconds> — "3일 4시간" / "2시간 11분" / "42초"
fmt_secs() {
    awk -v v="$1" 'BEGIN{
        v = int(v);
        if (v < 0) v = 0;
        d = int(v/86400); h = int((v%86400)/3600); m = int((v%3600)/60); s = v%60;
        if (d > 0)      printf "%d일 %d시간", d, h;
        else if (h > 0) printf "%d시간 %d분", h, m;
        else if (m > 0) printf "%d분", m;
        else            printf "%d초", s;
    }'
}

# fmt_ago <seconds> — 경과 시간 표현
fmt_ago() { printf '%s 전' "$(fmt_secs "$1")"; }

# fmt_reqps <value>
fmt_reqps() { printf '%s req/s' "$(fmt_num "$1" 2)"; }

# ═══════════════════════════════════════════════════════════
# ③ 판정 결과 축적
# ═══════════════════════════════════════════════════════════

CK_NAME=(); CK_TITLE=(); CK_GROUP=(); CK_STATUS=(); CK_TEXT=()

# record <name> <group> <title> <status> <text>
record() {
    CK_NAME+=("$1")
    CK_GROUP+=("$2")
    CK_TITLE+=("$3")
    CK_STATUS+=("$4")
    CK_TEXT+=("$5")
}

# classify_high <value> <warn> <crit> — 값이 클수록 나쁜 지표
classify_high() {
    if ge "$1" "$3"; then echo "$ST_CRIT"
    elif ge "$1" "$2"; then echo "$ST_WARN"
    else echo "$ST_OK"; fi
}

# classify_low <value> <warn> <crit> — 값이 작을수록 나쁜 지표
classify_low() {
    if ! ge "$1" "$3"; then echo "$ST_CRIT"
    elif ! ge "$1" "$2"; then echo "$ST_WARN"
    else echo "$ST_OK"; fi
}

# check_up <name> <group> <title> <query>
#   1이면 정상, 0이면 위험, 조회 실패면 확인 불가
check_up() {
    local name="$1" group="$2" title="$3" query="$4" v
    if ! v="$(promql "$query")"; then
        record "$name" "$group" "$title" "$ST_UNKNOWN" "확인 불가"
        return 0
    fi
    if ge "$v" 1; then
        record "$name" "$group" "$title" "$ST_OK" "정상"
    else
        record "$name" "$group" "$title" "$ST_CRIT" "중단"
    fi
}

# check_metric <name> <group> <title> <query> <warn> <crit> <high|low> <formatter> [단서]
#   formatter: 값을 사람이 읽는 문자열로 바꾸는 함수 이름
#   단서: 값 뒤에 덧붙일 문자열 (예: 어느 노드인지)
check_metric() {
    local name="$1" group="$2" title="$3" query="$4"
    local warn="$5" crit="$6" dir="$7" formatter="$8" hint="${9:-}"
    local v st text
    if ! v="$(promql "$query")"; then
        record "$name" "$group" "$title" "$ST_UNKNOWN" "확인 불가"
        return 0
    fi
    if [[ "$dir" == "high" ]]; then
        st="$(classify_high "$v" "$warn" "$crit")"
    else
        st="$(classify_low "$v" "$warn" "$crit")"
    fi
    text="$("$formatter" "$v")"
    [[ -n "$hint" ]] && text="${text} (${hint})"
    record "$name" "$group" "$title" "$st" "$text"
}

# check_log_metric — Loki 쿼리 버전 (인자 규약은 check_metric과 동일)
check_log_metric() {
    local name="$1" group="$2" title="$3" query="$4"
    local warn="$5" crit="$6" dir="$7" formatter="$8"
    local v st
    if ! v="$(logql "$query")"; then
        record "$name" "$group" "$title" "$ST_UNKNOWN" "확인 불가"
        return 0
    fi
    if [[ "$dir" == "high" ]]; then
        st="$(classify_high "$v" "$warn" "$crit")"
    else
        st="$(classify_low "$v" "$warn" "$crit")"
    fi
    record "$name" "$group" "$title" "$st" "$("$formatter" "$v")"
}

# ═══════════════════════════════════════════════════════════
# ④ 항목별 점검
# ═══════════════════════════════════════════════════════════

APP="$HEALTH_APP_LABEL"

run_checks() {
    local g

    # ─── 서비스 가동 ───
    g="서비스 가동"
    check_up api_server_up    "$g" "API 서버"    'up{job="spring-boot"}'
    check_up loki_up          "$g" "Loki"        'up{job="loki"}'
    check_up prometheus_up    "$g" "Prometheus"  'up{job="prometheus"}'
    check_up grafana_up       "$g" "Grafana"     'up{job="grafana"}'
    check_up alloy_up         "$g" "Alloy"       'up{job="alloy-monitoring"}'
    check_up mysql_up         "$g" "MySQL"       'mysql_up{instance="heatwave-mysql"}'

    # ─── 수집 파이프라인 ───
    g="수집 파이프라인"
    check_metric metrics_freshness_api "$g" "API 메트릭 지연" \
        'time() - node_time_seconds{instance="springboot"}' \
        "$HEALTH_FRESHNESS_WARN_S" "$HEALTH_FRESHNESS_CRIT_S" high fmt_secs
    check_metric metrics_freshness_mon "$g" "모니터링 메트릭 지연" \
        'time() - node_time_seconds{instance="monitoring"}' \
        "$HEALTH_FRESHNESS_WARN_S" "$HEALTH_FRESHNESS_CRIT_S" high fmt_secs
    check_log_metric log_ingest_24h "$g" "로그 유입(24h)" \
        'sum(count_over_time({host=~".+"}[24h]))' \
        "$HEALTH_LOGINGEST_WARN" "$HEALTH_LOGINGEST_CRIT" low fmt_count

    # ─── 애플리케이션 ───
    g="애플리케이션"
    check_metric http_5xx_ratio "$g" "5xx 비율(24h)" \
        "(sum(increase(http_server_requests_seconds_count{application=\"${APP}\", status=~\"5..\"}[24h])) or vector(0)) / sum(increase(http_server_requests_seconds_count{application=\"${APP}\"}[24h])) * 100" \
        "$HEALTH_5XX_WARN_PCT" "$HEALTH_5XX_CRIT_PCT" high fmt_pct2
    check_log_metric error_logs_24h "$g" "ERROR 로그(24h)" \
        'sum(count_over_time({level="ERROR"}[24h]))' \
        "$HEALTH_ERRORLOG_WARN" "$HEALTH_ERRORLOG_CRIT" high fmt_cnt
    check_circuit_breaker "$g"
    check_metric api_restarts_24h "$g" "API 재시작(24h)" \
        "resets(process_uptime_seconds{application=\"${APP}\"}[24h]) or vector(0)" \
        "$HEALTH_RESTART_WARN" "$HEALTH_RESTART_CRIT" high fmt_times
    check_metric request_rate "$g" "요청률(24h 평균)" \
        "sum(rate(http_server_requests_seconds_count{application=\"${APP}\"}[24h]))" \
        999999 999999 high fmt_reqps

    # ─── 노드 리소스 ───
    # topk(1)로 가장 나쁜 노드 하나만 뽑고, 어느 노드인지 라벨로 덧붙인다.
    g="노드 리소스"
    local q_cpu q_mem q_disk
    q_cpu='topk(1, 100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[24h])) * 100))'
    q_mem='topk(1, (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100)'
    q_disk='topk(1, (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs", mountpoint=~"/|/mnt/monitoring"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs", mountpoint=~"/|/mnt/monitoring"}) * 100)'

    check_metric cpu_max "$g" "CPU 최대" "$q_cpu" \
        "$HEALTH_CPU_WARN_PCT" "$HEALTH_CPU_CRIT_PCT" high fmt_pct \
        "$(promql_label "$q_cpu" instance || true)"
    check_metric mem_max "$g" "메모리 최대" "$q_mem" \
        "$HEALTH_MEM_WARN_PCT" "$HEALTH_MEM_CRIT_PCT" high fmt_pct \
        "$(promql_label "$q_mem" instance || true)"
    check_metric disk_max "$g" "디스크 최대" "$q_disk" \
        "$HEALTH_DISK_WARN_PCT" "$HEALTH_DISK_CRIT_PCT" high fmt_pct \
        "$(promql_label "$q_disk" instance || true) $(promql_label "$q_disk" mountpoint || true)"

    # ─── 백업 ───
    g="백업"
    check_metric plg_backup_age "$g" "PLG 백업" \
        'time() - max(q_asker_backup_last_success_timestamp)' \
        "$HEALTH_PLG_BACKUP_WARN_S" "$HEALTH_PLG_BACKUP_CRIT_S" high fmt_ago
    check_metric mysql_backup_age "$g" "MySQL 백업" \
        'time() - oci_mysql_backup_last_success_timestamp_seconds' \
        "$HEALTH_MYSQL_BACKUP_WARN_S" "$HEALTH_MYSQL_BACKUP_CRIT_S" high fmt_ago
    check_metric backup_storage "$g" "백업 저장소" \
        'q_asker_backup_storage_usage_ratio * 100' \
        "$HEALTH_STORAGE_WARN_PCT" "$HEALTH_STORAGE_CRIT_PCT" high fmt_pct
}

# 서킷브레이커는 "지금 열려 있는가"와 "지난 24시간에 열린 적 있는가"를 함께 본다.
check_circuit_breaker() {
    local group="$1" now hist
    now="$(promql "max(resilience4j_circuitbreaker_state{application=\"${APP}\", name=\"aiServer\", state=\"open\"})" || true)"
    hist="$(promql "max(max_over_time(resilience4j_circuitbreaker_state{application=\"${APP}\", name=\"aiServer\", state=\"open\"}[24h]))" || true)"

    if [[ -z "$now" && -z "$hist" ]]; then
        record circuit_breaker "$group" "서킷브레이커" "$ST_UNKNOWN" "확인 불가"
    elif [[ -n "$now" ]] && ge "$now" 1; then
        record circuit_breaker "$group" "서킷브레이커" "$ST_CRIT" "현재 OPEN"
    elif [[ -n "$hist" ]] && ge "$hist" 1; then
        record circuit_breaker "$group" "서킷브레이커" "$ST_WARN" "24h 내 OPEN 이력"
    else
        record circuit_breaker "$group" "서킷브레이커" "$ST_OK" "CLOSED 유지"
    fi
}

# ═══════════════════════════════════════════════════════════
# ⑤ 리포트 조립
# ═══════════════════════════════════════════════════════════

status_emoji() {
    case "$1" in
        "$ST_OK")   printf '✅' ;;
        "$ST_WARN") printf '⚠️' ;;
        "$ST_CRIT") printf '❌' ;;
        *)          printf '❔' ;;
    esac
}

status_word() {
    case "$1" in
        "$ST_OK")   printf '정상' ;;
        "$ST_WARN") printf '주의' ;;
        "$ST_CRIT") printf '위험' ;;
        *)          printf '확인 불가' ;;
    esac
}

COUNT_OK=0; COUNT_WARN=0; COUNT_CRIT=0; COUNT_UNKNOWN=0; OVERALL=$ST_OK

summarize() {
    local i st
    for i in "${!CK_NAME[@]}"; do
        st="${CK_STATUS[$i]}"
        case "$st" in
            "$ST_OK")   COUNT_OK=$(( COUNT_OK + 1 )) ;;
            "$ST_WARN") COUNT_WARN=$(( COUNT_WARN + 1 )) ;;
            "$ST_CRIT") COUNT_CRIT=$(( COUNT_CRIT + 1 )) ;;
            *)          COUNT_UNKNOWN=$(( COUNT_UNKNOWN + 1 )) ;;
        esac
    done
    # 종합 판정: 위험 > 확인 불가 > 주의 > 정상
    if (( COUNT_CRIT > 0 )); then OVERALL=$ST_CRIT
    elif (( COUNT_UNKNOWN > 0 )); then OVERALL=$ST_UNKNOWN
    elif (( COUNT_WARN > 0 )); then OVERALL=$ST_WARN
    else OVERALL=$ST_OK; fi
}

# 그룹별 한 줄 요약 + 문제 항목 별도 표기
build_body() {
    local i g seen line body attention=""
    local groups=()

    # 등장 순서대로 그룹 목록 수집
    for i in "${!CK_GROUP[@]}"; do
        seen=0
        for g in ${groups[@]+"${groups[@]}"}; do
            [[ "$g" == "${CK_GROUP[$i]}" ]] && { seen=1; break; }
        done
        (( seen )) || groups+=("${CK_GROUP[$i]}")
    done

    body=""
    for g in "${groups[@]}"; do
        line=""
        for i in "${!CK_NAME[@]}"; do
            [[ "${CK_GROUP[$i]}" == "$g" ]] || continue
            [[ -n "$line" ]] && line+="  ·  "
            line+="$(status_emoji "${CK_STATUS[$i]}") ${CK_TITLE[$i]} ${CK_TEXT[$i]}"
        done
        body+="*${g}*"$'\n'"${line}"$'\n\n'
    done

    # 정상이 아닌 항목만 모아 맨 위에 다시 보여준다 (스크롤 없이 눈에 걸리도록)
    local word
    for i in "${!CK_NAME[@]}"; do
        [[ "${CK_STATUS[$i]}" == "$ST_OK" ]] && continue
        [[ -n "$attention" ]] && attention+=", "
        word="$(status_word "${CK_STATUS[$i]}")"
        if [[ "${CK_TEXT[$i]}" == "$word" ]]; then
            attention+="${CK_TITLE[$i]}(${word})"
        else
            attention+="${CK_TITLE[$i]}(${word}: ${CK_TEXT[$i]})"
        fi
    done
    if [[ -n "$attention" ]]; then
        body="*확인 필요*: ${attention}"$'\n\n'"${body}"
    fi

    body+="👉 <${HEALTH_DASHBOARD_URL}|헬스체크 대시보드에서 확인>"
    printf '%s' "$body"
}

build_header() {
    local today total
    today="$(TZ=Asia/Seoul date +'%Y-%m-%d %H:%M')"
    total=$(( COUNT_OK + COUNT_WARN + COUNT_CRIT + COUNT_UNKNOWN ))
    if (( OVERALL == ST_OK )); then
        printf '%s *Q-Asker 일일 헬스 리포트* — %s KST\n전체 상태: *정상* — %d개 항목 전부 통과' \
            "$(status_emoji "$OVERALL")" "$today" "$total"
    else
        printf '%s *Q-Asker 일일 헬스 리포트* — %s KST\n전체 상태: *%s* — 정상 %d · 주의 %d · 위험 %d · 확인 불가 %d (총 %d)' \
            "$(status_emoji "$OVERALL")" "$today" "$(status_word "$OVERALL")" \
            "$COUNT_OK" "$COUNT_WARN" "$COUNT_CRIT" "$COUNT_UNKNOWN" "$total"
    fi
}

attachment_color() {
    case "$OVERALL" in
        "$ST_OK")   printf '#2eb67d' ;;
        "$ST_WARN") printf '#ecb22e' ;;
        "$ST_CRIT") printf '#e01e5a' ;;
        *)          printf '#717274' ;;
    esac
}

# ═══════════════════════════════════════════════════════════
# ⑥ Slack 발송
# ═══════════════════════════════════════════════════════════

send_slack() {
    local header="$1" body="$2" payload

    if [[ -z "${SLACK_HEALTH_WEBHOOK_URL:-}" ]]; then
        log WARN "SLACK_HEALTH_WEBHOOK_URL(및 SLACK_BACKUP_WEBHOOK_URL) 미설정 — Slack 발송 스킵"
        return 0
    fi

    payload="$(jq -n \
        --arg text "$header" \
        --arg body "$body" \
        --arg color "$(attachment_color)" \
        '{
            text: $text,
            attachments: [{
                color: $color,
                mrkdwn_in: ["text"],
                text: $body
            }]
        }')"

    if curl -sf --max-time 15 -X POST \
        -H 'Content-Type: application/json' \
        --data "$payload" \
        "$SLACK_HEALTH_WEBHOOK_URL" >/dev/null; then
        log INFO "Slack 일일 헬스 리포트 발송 완료 (판정: $(status_word "$OVERALL"))"
        return 0
    fi
    log ERROR "Slack 발송 실패 (webhook 응답 이상)"
    return 1
}

# ═══════════════════════════════════════════════════════════
# ⑦ Prometheus textfile 메트릭 노출
# ═══════════════════════════════════════════════════════════

write_health_metrics() {
    local content="" i now
    now="$(date +%s)"

    content+="# HELP q_asker_health_check_status Daily health check status (0=ok,1=warn,2=crit,3=unknown)"$'\n'
    content+="# TYPE q_asker_health_check_status gauge"$'\n'
    for i in "${!CK_NAME[@]}"; do
        content+="q_asker_health_check_status{check=\"${CK_NAME[$i]}\",title=\"${CK_TITLE[$i]}\",group=\"${CK_GROUP[$i]}\"} ${CK_STATUS[$i]}"$'\n'
    done

    content+="# HELP q_asker_health_overall_status Overall daily health verdict (0=ok,1=warn,2=crit,3=unknown)"$'\n'
    content+="# TYPE q_asker_health_overall_status gauge"$'\n'
    content+="q_asker_health_overall_status ${OVERALL}"$'\n'

    content+="# HELP q_asker_health_check_total Number of checks per status"$'\n'
    content+="# TYPE q_asker_health_check_total gauge"$'\n'
    content+="q_asker_health_check_total{status=\"ok\"} ${COUNT_OK}"$'\n'
    content+="q_asker_health_check_total{status=\"warn\"} ${COUNT_WARN}"$'\n'
    content+="q_asker_health_check_total{status=\"crit\"} ${COUNT_CRIT}"$'\n'
    content+="q_asker_health_check_total{status=\"unknown\"} ${COUNT_UNKNOWN}"$'\n'

    content+="# HELP q_asker_health_report_last_run_timestamp Last daily report run epoch seconds"$'\n'
    content+="# TYPE q_asker_health_report_last_run_timestamp gauge"$'\n'
    content+="q_asker_health_report_last_run_timestamp ${now}"$'\n'

    write_metrics_atomic "$content" "q_asker_health.prom"
}

# ═══════════════════════════════════════════════════════════
# ⑧ 메인
# ═══════════════════════════════════════════════════════════

main() {
    log INFO "일일 헬스 리포트 시작 (prometheus=${HEALTH_PROM_URL}, loki=${HEALTH_LOKI_URL})"

    run_checks
    summarize

    local header body
    header="$(build_header)"
    body="$(build_body)"

    if (( DRY_RUN )); then
        log INFO "--dry-run — Slack 발송·메트릭 기록을 건너뛰고 본문만 출력한다"
        printf '%s\n\n%s\n' "$header" "$body"
        return 0
    fi

    write_health_metrics

    send_slack "$header" "$body" || return 1
    return 0
}

main
