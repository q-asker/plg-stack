---
name: "PLG 스택 코딩 규칙"
description: "Java/Bash/YAML 코딩 컨벤션, 디렉토리 구조, Docker Compose 설정"
type: code-rules
---

# 코드 규칙

## 네이밍

- **Java 클래스**: PascalCase (`KafkaProducer`, `ConfigManager`)
- **Java 메서드/변수**: camelCase (`processMessage`, `isActive`)
- **Java 상수**: SCREAMING_SNAKE_CASE (`MAX_BATCH_SIZE`, `LOKI_ENDPOINT`)
- **Bash 함수/변수**: snake_case (`start_kafka`, `log_level`)
- **Docker Compose 서비스**: kebab-case (`kafka-broker`, `zookeeper-1`)
- **YAML 키**: snake_case (Alloy 설정, docker-compose.yml)
- **파일명**:
  - Java 소스: PascalCase (`KafkaConfig.java`)
  - 쉘 스크립트: snake_case (`start-services.sh`)
  - 설정 파일: snake_case 또는 프로젝트 기준 (`config.alloy`, `docker-compose.yml`)
- **코드 주석**: 한국어

## 디렉토리 구조

**핵심 원칙**: 각 노드(broker-1/2/3, springboot, monitoring)는 독립적인 Docker Compose 프로젝트로 관리

```
plg-stack/
├── springboot/                    ← OCI-2 Spring Boot 애플리케이션
│   ├── docker-compose.yml         ← Spring Boot + LibreOffice + Alloy
│   ├── src/                       ← (선택) Spring Boot 소스 코드
│   ├── alloy/
│   │   └── config.alloy
│   └── (선택) scripts/
│
├── monitoring/                    ← OCI-3 모니터링 스택
│   ├── docker-compose.yml         ← Loki + Prometheus + Grafana + Alloy
│   ├── .env.example               ← 환경 변수 템플릿
│   ├── loki/
│   │   └── loki-config.yaml
│   ├── prometheus/
│   │   └── prometheus.yml
│   ├── grafana/
│   │   └── provisioning/
│   │       └── datasources/
│   │           └── datasources.yml
│   ├── alloy/
│   │   └── config.alloy           ← MySQL exporter 설정
│   └── (선택) scripts/
│
├── CLAUDE.md                      ← 프로젝트 명세
├── README.md                      ← 배포 가이드
├── .gitignore                     ← Git 무시 목록
├── remote-node.env.example        ← 원격 노드 공통 환경 변수
│
└── .claude/                       ← Claude Code 설정
    ├── rules/                     ← 코딩 규칙
    ├── commands/
    ├── agents/
    ├── hooks/
    └── settings.json
```

## Docker Compose 규칙

### docker-compose.yml 작성 기준

1. **서비스 정의** (service names는 kebab-case)
   ```yaml
   services:
     kafka-broker:
       image: confluentinc/cp-kafka:7.5.0
       environment:
         KAFKA_BROKER_ID: 1
         KAFKA_ADVERTISED_LISTENERS: ...
     zookeeper:
       image: confluentinc/cp-zookeeper:7.5.0
   ```

2. **볼륨 마운트**: 절대 경로 또는 named volume 사용
   ```yaml
   volumes:
     - /실제/경로:/컨테이너/경로:ro    # 읽기 전용
     - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
   ```

3. **네트워크**: 기본 bridge 네트워크 사용 또는 명시적 정의
   ```yaml
   networks:
     kafka-net:
       driver: bridge
   ```

4. **환경 변수**:
   - 하드코딩 금지 → `.env` 파일 사용
   - `env_file: .env` 또는 `environment:` 에서 `${VAR_NAME}` 참조

### 환경 변수 파일 규칙

**파일 구조**:
- `remote-node.env.example` — 모든 원격 노드 공통 변수
- `monitoring/.env.example` — 모니터링 스택 전용 변수
- `.env` (Git 무시) — 실제 값

**예**:
```bash
# LOKI/Prometheus 서버 주소 (모든 원격 노드)
LOKI_URL=http://monitoring.example.com:3100
PROMETHEUS_URL=http://monitoring.example.com:9090

# Alloy 메모리 제한 (필수, 메모리 누수 대비)
ALLOY_MEMORY_LIMIT=256MiB

# 모니터링 스택 전용
GRAFANA_ADMIN_PASSWORD=secure_password
MYSQL_DSN=user:password@tcp(heawave-host:3306)/db
```

## Alloy 설정 규칙 (config.alloy)

1. **로그 수집 (로컬 파일)**
   ```alloy
   local.file_sd "kafka_logs" {
     files = ["/var/log/kafka/*.log"]
     refresh_interval = "5s"
   }

   loki.source.file "kafka" {
     targets = local.file_sd.kafka_logs.targets
     forward_to = [loki.write.default.receiver]
   }
   ```

2. **메트릭 수집 (node_exporter, Spring Boot Actuator 등)**
   ```alloy
   prometheus.scrape "local_metrics" {
     targets = [{__address__ = "localhost:9100"}]  # node_exporter
     forward_to = [prometheus.remote_write.default.receiver]
   }
   ```

3. **원격 서버 푸시 설정**
   ```alloy
   loki.write "default" {
     clients = [{
       url = env("LOKI_URL")  # 환경 변수 참조
     }]
   }

   prometheus.remote_write "default" {
     endpoint {
       url = env("PROMETHEUS_URL")
       headers = {"X-Custom-Header" = "value"}
     }
   }
   ```

4. **메모리 관리**
   ```bash
   # Docker Compose에서 환경 변수 설정
   environment:
     - GOMEMLIMIT=${ALLOY_MEMORY_LIMIT}  # 256MiB 권장
   ```

## 제약 사항

- ❌ **CLAUDE.md 수정 없이 기술 스택 변경** 금지
- ❌ **환경 변수를 Docker Compose에 하드코딩** 금지 → `.env` 파일 사용
- ❌ **로그 경로를 상대 경로로 지정** 금지 → 절대 경로 또는 Docker 명명 볼륨 사용
- ❌ **Alloy 메모리 제한 없음** 금지 → 항상 `GOMEMLIMIT` 설정 (메모리 누수 문제)
- ⚠️ **컨테이너 이미지 `latest` 태그** — 프로덕션에서는 구체적 버전 지정 권장

## 포맷팅

- **YAML** (docker-compose.yml, Alloy, Prometheus): 스페이스 2칸 들여쓰기
- **Bash/Shell**: 스페이스 4칸 들여쓰기, shellcheck 호환
- **Java** (선택): Checkstyle 또는 Spotless 사용 가능

## 버전 관리 (.gitignore)

`plg-stack/.gitignore`에 포함되어야 할 항목:

```
# 환경 변수
.env
.env.local
*.env

# IDE
.idea/
.vscode/
*.swp
*.swo

# Docker
docker-compose.override.yml

# 로그/임시 파일
logs/
*.log
tmp/

# 빌드 산출물 (Spring Boot)
build/
target/
*.jar
*.class

# 운영 데이터 (Git에 올리면 안 됨)
*.sqlite
*.db
data/
volumes/
```

## 배포 및 운영 체크리스트

각 노드별 docker-compose.yml 작성 후:

- [ ] 이미지 버전 명시 (latest 금지)
- [ ] `.env` 파일 확인 (LOKI_URL, PROMETHEUS_URL, ALLOY_MEMORY_LIMIT 설정)
- [ ] 볼륨 경로 검증 (존재하는 경로인지 확인)
- [ ] `docker compose config` 로 YAML 문법 검증
- [ ] `docker compose up -d` 로 정상 시작 확인
- [ ] `docker logs <service>` 로 에러 확인
- [ ] Alloy UI (`:12345`)에서 메트릭/로그 수집 상태 확인
- [ ] Grafana Explore에서 Loki/Prometheus 데이터 조회 가능 확인

## 참고 자료

- **Alloy 공식 문서**: https://grafana.com/docs/alloy/latest/
- **Docker Compose 공식**: https://docs.docker.com/compose/
- **Loki 라벨 전략**: CLAUDE.md 참고
- **Kafka 브로커 설정**: broker-{1,2,3}/docker-compose.yml 예제
