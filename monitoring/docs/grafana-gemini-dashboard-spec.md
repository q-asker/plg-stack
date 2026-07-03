# Grafana Gemini 대시보드 구축 지침

## 목적

Gemini API 호출의 응답 시간, 토큰 사용량, 비용을 실시간 모니터링하는 Grafana 대시보드를 구축한다.

## 인프라 현황

- **애플리케이션**: Spring Boot 3.5.8 + Spring AI 1.1.2
- **모델**: Gemini 3 Flash Preview (`gemini-3-flash-preview`)
- **메트릭 수집**: Micrometer Prometheus → OCI-3 Prometheus 직접 Pull (Alloy 미경유)
- **로그 수집**: Alloy → 원격 Loki
- **대시보드**: Grafana (원격 모니터링 스택)
- **Prometheus 설정**: `monitoring/prometheus/prometheus.yml`

### 메트릭 수집 경로

Spring Boot는 `/actuator/prometheus`에서 Prometheus 포맷을 네이티브 노출하므로, OCI-3 Prometheus가 직접 Pull(scrape)한다. Alloy를 경유하지 않는다.

```
Spring Boot /actuator/prometheus → Prometheus scrape (job: spring-boot) → Grafana
```

- **Prometheus scrape 설정**: `monitoring/prometheus/prometheus.yml` (`job_name: "spring-boot"`)
- **타겟**: `origin-api.q-asker.com:9090`
- **instance 라벨**: `springboot-oci`

> Alloy는 node_exporter/process_exporter처럼 Prometheus 형식을 직접 노출하지 못하는 시스템 메트릭을 수집하여 push할 때 사용한다.

## 노출된 커스텀 메트릭 (Spring Boot → Prometheus)

`QuizOrchestrationServiceImpl.java`에서 Micrometer로 등록한 메트릭:

| Prometheus 메트릭명 | 타입 | 설명 | 단위 |
|---|---|---|---|
| `gemini_chunk_duration_seconds` | Timer (histogram) | 청크별 Gemini API 응답 시간 | seconds |
| `gemini_tokens_input_total` | Counter | 비캐시 입력 토큰 누적 | tokens |
| `gemini_tokens_cached_total` | Counter | 캐시 히트 토큰 누적 | tokens |
| `gemini_tokens_thinking_total` | Counter | thinking 토큰 누적 | tokens |
| `gemini_tokens_output_total` | Counter | 출력 토큰 누적 | tokens |
| `gemini_cost_estimated_total` | Counter | 추정 비용 누적 (캐시 저장 비용 제외) | USD |

### 비용 계산 로직 (코드 내 구현됨)

```
비캐시 입력 비용 = (promptTokens - cachedTokens) × $0.50 / 1M
캐시 읽기 비용  = cachedTokens × $0.05 / 1M
출력 비용       = completionTokens × $3.00 / 1M (thinking 포함)
캐시 저장 비용  = cachedTokens × $1.00 / 1M / hour (별도 로깅, 메트릭에 미포함)
```

### 로그 (Loki에 수집됨)

각 청크 처리 시 아래 형식의 로그가 출력된다:

```
Gemini Usage - pages=[1, 2], 2340ms, 입력: 2500토큰(캐시: 1800), thinking: 512토큰, 출력: 1200토큰, 추정 비용: $0.004590 (입력: $0.000350, 캐시읽기: $0.000090, 출력: $0.003600) [캐시 저장 비용 별도]
```

캐시 삭제 시:

```
캐시 저장 비용 추정 - 캐시 토큰: 15000, 사용 시간: 2.3분, 추정 비용: $0.000575
```

## 대시보드 패널 구성

### Row 1: 응답 시간

| 패널 | 타입 | PromQL | 설명 |
|---|---|---|---|
| 평균 응답 시간 | Stat | `rate(gemini_chunk_duration_seconds_sum[5m]) / rate(gemini_chunk_duration_seconds_count[5m])` | 최근 5분 평균 |
| p50 / p95 / p99 | Time series | `histogram_quantile(0.50, rate(gemini_chunk_duration_seconds_bucket[5m]))` | 퍼센타일별 응답 시간 추이 |
| 응답 시간 분포 | Heatmap | `rate(gemini_chunk_duration_seconds_bucket[5m])` | 시간대별 응답 시간 분포 |

### Row 2: 토큰 사용량

| 패널 | 타입 | PromQL | 설명 |
|---|---|---|---|
| 토큰 사용 추이 | Time series (stacked) | `rate(gemini_tokens_input_total[5m])`, `rate(gemini_tokens_cached_total[5m])`, `rate(gemini_tokens_thinking_total[5m])`, `rate(gemini_tokens_output_total[5m])` | 토큰 종류별 초당 사용량 |
| 캐시 히트율 | Gauge | `rate(gemini_tokens_cached_total[5m]) / (rate(gemini_tokens_input_total[5m]) + rate(gemini_tokens_cached_total[5m]))` | 캐시 효율 (0~1) |
| 누적 토큰 | Stat (4개) | `gemini_tokens_input_total`, `gemini_tokens_cached_total`, `gemini_tokens_thinking_total`, `gemini_tokens_output_total` | 서버 시작 이후 누적 |

### Row 3: 비용

| 패널 | 타입 | PromQL | 설명 |
|---|---|---|---|
| 시간당 비용 | Stat | `rate(gemini_cost_estimated_total[1h]) * 3600` | 현재 시간당 추정 비용 |
| 일일 비용 추이 | Time series | `increase(gemini_cost_estimated_total[1d])` | 일별 비용 추이 |
| 누적 비용 | Stat | `gemini_cost_estimated_total` | 서버 시작 이후 총 비용 |

### Row 4: 요청 수

| 패널 | 타입 | PromQL | 설명 |
|---|---|---|---|
| 분당 청크 요청 수 | Time series | `rate(gemini_chunk_duration_seconds_count[1m]) * 60` | RPM |
| 총 요청 수 | Stat | `gemini_chunk_duration_seconds_count` | 서버 시작 이후 누적 |

## 구현 완료

- **대시보드 JSON**: `monitoring/grafana/provisioning/dashboards/json/api-server-compute/q-asker-api-server-compute-gemini-api.json`
- **사전 작업 불필요**: `monitoring/prometheus/prometheus.yml`에 Spring Boot scrape 설정이 이미 존재 (`job_name: "spring-boot"`)

## 알림 규칙 (선택)

| 조건 | 심각도 | 설명 |
|---|---|---|
| `histogram_quantile(0.99, rate(gemini_chunk_duration_seconds_bucket[5m])) > 10` | Warning | p99 응답 시간 10초 초과 |
| `rate(gemini_cost_estimated_total[1h]) * 3600 > 1.0` | Critical | 시간당 비용 $1 초과 |
| `rate(gemini_chunk_duration_seconds_count[5m]) == 0` for 10m | Warning | 10분간 요청 없음 (서비스 중단 의심) |
