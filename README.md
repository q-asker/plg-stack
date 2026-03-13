# Q-Asker PLG 스택 배포 가이드

## 아키텍처 개요

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  broker-1    │  │  broker-2    │  │  broker-3    │  │  #2 Spring   │
│  홈서버      │  │  Galaxy S20+ │  │  OCI #1      │  │  Boot OCI    │
│  x86_64      │  │  arm64       │  │  ARM         │  │  ARM         │
│              │  │              │  │              │  │              │
│  ┌────────┐  │  │  ┌────────┐  │  │  ┌────────┐  │  │  ┌────────┐  │
│  │ Alloy  │──┼──┼──│ Alloy  │──┼──┼──│ Alloy  │──┼──┼──│ Alloy  │  │
│  └────────┘  │  │  └────────┘  │  │  └────────┘  │  │  └────────┘  │
│   로그+메트릭 │  │   로그+메트릭 │  │   로그+메트릭 │  │   로그+메트릭 │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │                 │
       └─────────────────┴────────┬────────┴─────────────────┘
                                  │ push (HTTP)
                                  ▼
                    ┌──────────────────────────┐
                    │  #4 Monitoring (OCI ARM)  │
                    │                          │
                    │  ┌──────┐  ┌──────────┐  │
                    │  │ Loki │  │Prometheus │  │
                    │  │:3100 │  │  :9090    │  │
                    │  └──┬───┘  └────┬─────┘  │
                    │     └─────┬─────┘        │
                    │           ▼              │
                    │     ┌──────────┐         │
                    │     │ Grafana  │         │
                    │     │  :3000   │         │
                    │     └──────────┘         │
                    │                          │
                    │  ┌────────┐              │
                    │  │ Alloy  │─── MySQL     │
                    │  │(로컬)  │    원격 scrape│
                    │  └────────┘    (HeatWave)│
                    └──────────────────────────┘
```

## 디렉토리 구조

```
plg-stack/
├── monitoring/              ← #4 Monitoring 인스턴스
│   ├── docker-compose.yml   ← Loki + Grafana + Prometheus + Alloy
│   ├── .env.example
│   ├── loki/
│   │   └── loki-config.yaml
│   ├── grafana/
│   │   └── provisioning/
│   │       └── datasources/
│   │           └── datasources.yml
│   ├── prometheus/
│   │   └── prometheus.yml
│   └── alloy/
│       └── config.alloy
├── broker-1/                ← 홈서버 (x86_64)
│   ├── docker-compose.yml
│   └── alloy/
│       └── config.alloy
├── broker-2/                ← Galaxy S20+ (arm64)
│   ├── docker-compose.yml
│   └── alloy/
│       └── config.alloy
├── broker-3/                ← OCI #1 (ARM)
│   ├── docker-compose.yml
│   └── alloy/
│       └── config.alloy
├── springboot/              ← OCI #2 (ARM)
│   ├── docker-compose.yml
│   └── alloy/
│       └── config.alloy
└── remote-node.env.example  ← 원격 노드 공통 환경변수 템플릿
```

## 배포 순서

### 1단계: #4 Monitoring 인스턴스 (먼저 배포)

```bash
# 1. 파일 복사
scp -r monitoring/ oci-monitoring:~/plg-stack/

# 2. 환경변수 설정
ssh oci-monitoring
cd ~/plg-stack/monitoring
cp .env.example .env
vi .env   # GRAFANA_ADMIN_PASSWORD, MYSQL_DSN 설정

# 3. Loki 데이터 디렉토리 권한 설정
docker volume create --name monitoring_loki-data
# 또는 바인드 마운트 사용 시:
# mkdir -p ./loki-data && sudo chown 10001:10001 ./loki-data

# 4. 실행
docker compose up -d

# 5. 확인
curl http://localhost:3100/ready    # Loki 상태
curl http://localhost:9090/-/ready  # Prometheus 상태
# Grafana: http://<monitoring-ip>:3000
```

### 2단계: OCI NSG 방화벽 설정

`nsg-monitoring`에 다음 인바운드 규칙 추가:

| 포트 | 용도 | 소스 |
|------|------|------|
| 3100 | Loki (Alloy → Loki push) | broker-1/2/3, springboot IP |
| 3000 | Grafana 대시보드 | 관리자 IP |
| 9090 | Prometheus (remote_write) | broker-1/2/3, springboot IP |

### 3단계: 각 원격 노드 배포

```bash
# broker-1 예시 (나머지 노드도 동일 패턴)
scp -r broker-1/ homeserver:~/plg-stack/

ssh homeserver
cd ~/plg-stack/broker-1
cp ../remote-node.env.example .env
vi .env   # LOKI_URL, PROMETHEUS_URL 확인

# Kafka/ZK 로그 경로 확인 후 docker-compose.yml 수정
vi docker-compose.yml   # 볼륨 마운트 경로 확인

docker compose up -d

# Alloy UI 확인: http://localhost:12345
```

## 배포 후 확인 체크리스트

- [ ] Grafana 접속 (http://monitoring:3000)
- [ ] Grafana → Explore → Loki 데이터소스 선택
- [ ] `{host="broker-1"}` 쿼리로 로그 확인
- [ ] `{job="kafka"}` 쿼리로 Kafka 로그 필터링
- [ ] Grafana → Explore → Prometheus 데이터소스 선택
- [ ] `node_cpu_seconds_total{instance="broker-1"}` 메트릭 확인
- [ ] `mysql_up{job="mysql"}` HeatWave 연결 확인

## 커스터마이징 필요 사항

### 로그 경로 확인 (각 노드별)
Kafka/ZK 로그 경로가 실제 환경과 다를 수 있으므로
`docker-compose.yml`의 볼륨 마운트를 실제 경로에 맞게 수정:

```yaml
volumes:
  # 실제 Kafka 로그 경로로 변경
  - /실제/kafka/로그/경로:/var/log/kafka:ro
  - /실제/zookeeper/로그/경로:/var/log/zookeeper:ro
```

### Spring Boot Actuator 설정
Prometheus가 Spring Boot 메트릭을 scrape하려면 application.yml에 추가:

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health, info, prometheus
  endpoint:
    prometheus:
      enabled: true
  metrics:
    tags:
      application: q-asker-api
```

의존성: `micrometer-registry-prometheus`
SecurityConfig에서 `/actuator/**` 허용 확인 필요

### HeatWave MySQL 모니터링 계정
Alloy MySQL exporter용 최소 권한 계정 생성:

```sql
CREATE USER 'alloy_monitor'@'%' IDENTIFIED BY 'secure_password';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'alloy_monitor'@'%';
FLUSH PRIVILEGES;
```

## 트러블슈팅

### Loki에 로그가 안 들어올 때
```bash
# 1. Alloy 상태 확인
curl http://<node>:12345/metrics | grep loki_write

# 2. Alloy 로그 확인
docker logs alloy-broker1

# 3. Loki 연결 테스트
curl -s http://monitoring.example.com:3100/ready

# 4. NSG 방화벽 확인 (OCI 콘솔)
```

### 메모리 사용량 모니터링
```bash
# 각 노드에서
docker stats alloy-broker1 --no-stream
```

## 버전 정보

| 컴포넌트 | 버전 | 비고 |
|----------|------|------|
| Loki | 3.6.0 | 최신 안정 버전 |
| Grafana | 12.4.0 | 최신 안정 버전 |
| Prometheus | v3.10.0 | remote_write 수신 지원 |
| Alloy | latest | Promtail 후속, 통합 에이전트 |
