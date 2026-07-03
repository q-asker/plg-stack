#!/usr/bin/env bash
# =============================================================
# gameday.sh — 분기 1회 GameDay 실측 자동화 (T8, SC-004)
# (plg-stack: specs/001-prometheus-loki-backup-recovery)
# =============================================================
# 실행 방법 (OCI-3에서):
#   sudo bash monitoring/scripts/gameday.sh
#   sudo bash monitoring/scripts/gameday.sh 20260901-0300   # 다른 SNAPSHOT
#
# 실행 중 SLACK_WEBHOOK_URL을 임시 무력화하고 완료 후 원복한다.
#
# 흐름:
#   1) 사전 헬스 · Slack 무력화
#   2) Prometheus 3회 반복 (restore.sh --target=prometheus --snapshot=<선택>)
#   3) Loki 보조 1회
#   4) 사후 헬스 · .bak 현황
#   5) Slack 원복
#   6) 최종 요약 (RUNBOOK §12에 이 블록을 그대로 붙여넣기)
#
# 로그: /tmp/gameday-YYYYMMDD-HHMMSS/*.log
# 판정: MAX(RTO) <= 14400s (SC-001)

set -uo pipefail

SNAPSHOT="${1:-20260703-0205}"
MONITORING_DIR="/home/ubuntu/plg-stack/monitoring"
RESTORE_SH="$MONITORING_DIR/scripts/restore.sh"
ENV_FILE="$MONITORING_DIR/.env"

STAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="/tmp/gameday-$STAMP"
ENV_BAK="$ENV_FILE.gameday-orig-$STAMP"
mkdir -p "$LOG_DIR"

echo "=== 사전 헬스 ==="
curl -sf http://localhost:9090/-/ready && echo prom-ok
curl -sf http://localhost:3100/ready   && echo loki-ok

echo
echo "=== Slack 무력화 ==="
cp "$ENV_FILE" "$ENV_BAK"
sed -i 's|^SLACK_WEBHOOK_URL=.*|SLACK_WEBHOOK_URL=|' "$ENV_FILE"
grep '^SLACK_WEBHOOK_URL=' "$ENV_FILE"

GAMEDAY_START_KST=$(TZ=Asia/Seoul date +%Y-%m-%dT%H:%M:%S)
GIT_SHA=$(cd /home/ubuntu/plg-stack && git rev-parse --short HEAD)
echo
echo "=== GameDay 시작 ==="
echo "  KST      : $GAMEDAY_START_KST"
echo "  SNAPSHOT : $SNAPSHOT"
echo "  Git      : $GIT_SHA"

declare -a RTOS EXITS STARTS ENDS
for N in 1 2 3; do
    T0=$(date +%s); S=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    "$RESTORE_SH" --target=prometheus --snapshot="$SNAPSHOT" > "$LOG_DIR/prom-$N.log" 2>&1
    E=$?
    T1=$(date +%s); F=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    R=$((T1 - T0))
    RTOS[$N]=$R; EXITS[$N]=$E; STARTS[$N]=$S; ENDS[$N]=$F
    echo "── Prom 회차 $N ── start=$S end=$F RTO=${R}s exit=$E"
done

T0=$(date +%s); LS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
"$RESTORE_SH" --target=loki --snapshot="$SNAPSHOT" > "$LOG_DIR/loki.log" 2>&1
LE=$?
T1=$(date +%s); LF=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LR=$((T1 - T0))
echo "── Loki 보조 ── start=$LS end=$LF RTO=${LR}s exit=$LE"

echo
echo "=== 사후 헬스 ==="
curl -sf http://localhost:9090/-/ready && echo prom-ok
curl -sf http://localhost:3100/ready   && echo loki-ok

echo
echo "=== .bak 디렉토리 현황 ==="
ls -la /mnt/monitoring/ | grep -E '\.bak\.' || echo "(없음)"
du -sh /mnt/monitoring/*.bak.* 2>/dev/null || true

echo
echo "=== Slack 원복 ==="
cp "$ENV_BAK" "$ENV_FILE"
grep '^SLACK_WEBHOOK_URL=' "$ENV_FILE"

GAMEDAY_END_KST=$(TZ=Asia/Seoul date +%Y-%m-%dT%H:%M:%S)

MIN=$(printf '%s\n' "${RTOS[1]}" "${RTOS[2]}" "${RTOS[3]}" | sort -n | head -1)
MAX=$(printf '%s\n' "${RTOS[1]}" "${RTOS[2]}" "${RTOS[3]}" | sort -n | tail -1)
AVG=$(( (RTOS[1] + RTOS[2] + RTOS[3]) / 3 ))
[ "$MAX" -le 14400 ] && JUDGMENT=PASS || JUDGMENT=FAIL

echo
echo "════════════════════════════════════════════"
echo "GameDay 결과"
echo "════════════════════════════════════════════"
echo "START (KST): $GAMEDAY_START_KST"
echo "END   (KST): $GAMEDAY_END_KST"
echo "SNAPSHOT   : $SNAPSHOT"
echo "Git commit : $GIT_SHA"
echo "Log dir    : $LOG_DIR"
echo
echo "Prometheus 3회 실측:"
for N in 1 2 3; do
    echo "  회차 $N: ${RTOS[$N]}s (exit=${EXITS[$N]}, ${STARTS[$N]} -> ${ENDS[$N]})"
done
echo "  MIN: ${MIN}s"
echo "  MAX: ${MAX}s"
echo "  AVG: ${AVG}s"
echo
echo "Loki 보조 1회:"
echo "  RTO: ${LR}s (exit=$LE, ${LS} -> ${LF})"
echo
echo "SC-001 판정 (MAX <= 14400s): $JUDGMENT"
echo "════════════════════════════════════════════"
