# 헬스체크 (대시보드 + 일일 Slack 리포트)

"지금 살아있는가"는 Grafana 대시보드가, "지난 하루가 정상이었는가"는 매일 아침 Slack 리포트가 답한다.
둘은 **같은 판정 기준**을 쓴다 — 리포트가 판정한 결과를 textfile 메트릭으로 노출하고, 대시보드 ⑤·⑥ 행이 그 값을 그대로 읽는다.

| 구성 요소 | 위치 | 역할 |
|-----------|------|------|
| 대시보드 | `grafana/provisioning/dashboards/json/헬스체크/q-asker-health-overview.json` | 서비스 가동 → 수집 → 애플리케이션 → 리소스 → 백업 순의 단일 화면 |
| 리포트 스크립트 | `healthcheck/daily-health-report.sh` | Prometheus·Loki 조회 → 20개 항목 판정 → Slack 발송 → 메트릭 노출 |
| cron 참조본 | `healthcheck/cron/q-asker-health` | 매일 KST 09:00 실행 |
| logrotate 참조본 | `healthcheck/logrotate/q-asker-health` | 리포트 로그 월 1회 회전 |

즉시성이 필요한 장애 알림은 이 체계가 아니라 Grafana 알림 규칙(`grafana/provisioning/alerting/alerting.yml`, `#알림-에러`)이 담당한다.
일일 리포트는 **이상이 없어도 매일 보낸다** — 리포트가 오지 않는 것 자체가 이상 신호가 되도록 설계했다.

## 판정 항목 (20개)

| 그룹 | 항목 | 주의 / 위험 |
|------|------|-------------|
| 서비스 가동 | API 서버·Loki·Prometheus·Grafana·Alloy·MySQL | scrape 실패 시 즉시 위험 |
| 수집 파이프라인 | API·모니터링 노드 메트릭 지연 | 60초 / 300초 |
| | 로그 유입(24h) | 0줄이면 위험 |
| 애플리케이션 | 5xx 비율(24h) | 1% / 5% |
| | ERROR 로그(24h) | 1건 / 50건 |
| | 서킷브레이커(aiServer) | 24h 내 OPEN 이력 / 현재 OPEN |
| | API 재시작(24h) | 1회 / 3회 |
| | 요청률(24h 평균) | 정보성 (임계 없음) |
| 노드 리소스 | CPU·메모리·디스크 최대 | 80/90 · 85/93 · 85/92 % |
| 백업 | PLG 백업 경과 | 48시간 / 60시간 |
| | MySQL L2 백업 경과 | 9시간 / 24시간 |
| | 백업 저장소 사용률 | 80% / 90% |

조회 자체가 실패한 항목은 **확인 불가**로 따로 집계한다(정상으로 넘기지 않는다).
임계값은 전부 `HEALTH_*` 환경 변수로 override 가능하다 — 기본값은 스크립트 상단 설정 절 참조.

## 배포 (OCI-3)

```bash
cd ~/plg-stack && git pull origin main

# ① Slack 웹훅 등록 (monitoring/.env)
#    전용 채널이 없으면 이 줄을 생략해도 된다 — SLACK_BACKUP_WEBHOOK_URL로 폴백한다.
echo 'SLACK_HEALTH_WEBHOOK_URL=https://hooks.slack.com/services/...' >> monitoring/.env

# ② 발송 없이 리허설 (Slack·메트릭 기록 모두 건너뛰고 본문만 출력)
./monitoring/healthcheck/daily-health-report.sh --dry-run

# ③ 실제 1회 발송 확인
sudo ./monitoring/healthcheck/daily-health-report.sh

# ④ cron·logrotate 등록
sudo cp monitoring/healthcheck/cron/q-asker-health /etc/cron.d/q-asker-health
sudo chown root:root /etc/cron.d/q-asker-health && sudo chmod 644 /etc/cron.d/q-asker-health
sudo cp monitoring/healthcheck/logrotate/q-asker-health /etc/logrotate.d/q-asker-health
sudo chown root:root /etc/logrotate.d/q-asker-health && sudo chmod 644 /etc/logrotate.d/q-asker-health

# ⑤ 대시보드 반영 — Prometheus에 loki·grafana scrape가 추가되었으므로 함께 재적용
cd monitoring && docker compose up -d && curl -X POST http://localhost:9090/-/reload
```

`daily-health-report.sh`는 cron이 레포 경로를 직접 실행한다(PLG 백업과 동일 모델) — `git pull`만 하면 코드가 반영된다.
단, 메트릭을 `/var/lib/node_exporter/textfile_collector`에 쓰므로 **cron에서는 root로 실행**해야 한다.

## 검증

```bash
# 리포트가 노출한 메트릭 (Alloy가 15초마다 수집)
cat /var/lib/node_exporter/textfile_collector/q_asker_health.prom

# Prometheus에 반영됐는지
curl -sf 'http://localhost:9090/api/v1/query?query=q_asker_health_overall_status' | jq
curl -sf 'http://localhost:9090/api/v1/query?query=q_asker_health_check_status' | jq '.data.result[].metric.title'

# 새로 추가된 scrape 대상이 UP인지
curl -sf 'http://localhost:9090/api/v1/query?query=up{job=~"loki|grafana"}' | jq '.data.result[] | {job:.metric.job, up:.value[1]}'
```

## 리포트가 오지 않을 때

1. `sudo tail -50 /var/log/q-asker-health.log` — 실행 자체가 있었는지 본다.
2. 로그가 비어 있으면 cron 등록 확인: `cat /etc/cron.d/q-asker-health`, `systemctl status cron`.
3. 실행은 됐는데 발송이 없으면 `SLACK_*_WEBHOOK_URL` 미설정 경고가 로그에 남는다 — `monitoring/.env`를 확인한다.
4. 대시보드 "일일 리포트 경과"가 25시간을 넘겼는지로도 같은 사실을 알 수 있다.
