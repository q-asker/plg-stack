#!/usr/bin/env bash
# ============================================================
# Slack 알림 (SLACK_BACKUP_WEBHOOK_URL 부재 시 로그만 남기고 스킵)
# ============================================================
# 사용: backup.sh 등에서 source 후 호출.
#   notify_slack <status> <detail>
#     status: SUCCESS|WARN|ERROR
#
# SLACK_BACKUP_WEBHOOK_URL 미설정 또는 curl 미설치 시 백업 자체는 정상 동작하고
# 알림만 조용히 스킵한다. 전송 실패도 로그 경고만 남기고 종료코드에 영향 없음.

notify_slack() {
  local status="$1" detail="$2"

  if [[ -z "${SLACK_BACKUP_WEBHOOK_URL:-}" ]]; then
    log "[notify] SLACK_BACKUP_WEBHOOK_URL 미설정 — Slack 알림 스킵: [${status}] ${detail}"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log "[notify] curl 미설치 — Slack 알림 스킵"
    return 0
  fi

  local emoji="ℹ️" color="#2eb67d"
  case "$status" in
    SUCCESS) emoji="✅"; color="#2eb67d" ;;
    WARN)    emoji="⚠️"; color="#ecb22e" ;;
    ERROR)   emoji="❌"; color="#e01e5a" ;;
  esac

  local host payload
  host="$(hostname -s 2>/dev/null || hostname)"
  payload=$(jq -n \
    --arg text "${emoji} *[oci-mysql-backup]* ${status}" \
    --arg detail "${detail}" \
    --arg host "${host}" \
    --arg color "${color}" \
    '{
      text: $text,
      attachments: [{
        color: $color,
        mrkdwn_in: ["fields"],
        fields: [
          {title: "Host",   value: $host,   short: true},
          {title: "Detail", value: $detail, short: false}
        ]
      }]
    }')

  curl -sf -X POST \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$SLACK_BACKUP_WEBHOOK_URL" >/dev/null 2>&1 \
    || log "[notify] Slack 알림 전송 실패 (webhook 응답 이상)"
}
