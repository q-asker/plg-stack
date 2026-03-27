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
| **로그 저장소** | Loki | 3.6.0 | 라벨 기반 로그 인덱싱 및 저장 |
| **메트릭 저장소** | Prometheus | v3.10.0 | 시계열 메트릭 저장 및 PromQL 쿼리 |
| **시각화** | Grafana | 12.4.0 | 대시보드 및 알림 |
| **데이터베이스** | OCI HeatWave MySQL | 관리형 | 애플리케이션 및 메타데이터 저장 |
| **배포/오케스트레이션** | Docker | 24.x+ | 컨테이너 런타임 |
| | Docker Compose | 2.x+ | 다중 서비스 오케스트레이션 |
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
      └────────────────────────────┘
```

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
│   │   └── prometheus.yml       ← Prometheus scrape 설정
│   ├── grafana/
│   │   └── provisioning/
│   │       └── datasources/
│   │           └── datasources.yml
│   ├── alloy/
│   │   └── config.alloy         ← MySQL exporter 설정
│   └── local/                   ← 로컬 테스트용 모니터링 스택
│       ├── docker-compose.yml   ← Prometheus + Grafana (로컬)
│       └── prometheus/
│           └── prometheus.yml   ← Spring Boot Actuator 스크래핑
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

## 작업 범위 제한

- **Kafka 브로커 설정은 이 프로젝트에서 관리하지 않는다** — broker-1/2/3은 별도 프로젝트로 분리됨

## 참고 자료

- **배포 가이드**: `README.md`
- **노션 히스토리**: PLG 스택 초기 프로젝트 설정 (2026-03-14)
- **옵저버빌리티 아키텍처**: Loki(라벨 인덱싱) / Prometheus(시계열 쿼리) / Grafana(시각화)
- **MySQL 모니터링**: Alloy MySQL exporter로 HeatWave 메트릭 수집 (PROCESS, REPLICATION CLIENT 권한)
