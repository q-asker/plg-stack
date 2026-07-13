# Q-Asker PLG 스택 프로젝트

## 프로젝트 개요

분산 시스템의 옵저버빌리티를 위한 PLG(Promtail→Alloy, Loki, Grafana) 스택 구현 프로젝트. Spring Boot 애플리케이션과 중앙 모니터링 스택으로 구성된 프로덕션 환경 배포 및 운영. Kafka 브로커 설정은 별도 프로젝트로 분리하여 관리.

## 기술 스택

| 분류 | 기술 | 버전 | 용도 |
|------|------|------|------|
| **애플리케이션** | Spring Boot | 3.x | OCI-2 REST API 애플리케이션 |
| | Java | 21 (ARM 지원) | JVM 런타임 |
| | LibreOffice | 7.x | OCI-2 문서 변환 (UNO TCP) |
| **에이전트/수집** | Grafana Alloy | latest | 로그+메트릭 수집 (Promtail 후속) |
| **로그 저장소** | Loki | 3.7.3 | 라벨 기반 로그 인덱싱 및 저장 |
| **메트릭 저장소** | Prometheus | v3.13.0 | 시계열 메트릭 저장 및 PromQL 쿼리 |
| **시각화** | Grafana | 13.1.0 | 대시보드 및 알림 |
| **데이터베이스** | OCI HeatWave MySQL | 관리형 | 애플리케이션 및 메타데이터 저장 |
| **백업 저장소** | OCI Object Storage | Always Free | Prometheus/Loki 백업 tarball (버킷 `qasker-monitoring-backup`) + MySQL L2 덤프 (버킷 `qasker-mysql-backup`) |
| **배포/오케스트레이션** | Docker | 24.x+ | 컨테이너 런타임 |
| | Docker Compose | 2.x+ | 다중 서비스 오케스트레이션 |
| **스케줄러** | 호스트 cron + systemd timer | Ubuntu 기본 | cron: 매일 KST 03:00 백업·04:00 재검증 (TZ=Asia/Seoul) / systemd: MySQL L2 백업 6시간 주기 |
| **인프라** | OCI Always Free | — | 3개 ARM 인스턴스 + 관리형 MySQL |

## 명령어 (Scripts)

Docker Compose를 통한 운영 명령어:

```bash
# 모니터링 스택 시작
cd monitoring && docker compose up -d

# Spring Boot 애플리케이션 시작
cd springboot && docker compose up -d

# 상태 확인
docker ps
docker logs <service-name>

# 메트릭/로그 수집 상태 확인
curl http://<node>:12345/metrics          # Alloy UI
curl http://monitoring:3100/ready         # Loki
curl http://monitoring:9090/-/ready       # Prometheus
curl http://monitoring:3000/api/health    # Grafana
```

### 백업·복구·검증 (spec 001-prometheus-loki-backup-recovery)

세 스크립트 공통 인자 규약: `--target=prometheus|loki|both`(백업/복구) 또는 `--scope=all|prometheus|loki`(검증).
자세한 배경 · 흐름도는 [monitoring/docs/프로메테우스로키백업복구설명.md](monitoring/docs/프로메테우스로키백업복구설명.md), 운영 절차는 [monitoring/docs/RUNBOOK-backup-restore.md](monitoring/docs/RUNBOOK-backup-restore.md) 참고.

```bash
# 수동 백업 (호스트 cron이 매일 KST 03:00 자동 실행)
sudo ./monitoring/scripts/backup.sh --target=both
sudo ./monitoring/scripts/backup.sh --target=prometheus --dry-run

# 복원 (사용자 개입 필요, --snapshot 필수)
sudo ./monitoring/scripts/restore.sh --target=prometheus              # 사용 가능 목록 조회 후 exit 2
sudo ./monitoring/scripts/restore.sh --target=loki --snapshot=YYYYMMDD-HHMM
sudo ./monitoring/scripts/restore.sh --target=both --snapshot=YYYYMMDD-HHMM

# 무결성 재검증 (호스트 cron이 매일 KST 04:00 자동 실행)
sudo ./monitoring/scripts/verify.sh --scope=all
sudo ./monitoring/scripts/verify.sh --scope=prometheus --dry-run

# 백업 상태 관측
curl -sf 'http://localhost:9090/api/v1/query?query=q_asker_backup_last_success_timestamp' | jq
curl -sf 'http://localhost:9090/api/v1/query?query=q_asker_backup_verify_fail_total' | jq
```

## 아키텍처

### 논리 아키텍처
```
┌──────────────────────────────────────┐
│          로그 + 메트릭 수집            │
├──────────────────┬───────────────────┤
│ Spring Boot      │ (외부 Alloy 노드)  │
│ (OCI-2)          │ 별도 프로젝트 관리   │
│ Alloy            │                    │
│ arm64            │                    │
└────────┬─────────┴─────────┬─────────┘
         │                   │
         └─────────┬─────────┘
                   │ HTTP POST (Protobuf+snappy)
                   ▼
      ┌────────────────────────────┐
      │ OCI-3 모니터링 스택         │
      ├────────────────────────────┤
      │ Loki (로그 저장)          │
      │ :3100 (ingest)            │
      │                            │
      │ Prometheus (메트릭)        │
      │ :9090 (remote_write)      │
      │                            │
      │ Grafana (시각화)           │
      │ :3000 (대시보드)          │
      │                            │
      │ Alloy (MySQL exporter)    │
      │ HeatWave 메트릭 수집      │
      │                            │
      │ Alloy (textfile collector)│
      │ backup.sh/verify.sh 메트릭│
      └──────────┬─────────────────┘
                 │ 매일 KST 03:00 backup.sh
                 │ 매일 KST 04:00 verify.sh
                 │ (tar+gzip+sha256, OCI CLI)
                 ▼
      ┌────────────────────────────┐
      │ OCI Object Storage         │
      │ Standard tier 20 GiB Free  │
      │ qasker-monitoring-backup   │
      │ Lifecycle: 7일 후 DELETE   │
      │ IAM Writer/Reader 분리     │
      └────────────────────────────┘
```

**MySQL L2 백업 (별도 서브시스템, spec 001-oci-mysql-backup-restore)**: OCI-3에서 systemd timer가 6시간 주기(UTC 00·06·12·18 = KST 09·15·21·03)로 `oci-mysql-backup/backup.sh`를 실행 → HeatWave MySQL을 `mysqldump`(gzip+sha256)하여 별도 버킷 `qasker-mysql-backup`에 PUT한다. PLG 백업(cron)과 독립적으로 동작하며, flock으로 백업/복구/GameDay를 직렬화하고 Prometheus textfile 컬렉터로 결과 메트릭을 노출한다.

### 디렉토리 구조

```
plg-stack/
├── CLAUDE.md                    ← 이 파일
├── README.md                    ← 배포 가이드
├── .gitignore                   ← Git 무시 목록
├── .mcp.json                    ← MCP 서버 설정
│
├── springboot/                  ← OCI-2 Spring Boot 애플리케이션
│   ├── docker-compose.yml       ← Alloy 에이전트 (Docker 소켓 기반 로그 수집)
│   ├── src/                     ← Java 소스 코드 (필요 시)
│   └── alloy/
│       └── config.alloy         ← Docker 소켓으로 stdout/stderr 수집
│
├── monitoring/                  ← OCI-3 모니터링 스택 (리더 선택)
│   ├── docker-compose.yml       ← Loki + Prometheus + Grafana + Alloy
│   ├── .env                     ← 환경 변수 (Git 무시)
│   ├── loki/
│   │   └── loki-config.yaml     ← Loki 설정 (라벨 인덱싱)
│   ├── prometheus/
│   │   ├── prometheus.yml       ← Prometheus scrape 설정
│   │   └── rules.yml            ← Recording rules (TTFQ 분위수/외삽, CB 헬스, breach 회복)
│   ├── grafana/
│   │   └── provisioning/
│   │       ├── datasources/
│   │       │   └── datasources.yml
│   │       ├── dashboards/
│   │       │   └── json/                    ← 카테고리 폴더별 대시보드 JSON
│   │       │       ├── Q-Asker API 서버/    ← HTTP, JVM, 서킷브레이커, 로그, 인프라 등
│   │       │       ├── 데이터베이스/        ← HeatWave MySQL, L2 백업
│   │       │       ├── 모니터링 서버/       ← Alloy, Prometheus, 노드 인프라
│   │       │       ├── 서킷브레이커 튜닝/
│   │       │       └── 쿼리 튜닝/
│   │       └── alerting/
│   ├── alloy/
│   │   └── config.alloy         ← MySQL exporter + textfile collector 설정
│   ├── scripts/                 ← 백업·복구·검증 스크립트 (spec 001)
│   │   ├── backup.sh            ← 매일 KST 03:00 자동 백업 진입점
│   │   ├── restore.sh           ← 재해 복구 진입점 (부분 복원 지원)
│   │   ├── verify.sh            ← 매일 KST 04:00 무결성 재검증 진입점
│   │   └── lib/
│   │       └── backup-common.sh ← 공통 함수 라이브러리 (15+ 유틸)
│   ├── cron/
│   │   └── q-asker-backup       ← /etc/cron.d/ 배포 참조본 (TZ=Asia/Seoul)
│   ├── logrotate/
│   │   └── q-asker-backup       ← /etc/logrotate.d/ 배포 참조본 (weekly × 4)
│   ├── docs/
│   │   ├── grafana-gemini-dashboard-spec.md
│   │   ├── 프로메테우스로키백업복구설명.md ← 배경 지식 + 흐름도 (진실의 원천)
│   │   └── RUNBOOK-backup-restore.md      ← 평시·장애·복원·GameDay 절차
│   └── local/                   ← 로컬 테스트용 모니터링 스택
│       ├── docker-compose.yml   ← Prometheus + Grafana (로컬)
│       └── prometheus/
│           └── prometheus.yml   ← Spring Boot Actuator 스크래핑
│
├── oci-mysql-backup/            ← HeatWave MySQL L2 백업 (systemd, spec 001-oci-mysql-backup-restore)
│   ├── backup.sh                ← mysqldump → gzip+sha256 → Object Storage PUT (6시간 주기)
│   ├── restore.sh               ← 재해 복구 진입점 (원격 호스트용)
│   ├── restore-local.sh         ← 로컬 Docker MySQL로 복원 (분석용)
│   ├── masked-export.sh         ← 민감정보 마스킹 덤프
│   ├── healthcheck.sh           ← baseline 대비 스키마/테이블 헬스체크
│   ├── deploy.sh                ← /opt 배치 + systemd unit 등록 (sudo)
│   ├── env.example              ← EnvironmentFile 템플릿
│   ├── healthcheck.baseline.yml ← 헬스체크 기준선
│   ├── lib/
│   │   ├── metadata.sh          ← DB 메타데이터(스키마/row 카운트) JSON
│   │   └── metrics.sh           ← Prometheus textfile 메트릭 갱신
│   └── systemd/
│       ├── oci-mysql-backup.service  ← oneshot 백업 (User=oci-mysql-backup)
│       └── oci-mysql-backup.timer    ← 6시간 주기 (UTC 00·06·12·18)
│
├── remote-node.env.example      ← 원격 노드 공통 환경 변수
└── .claude/                     ← Claude Code 설정 디렉토리
    ├── CLAUDE.md
    ├── rules/                   ← 코딩 컨벤션 및 작업 규칙
    ├── commands/                ← CLI 커맨드
    ├── agents/                  ← 전용 에이전트
    ├── hooks/                   ← Git 훅
    └── settings.json            ← 클로드 코드 설정
```

### 호스팅 환경

**OCI Always Free (3개 ARM 인스턴스, 총 4 OCPU / 24GB)**

| 인스턴스 | 스펙 | 역할 | 퍼블릭 IP | 프라이빗 IP |
|---------|------|------|----------|-----------|
| OCI-1 | 1 OCPU / 8GB | Kafka + ZK + Alloy (별도 프로젝트) | 168.107.40.76 | 10.0.0.220 |
| OCI-2 (Spring Boot) | 2 OCPU / 10GB | Spring Boot + LibreOffice + Alloy | 168.107.15.251 | 10.0.0.37 |
| OCI-3 (모니터링) | 1 OCPU / 6GB | Loki + Prometheus + Grafana | 168.107.55.136 | 10.0.0.122 |

**스토리지**

- OCI-3 블록 볼륨: 50GB (`/mnt/monitoring`)
  - `/mnt/monitoring/loki` — Loki 데이터
  - `/mnt/monitoring/prometheus` — Prometheus TSDB
  - `/mnt/monitoring/grafana` — Grafana 데이터 (선택)

**네트워크 (OCI NSG)**

| NSG | 인스턴스 | 허용 포트 |
|-----|---------|---------|
| nsg-springboot | OCI-2 | 8080, 9100 |
| nsg-monitoring | OCI-3 | 3000(Grafana), 9090(Prometheus), 3100(Loki) |

## 개발 도구 및 설정

| 도구 | 용도 | 설정 |
|------|------|------|
| **Docker** | 컨테이너 런타임 | docker-compose.yml |
| **Docker Compose** | 멀티서비스 오케스트레이션 | 각 디렉토리별 compose 파일 |
| **Bash/Shell** | 스크립트 | Alloy 설정, 배포 자동화 |
| **Git** | 버전 관리 | .git, .gitignore |
| **MCP** | AI 협업 | .mcp.json (Claude Code 연동) |

### 포맷팅/린팅

- **.gitignore**: IDE, 환경변수, 로그, 빌드 산출물 제외
- **코드 주석**: 한국어
- **커밋 메시지**: 한국어

### 환경 변수

**파일**: `remote-node.env.example` (원격 노드 공통), `monitoring/.env` (모니터링 스택), `springboot/.env` (Spring Boot)

**핵심 변수**:
```bash
# 각 Alloy 에이전트
LOKI_URL=http://monitoring.example.com:3100
PROMETHEUS_URL=http://monitoring.example.com:9090
ALLOY_MEMORY_LIMIT=256MiB    # 메모리 누수 대비 필수

# Monitoring 스택
GRAFANA_ADMIN_PASSWORD=<secure>
MYSQL_DSN=user:password@tcp(heawave-host:3306)/db
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...  # Grafana 에러 + 백업 실패 알림 공용

# 백업·복구 (spec 001, monitoring/.env)
OCI_BUCKET_NAME=qasker-monitoring-backup      # T2 Terraform 산출물
OCI_NAMESPACE=<tenancy-namespace>              # `oci os ns get` 결과
OCI_REGION=ap-chuncheon-1                      # OCI-3 region 일치
OCI_CONFIG_FILE=/home/ubuntu/.oci/config       # API Key 방식 (instance principal 대안)
OCI_WRITER_PROFILE=BACKUP_MON_WRITER           # PUT/DELETE 전용 IAM (T2 분리)
OCI_READER_PROFILE=BACKUP_MON_READER           # GET 전용 IAM
BACKUP_RETENTION_DAYS=7                        # backup.sh + lifecycle 이중 안전망
BACKUP_FREE_LIMIT_BYTES=21474836480            # 20 GiB, verify.sh 90% 임계 기준
```

## 개발 워크플로우

### 로컬 환경 (홈서버 + Galaxy S20+)

1. `docker-compose.yml` 수정 → `docker compose up -d`
2. `alloy/config.alloy` 수정 → Alloy UI (`:12345`) 에서 실시간 확인
3. 로그/메트릭 → Grafana Explore에서 검증

### 프로덕션 배포 (OCI)

1. 파일 변경사항 Git 커밋
2. `monitoring/` 또는 `springboot/` 배포
3. Grafana 대시보드에서 모니터링

### 모니터링 검증 체크리스트

```bash
✓ Loki: curl http://monitoring:3100/ready
✓ Prometheus: curl http://monitoring:9090/-/ready
✓ Grafana: curl http://monitoring:3000/api/health
✓ Alloy: curl http://<node>:12345/metrics | grep loki_write
```

### 백업 시스템 검증 체크리스트

```bash
# 컨테이너 config 반영 (T1/T5 함정 방지)
✓ Prometheus admin API: docker inspect prometheus --format '{{.Config.Cmd}}' | grep enable-admin-api
✓ Alloy textfile 마운트: docker inspect alloy --format '{{range .Mounts}}{{.Source}}{{println}}{{end}}' | grep textfile_collector

# 백업 파이프라인
✓ 어제 백업 성공: curl -sf 'http://localhost:9090/api/v1/query?query=time()-q_asker_backup_last_success_timestamp' | jq -r '.data.result[]|.value[1]'
✓ 무결성 재검증: curl -sf 'http://localhost:9090/api/v1/query?query=q_asker_backup_verify_fail_total' | jq
✓ 저장소 사용률: curl -sf 'http://localhost:9090/api/v1/query?query=q_asker_backup_storage_usage_ratio' | jq
✓ Quarantine 부재: oci --profile BACKUP_MON_READER os object list -bn qasker-monitoring-backup --prefix quarantine/ --all | jq '.data|length'

# 스크립트 정합성 (호스트)
✓ cron 등록: cat /etc/cron.d/q-asker-backup
✓ logrotate 등록: sudo logrotate -d /etc/logrotate.d/q-asker-backup
✓ OCI IAM Writer/Reader 프로필: grep -E '^\[BACKUP_MON_' ~/.oci/config
```

## 작업 범위 제한

- **Kafka 브로커 설정은 이 프로젝트에서 관리하지 않는다** — broker-1/2/3은 별도 프로젝트로 분리됨

## 참고 자료

- **배포 가이드**: `README.md`
- **노션 히스토리**: PLG 스택 초기 프로젝트 설정 (2026-03-14)
- **옵저버빌리티 아키텍처**: Loki(라벨 인덱싱) / Prometheus(시계열 쿼리) / Grafana(시각화)
- **MySQL 모니터링**: Alloy MySQL exporter로 HeatWave 메트릭 수집 (PROCESS, REPLICATION CLIENT 권한)
