#!/usr/bin/env bash
# ============================================================
# update.sh — MySQL 백업 코드를 /opt 배포본에 반영 (git pull 후 실행)
# ============================================================
# 배경: MySQL 백업은 systemd가 /opt/oci-mysql-backup/의 "사본"을 실행한다.
#       git pull은 워킹카피(~/plg-stack)만 갱신하므로, 코드 변경을 반영하려면
#       바뀐 파일을 /opt로 재배치해야 한다. 이 스크립트가 그 재배치를 자동화한다.
#       (최초 설치·사용자/systemd/env 생성은 deploy.sh. 이건 코드 갱신 전용.)
#
# 안전장치:
#   - 배포 전 소스 전체 bash -n (깨진 코드 배포 차단)
#   - systemd unit은 실제 변경분만 재설치 + daemon-reload
#   - 배포 후 /opt 사본 문법·lib 존재 재검증
#   - env/자격증명/state는 건드리지 않음 (코드만)
#
# 사용법 (OCI-3 호스트):
#   cd ~/plg-stack && git pull origin main
#   sudo ./oci-mysql-backup/update.sh

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/oci-mysql-backup"
SYSTEMD_DIR="/etc/systemd/system"

# deploy.sh와 동일한 배포 파일 목록 (실행 755 / lib 644)
BIN_FILES=(backup.sh restore.sh healthcheck.sh)
LIB_FILES=(lib/metrics.sh lib/metadata.sh lib/notify.sh)
UNIT_FILES=(oci-mysql-backup.service oci-mysql-backup.timer)

[[ $EUID -eq 0 ]] || { echo "❌ sudo로 실행하세요"; exit 1; }
[[ -d "$INSTALL_DIR" ]] || { echo "❌ $INSTALL_DIR 없음 — 최초 설치는 deploy.sh를 쓰세요"; exit 1; }

# ── 1) 배포 전 문법 검증 ──
echo "▶ 1/4 소스 문법 검증..."
for f in "${BIN_FILES[@]}" "${LIB_FILES[@]}"; do
  [[ -f "$SRC_DIR/$f" ]] || { echo "❌ 소스 누락: $f"; exit 2; }
  bash -n "$SRC_DIR/$f" || { echo "❌ 문법 오류: $f (배포 중단)"; exit 2; }
done
echo "   OK"

# ── 2) 코드 동기화 (변경분만 표시) ──
echo "▶ 2/4 /opt 동기화..."
install -m 755 -d "$INSTALL_DIR/lib"
for f in "${BIN_FILES[@]}"; do
  cmp -s "$SRC_DIR/$f" "$INSTALL_DIR/$f" 2>/dev/null && s="(동일)" || s="← 갱신"
  install -m 755 "$SRC_DIR/$f" "$INSTALL_DIR/$f"
  printf "   %-24s %s\n" "$f" "$s"
done
for f in "${LIB_FILES[@]}"; do
  cmp -s "$SRC_DIR/$f" "$INSTALL_DIR/$f" 2>/dev/null && s="(동일)" || s="← 갱신"
  install -m 644 "$SRC_DIR/$f" "$INSTALL_DIR/$f"
  printf "   %-24s %s\n" "$f" "$s"
done

# ── 3) systemd unit: 실제 변경분만 재설치 + reload ──
echo "▶ 3/4 systemd unit 확인..."
unit_changed=0
for u in "${UNIT_FILES[@]}"; do
  if ! cmp -s "$SRC_DIR/systemd/$u" "$SYSTEMD_DIR/$u" 2>/dev/null; then
    install -m 644 "$SRC_DIR/systemd/$u" "$SYSTEMD_DIR/$u"
    unit_changed=1
    echo "   갱신: $u"
  fi
done
if (( unit_changed )); then
  systemctl daemon-reload
  echo "   daemon-reload 완료"
else
  echo "   변경 없음"
fi

# ── 4) 배포본 사후 검증 ──
echo "▶ 4/4 배포본 검증..."
bash -n "$INSTALL_DIR/backup.sh" || { echo "❌ 배포본 문법 오류"; exit 3; }
for f in "${LIB_FILES[@]}"; do
  [[ -f "$INSTALL_DIR/$f" ]] || { echo "❌ 배포본 누락: $f"; exit 3; }
done
echo "   OK"

echo ""
echo "✅ 코드 반영 완료 (env·자격증명·state는 그대로)."
echo ""
echo "즉시 검증 (실제 백업 1회 실행 → Slack SUCCESS 확인):"
echo "   sudo systemctl start oci-mysql-backup.service"
echo "   sudo journalctl -u oci-mysql-backup.service -n 25 --no-pager"
echo ""
echo "안 하면 다음 타이머 주기(6시간)에 자동 반영됨."
