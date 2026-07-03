# Q-Asker PLG 스택

분산 시스템 옵저버빌리티를 위한 **Promtail(→Alloy)/Loki/Grafana + Prometheus** 스택. OCI Always Free ARM 인스턴스 3대와 관리형 MySQL로 운영.

- 로그 저장소: **Loki 3.6.0** (라벨 기반 인덱싱)
- 메트릭 저장소: **Prometheus v3.10.0**
- 시각화: **Grafana 12.4.0**
- 통합 에이전트: **Grafana Alloy** (Promtail + node_exporter + MySQL exporter 통합)

자세한 프로젝트 전반은 [CLAUDE.md](CLAUDE.md)를 참조.

---

## 배포

각 노드는 독립적인 Docker Compose 프로젝트로 관리합니다.

### 모니터링 스택 (OCI-3)

```bash
cd monitoring
cp .env.example .env    # 실제 값 채움 (GRAFANA_ADMIN_PASSWORD, MYSQL_DSN 등)
docker compose up -d

# 상태 확인
curl http://localhost:3100/ready     # Loki
curl http://localhost:9090/-/ready   # Prometheus
curl http://localhost:3000/api/health # Grafana
```

### Spring Boot 애플리케이션 (OCI-2)

```bash
cd springboot
cp .env.example .env
docker compose up -d
```

---

## 운영

### 백업·복구 (spec 001-prometheus-loki-backup-recovery)

Prometheus/Loki 데이터를 매일 KST 03:00 OCI Object Storage에 자동 백업. 무결성은 매일 KST 04:00 재검증.

- **배경 지식·흐름도**: [monitoring/docs/프로메테우스로키백업복구설명.md](monitoring/docs/프로메테우스로키백업복구설명.md)
- **운영 RUNBOOK (평시·장애·복원·GameDay)**: [monitoring/docs/RUNBOOK-backup-restore.md](monitoring/docs/RUNBOOK-backup-restore.md)
- **스크립트**: `monitoring/scripts/{backup,restore,verify}.sh` (자세한 사용법은 CLAUDE.md 명령어 섹션)

수동 실행 예시:
```bash
sudo ./monitoring/scripts/backup.sh --target=both
sudo ./monitoring/scripts/restore.sh --target=prometheus --snapshot=YYYYMMDD-HHMM
sudo ./monitoring/scripts/verify.sh --scope=all
```

### 대시보드

- Grafana: `https://mon.q-asker.com` (또는 `http://<OCI-3 IP>:3000`)
- 카테고리별 대시보드는 `monitoring/grafana/provisioning/dashboards/json/` 아래 폴더 참조

### 검증 체크리스트

```bash
✓ Loki:       curl -sf http://localhost:3100/ready
✓ Prometheus: curl -sf http://localhost:9090/-/ready
✓ Grafana:    curl -sf http://localhost:3000/api/health
✓ Alloy:      curl -sf http://localhost:12345/metrics | grep loki_write
✓ Backup:     curl -sf 'http://localhost:9090/api/v1/query?query=time()-q_asker_backup_last_success_timestamp' | jq
```

---

## 아키텍처 요약

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│ OCI-1 (Kafka)   │    │ OCI-2 (Spring)  │    │ OCI-3 (모니터링) │
│ - 별도 저장소   │    │ Spring Boot     │    │ Loki + Prom +   │
│ (본 저장소 밖) │    │ + Alloy         │    │ Grafana + Alloy │
└─────────────────┘    └────────┬────────┘    └────────┬────────┘
                                │                       │
                                └───────────────────────┼───────────────┐
                                Alloy remote_write /    │               │
                                loki push               ▼               │
                       ┌─────────────────────────────────────┐          │
                       │ OCI-3 저장소 (블록볼륨 50 GiB)      │          │
                       │ /mnt/monitoring/{loki,prometheus,   │          │
                       │                  grafana}          │          │
                       └────────────┬────────────────────────┘          │
                                    │ 매일 KST 03:00                    │
                                    │ backup.sh                         │
                                    ▼                                   │
                       ┌─────────────────────────────────────┐          │
                       │ OCI Object Storage Standard 20 GiB │◀─────────┘
                       │ qasker-monitoring-backup (7일 보존) │  매일 04:00
                       │ IAM Writer/Reader 분리              │  verify.sh
                       └─────────────────────────────────────┘  재검증
```

---

## 프로젝트 구조

```
plg-stack/
├── CLAUDE.md               # 프로젝트 전반 명세 (진실의 원천)
├── README.md               # 이 파일
├── monitoring/             # OCI-3 모니터링 스택
│   ├── docker-compose.yml
│   ├── alloy/config.alloy
│   ├── loki/loki-config.yaml
│   ├── prometheus/prometheus.yml
│   ├── grafana/provisioning/
│   ├── scripts/            # 백업·복구·검증 (spec 001)
│   │   ├── backup.sh
│   │   ├── restore.sh
│   │   ├── verify.sh
│   │   └── lib/backup-common.sh
│   ├── cron/               # /etc/cron.d/ 배포 참조본
│   ├── logrotate/          # /etc/logrotate.d/ 배포 참조본
│   ├── docs/               # 운영·설계 문서
│   │   ├── 프로메테우스로키백업복구설명.md
│   │   └── RUNBOOK-backup-restore.md
│   └── local/              # 로컬 개발용 스택
├── springboot/             # OCI-2 Spring Boot + Alloy
└── remote-node.env.example # 원격 노드 공통 환경 변수 템플릿
```

---

## 헌법 (5원칙 요약)

`.specify/memory/constitution.md` (로컬 참고용, gitignore)에서 정의된 프로젝트 5대 원칙:

- **I. Observability-First** (NON-NEGOTIABLE) — 모든 서비스 변경은 옵저버빌리티 경로 함께 설계
- **II. Configuration as Code** — 운영 상태 변경은 선언적 구성 파일로만
- **III. Secret & Environment Isolation** — 비밀값은 `.env`에서 `${VAR}` 참조로만
- **IV. Resource Discipline** — Always Free 한도 준수, `GOMEMLIMIT` 필수, `latest` 태그 금지
- **V. Documentation-Code Sync** — 코드/설정 변경 시 CLAUDE.md 동일 커밋에서 갱신

---

## 참고 자료

- **Grafana Loki 3.6**: <https://grafana.com/docs/loki/latest/>
- **Prometheus v3.10**: <https://prometheus.io/docs/introduction/overview/>
- **Grafana Alloy**: <https://grafana.com/docs/alloy/latest/>
- **OCI Always Free**: <https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm>
