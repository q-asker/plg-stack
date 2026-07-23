#!/usr/bin/env bash
# ============================================================
# 백업 주기 재조정 (라이브 적용) — MySQL(systemd timer) + PLG(cron)
# ============================================================
# 저장소 압박 시 백업 주기를 늘려 증가 속도를 낮추는 운영 도구.
# 호스트(OCI-3)에서 sudo로 실행. git 레포는 건드리지 않고 라이브 설정만 바꾼다.
#   - MySQL: systemd drop-in override로 OnCalendar 교체
#            (/etc/systemd/system/oci-mysql-backup.timer.d/10-schedule.conf)
#            → update.sh 재배포는 본체 unit만 교체하므로 drop-in은 유지된다.
#   - PLG:   /etc/cron.d/q-asker-backup 백업 라인의 스케줄 필드 in-place 교체.
#            ※ 나중에 `cp monitoring/cron/q-asker-backup /etc/cron.d/...`를 다시
#              돌리면 되돌아간다(그때 이 스크립트를 재실행하면 됨).
#
# 사용법:
#   sudo ./set-backup-schedule.sh --show                 # 현재 적용값만 확인
#   sudo ./set-backup-schedule.sh --mysql 12h            # MySQL만 12시간 주기
#   sudo ./set-backup-schedule.sh --plg 2d               # PLG만 이틀마다
#   sudo ./set-backup-schedule.sh --mysql 12h --plg 2d   # 둘 다
#
# 값 규칙:
#   --mysql <N>h : N은 24의 약수(2,3,4,6,8,12,24). UTC 00시 기준 균등 배치.
#   --plg   <N>d : N일마다 KST 03:00 (1=매일).
set -euo pipefail

CRON_FILE=/etc/cron.d/q-asker-backup
TIMER_DROPIN_DIR=/etc/systemd/system/oci-mysql-backup.timer.d
TIMER_DROPIN="$TIMER_DROPIN_DIR/10-schedule.conf"

die() { echo "❌ $*" >&2; exit 1; }

MYSQL_H=""; PLG_D=""; SHOW=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mysql) MYSQL_H="${2:?--mysql 값 필요 (예: 12h)}"; shift 2 ;;
        --plg)   PLG_D="${2:?--plg 값 필요 (예: 2d)}"; shift 2 ;;
        --show)  SHOW=1; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) die "알 수 없는 인자: $1 (--help 참고)" ;;
    esac
done

show_current() {
    echo "── 현재 적용 스케줄 ──"
    local mcal
    if [[ -f "$TIMER_DROPIN" ]]; then
        mcal="$(grep -m1 -E '^OnCalendar=.*[0-9]' "$TIMER_DROPIN" 2>/dev/null || true)"
        echo "  MySQL: ${mcal#OnCalendar=}  (drop-in override)"
    else
        mcal="$(systemctl cat oci-mysql-backup.timer 2>/dev/null | grep -m1 -E '^OnCalendar=' || true)"
        echo "  MySQL: ${mcal#OnCalendar=}  (기본 unit)"
    fi
    systemctl list-timers oci-mysql-backup.timer --no-pager 2>/dev/null \
        | awk 'NR==2{print "         다음 실행 → " $1, $2, $3}' || true
    if [[ -f "$CRON_FILE" ]]; then
        local cline
        cline="$(grep -E 'backup\.sh --target=both' "$CRON_FILE" 2>/dev/null \
                 | grep -oE '^[^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+' || echo '?')"
        echo "  PLG:   ${cline}  (분 시 일 월 요일, KST)"
    else
        echo "  PLG:   $CRON_FILE 없음 (cron 미배포)"
    fi
}

if (( SHOW )) && [[ -z "$MYSQL_H" && -z "$PLG_D" ]]; then
    show_current; exit 0
fi
[[ $EUID -eq 0 ]] || die "적용은 sudo로 실행하세요."
[[ -n "$MYSQL_H" || -n "$PLG_D" ]] || die "적어도 하나 지정: --mysql <N>h / --plg <N>d (또는 --show)"

# ── MySQL: systemd drop-in override ──
if [[ -n "$MYSQL_H" ]]; then
    n="${MYSQL_H%h}"
    [[ "$n" =~ ^[0-9]+$ ]] || die "--mysql 값은 <N>h 형식 (예: 12h). 받은 값: $MYSQL_H"
    (( n >= 1 && n <= 24 && 24 % n == 0 )) \
        || die "--mysql N은 24의 약수여야 함 (2,3,4,6,8,12,24). 받은 값: $n"
    systemctl cat oci-mysql-backup.timer >/dev/null 2>&1 \
        || die "oci-mysql-backup.timer 미설치 — 먼저 deploy.sh로 설치하세요."
    hours=""
    for (( h=0; h<24; h+=n )); do printf -v hh '%02d' "$h"; hours+="${hours:+,}$hh"; done
    mkdir -p "$TIMER_DROPIN_DIR"
    # list형 OnCalendar은 빈 대입으로 초기화 후 재설정해야 누적되지 않는다.
    cat > "$TIMER_DROPIN" <<EOF
# set-backup-schedule.sh 생성 — MySQL 백업 ${n}시간 주기 (UTC ${hours})
[Timer]
OnCalendar=
OnCalendar=*-*-* ${hours}:00:00
EOF
    systemctl daemon-reload
    systemctl restart oci-mysql-backup.timer
    echo "✅ MySQL 주기 → ${n}시간 (UTC ${hours}:00) 적용"
fi

# ── PLG: /etc/cron.d in-place ──
if [[ -n "$PLG_D" ]]; then
    [[ -f "$CRON_FILE" ]] || die "$CRON_FILE 없음 — PLG cron 미배포 상태."
    d="${PLG_D%d}"
    [[ "$d" =~ ^[0-9]+$ && "$d" -ge 1 ]] || die "--plg 값은 <N>d 형식, N>=1 (예: 2d). 받은 값: $PLG_D"
    if [[ "$d" == "1" ]]; then dom='*'; else dom="*/$d"; fi
    grep -qE 'backup\.sh --target=both' "$CRON_FILE" \
        || die "$CRON_FILE 에서 백업 라인을 찾지 못함."
    # 백업(--target=both) 라인의 5개 스케줄 필드를 '0 3 <dom> * *'로 교체.
    # 앞부분(root 전까지)만 치환하므로 경로·리다이렉트는 보존. archive 라인은 미대상.
    sed -i -E "/backup\.sh --target=both/ s|^[^r]*root |0 3 ${dom} * * root |" "$CRON_FILE"
    echo "✅ PLG 주기 → $([[ "$d" == "1" ]] && echo 매일 || echo "${d}일마다") KST 03:00 적용 (0 3 ${dom} * *)"
fi

echo
show_current
