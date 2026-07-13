#!/usr/bin/env bash
# ============================================================
# T6: 서버 설치 자동화 (OCI Compute 인스턴스에서 sudo 실행)
# ============================================================
# 동작:
#   1. 시스템 사용자 oci-mysql-backup 생성 (nologin)
#   2. /opt/oci-mysql-backup에 스크립트 배치
#   3. /var/lib/oci-mysql-backup 상태 디렉터리 + 소유권
#   4. /var/lib/node_exporter/textfile_collector 생성 (Alloy와 공유)
#   5. /etc/oci-mysql-backup/env 템플릿 배치
#   6. systemd unit 등록 + daemon-reload
#   7. ~/.oci/config 확인 (BACKUP_WRITER 프로필 필수)
#
# 실행 위치: OCI Compute 인스턴스 내부
# 사용법:
#   scp -r infra/scripts/oci-mysql-backup opc@<host>:~/
#   ssh opc@<host>
#   cd oci-mysql-backup
#   sudo ./deploy.sh
#
# 이후 수동 작업:
#   sudo vi /etc/oci-mysql-backup/env    # 값 채우기
#   sudo cp -r ~/.oci /var/lib/oci-mysql-backup/  # BACKUP_WRITER 프로필 복사
#   sudo chown -R oci-mysql-backup:oci-mysql-backup /var/lib/oci-mysql-backup/.oci
#   sudo -u oci-mysql-backup /opt/oci-mysql-backup/backup.sh  # 수동 검증
#   sudo systemctl enable --now oci-mysql-backup.timer

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="oci-mysql-backup"
INSTALL_DIR="/opt/oci-mysql-backup"
STATE_DIR="/var/lib/oci-mysql-backup"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
CONFIG_DIR="/etc/oci-mysql-backup"
SYSTEMD_DIR="/etc/systemd/system"

[[ $EUID -eq 0 ]] || { echo "❌ sudo로 실행하세요"; exit 1; }

echo "▶ 1/6 시스템 사용자 생성..."
if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd --system --home-dir "$STATE_DIR" --create-home \
    --shell /usr/sbin/nologin "$USER_NAME"
  echo "   신규: $USER_NAME"
else
  echo "   기존 사용자 유지: $USER_NAME"
fi

echo "▶ 2/6 스크립트 배치 → $INSTALL_DIR..."
install -m 755 -d "$INSTALL_DIR" "$INSTALL_DIR/lib" "$INSTALL_DIR/systemd"
install -m 755 "$SRC_DIR/backup.sh" "$INSTALL_DIR/backup.sh"
install -m 755 "$SRC_DIR/restore.sh" "$INSTALL_DIR/restore.sh"
install -m 755 "$SRC_DIR/healthcheck.sh" "$INSTALL_DIR/healthcheck.sh"
install -m 644 "$SRC_DIR/lib/metrics.sh" "$INSTALL_DIR/lib/metrics.sh"
install -m 644 "$SRC_DIR/lib/metadata.sh" "$INSTALL_DIR/lib/metadata.sh"

# Docker 설치 확인 (T8 restore.sh 사전 요구)
if ! command -v docker >/dev/null 2>&1; then
  echo "   ⚠️  docker 미설치 — T8 restore.sh 실행 전 설치 필요:"
  echo "       sudo apt install -y docker.io && sudo usermod -aG docker \$USER"
fi

echo "▶ 3/6 상태 디렉터리 준비..."
install -m 755 -d "$STATE_DIR"
chown "$USER_NAME:$USER_NAME" "$STATE_DIR"

echo "▶ 4/6 Prometheus textfile 디렉터리 준비..."
install -m 755 -d "$TEXTFILE_DIR"
chown "$USER_NAME:$USER_NAME" "$TEXTFILE_DIR"

echo "▶ 5/6 EnvironmentFile 템플릿 + 헬스체크 baseline..."
install -m 755 -d "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/env" ]]; then
  install -m 600 "$SRC_DIR/env.example" "$CONFIG_DIR/env"
  chown root:root "$CONFIG_DIR/env"
  echo "   신규: $CONFIG_DIR/env (⚠️ 값 채우기 필요)"
else
  echo "   기존 유지: $CONFIG_DIR/env"
fi
# T7 헬스체크 baseline (기존 있으면 덮어쓰지 않음 — 운영자가 갱신했을 수 있음)
if [[ ! -f "$CONFIG_DIR/healthcheck.baseline.yml" ]]; then
  install -m 644 "$SRC_DIR/healthcheck.baseline.yml" "$CONFIG_DIR/healthcheck.baseline.yml"
  echo "   신규: $CONFIG_DIR/healthcheck.baseline.yml"
else
  echo "   기존 유지: $CONFIG_DIR/healthcheck.baseline.yml"
fi

echo "▶ 6/6 systemd unit 등록..."
install -m 644 "$SRC_DIR/systemd/oci-mysql-backup.service" "$SYSTEMD_DIR/oci-mysql-backup.service"
install -m 644 "$SRC_DIR/systemd/oci-mysql-backup.timer" "$SYSTEMD_DIR/oci-mysql-backup.timer"
systemctl daemon-reload

echo ""
echo "═══════════════ 다음 단계 ═══════════════"
echo ""
echo "① EnvironmentFile 값 채우기:"
echo "   sudo vi $CONFIG_DIR/env"
echo ""
echo "② BACKUP_WRITER OCI 프로필 복사 (T3에서 등록한 자격증명):"
echo "   sudo mkdir -p $STATE_DIR/.oci"
echo "   sudo cp ~/.oci/config $STATE_DIR/.oci/config"
echo "   sudo cp ~/.oci/backup_writer.pem $STATE_DIR/.oci/backup_writer.pem"
echo "   sudo chown -R $USER_NAME:$USER_NAME $STATE_DIR/.oci"
echo "   sudo chmod 600 $STATE_DIR/.oci/*.pem $STATE_DIR/.oci/config"
echo ""
echo "③ 수동 검증:"
echo "   sudo -u $USER_NAME $INSTALL_DIR/backup.sh"
echo "   sudo cat $STATE_DIR/state.json"
echo "   oci --profile BACKUP_READER os object list -bn qasker-mysql-backup --limit 10"
echo ""
echo "④ Timer 활성화 (6시간 주기 자동 실행 시작):"
echo "   sudo systemctl enable --now oci-mysql-backup.timer"
echo "   systemctl list-timers | grep oci-mysql-backup"
echo ""
echo "⑤ 로그 확인:"
echo "   sudo journalctl -u oci-mysql-backup.service -n 50"
echo ""
echo "✅ 설치 완료"
