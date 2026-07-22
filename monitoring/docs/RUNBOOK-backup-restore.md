# Prometheus & Loki 백업·복구 RUNBOOK

**대상**: OCI-3 모니터링 인스턴스 운영자.
**목적**: 신규 합류 운영자가 외부 도움 없이 이 문서만 보고 평시 모니터링·장애 대응·복원·리허설을 수행할 수 있게 한다 (SC-007).
**전제**: [프로메테우스로키백업복구설명.md](프로메테우스로키백업복구설명.md)에서 배경 지식을 이미 이해했다고 가정.

---

## 목차

1. 평시 모니터링 (매일 확인 사항)
2. 장애 감지 → 의사결정 트리
3. 복원 절차 — Prometheus 단독
4. 복원 절차 — Loki 단독
5. 복원 절차 — both (동시 복구)
6. 복원 후 검증 쿼리
7. Quarantine 관리
8. `.bak.<ts>` 디렉토리 정리
9. NSG 점검 (9090 외부 차단)
10. Slack 알림별 대응
11. GameDay 체크리스트 (분기 1회)
12. GameDay Log (기록 부록)
13. 자주 발생하는 실수

---

## 1. 평시 모니터링

### 1.1 Grafana 대시보드

접속: <https://mon.q-asker.com>

핵심 확인 패널:
- **q_asker_backup_last_success_timestamp{store}** — 마지막 백업 성공 이후 경과 시간
- **q_asker_backup_duration_seconds{store}** — 백업 소요 시간 추이
- **q_asker_backup_size_bytes{store}** — 백업 크기 변화 (증가율 모니터링)
- **q_asker_backup_loki_downtime_seconds** — Loki 정지 시간 (SC-005 60초 감시)
- **q_asker_backup_storage_usage_ratio** — 저장소 사용률 (80% 조기·90% 임박 2단계 경고 기준, §10.2)

### 1.2 매일 아침 확인 절차 (60초)

```bash
sshmon
```

```bash
# 어제 백업 성공 여부
sudo tail -30 /var/log/q-asker-backup.log | grep -E "backup.sh 정상 종료|ERROR"

# 마지막 성공 timestamp가 24시간 이내인지
curl -sf 'http://localhost:9090/api/v1/query?query=time()-q_asker_backup_last_success_timestamp' \
  | jq -r '.data.result[] | "\(.metric.store): \(.value[1]) sec ago"'
# 두 store 모두 86400(24h) 미만이어야 함
```

### 1.3 주간 확인 (매주 월요일)

```bash
# 저장소 사용률 추이
curl -sf 'http://localhost:9090/api/v1/query?query=q_asker_backup_storage_usage_ratio' \
  | jq -r '.data.result[0].value[1]'
# 0.80 미만 권장. 0.80 이상이면 증가 추세 점검 + 필요 시 백업 주기 늘리기(§10.2)

# quarantine 누적 확인
oci --profile BACKUP_MON_READER os object list \
  -bn qasker-monitoring-backup --prefix "quarantine/" --all \
  | jq -r '.data[].name' | wc -l
# 0이 정상. 발생 시 §7 quarantine 관리 참고

# .bak.<ts> 디렉토리 누적 확인
sudo ls -la /mnt/monitoring/ | grep -E "\.bak\." | wc -l
# 최근 GameDay/복원 리허설 결과만 있어야 함. §8 참고
```

### 1.4 백업 스크립트 옵션 (빠른 참조)

```bash
sudo ./monitoring/scripts/backup.sh [옵션]
```

| 옵션 | 설명 |
|------|------|
| `--target=prometheus\|loki\|both` | 백업 대상 (기본 `both`) |
| `--retention-days=N` | 보관일 override(`.env`의 `BACKUP_RETENTION_DAYS`보다 우선). 일반 도구 — 저장소 압박 대응은 백업 주기 늘리기 권장(§10.2) |
| `--dry-run` | 업로드·정리·알림 없이 시뮬레이션 |
| `--debug` | `set -x` 상세 로그 |

- 백업은 업로드 직후 **인라인 무결성 검증**(sha256 재비교)을 수행하고, 실패분은 `quarantine/`로 격리한다.
- 저장소 사용률 경고는 **80%(⚠️ WARN) · 90%(❌ ERROR) 2단계**로 자동 발송된다(§10.2). 단계 상향 시에만 알리고 회복 시 재무장.

---

## 2. 장애 감지 → 의사결정 트리

```
[알림 또는 이상 감지]
   │
   ├─ Slack "q_asker_backup ERROR" 알림
   │  ├─ prometheus 관련 → §3 Prometheus 복원
   │  ├─ loki 관련        → §4 Loki 복원
   │  └─ 저장소 임계·격리 → §7 Quarantine 관리 or §10.2 임계 알림
   │
   ├─ Grafana에서 last_success_timestamp가 24h 초과
   │  └─ /var/log/q-asker-backup.log 확인 → 원인 분류 후 §10
   │
   ├─ OCI-3 인스턴스/디스크 손실 (재해)
   │  └─ §5 both 복원 (새 인스턴스 프로비저닝 필요 시 별건 절차)
   │
   ├─ Grafana 데이터 조회 실패 (일부 데이터 손실)
   │  └─ 손실 스토어에 따라 §3 or §4 (단독 복원)
   │
   └─ 정기 GameDay 리허설
      └─ §11 GameDay 체크리스트
```

---

## 3. 복원 절차 — Prometheus 단독

### 3.1 사전 확인

```bash
sshmon
cd ~/plg-stack

# 현재 Prometheus 컨테이너 상태
docker compose -f monitoring/docker-compose.yml ps prometheus
docker logs prometheus 2>&1 | tail -20

# 사용 가능한 백업 시점 조회 (--snapshot 미지정으로 목록만 확인)
sudo ./monitoring/scripts/restore.sh --target=prometheus
# → 목록 출력 후 exit 2
```

### 3.2 복원 실행

```bash
# 시점 결정 (예: 20260701-1447)
SNAPSHOT=20260701-1447

sudo ./monitoring/scripts/restore.sh \
  --target=prometheus \
  --snapshot=${SNAPSHOT} 2>&1 | tee /tmp/restore-prom-$(date +%Y%m%d-%H%M).log
```

예상 소요: **3~5분** (다운로드 22s + 압축 해제 99s + 헬스 폴링 11s + 여유).

### 3.3 성공 확인

```bash
# Prometheus healthy
curl -sf http://localhost:9090/-/ready
# → Prometheus Server is Ready.

# 복원된 시점 이전 데이터 조회 가능한지
curl -sf 'http://localhost:9090/api/v1/query?query=up' \
  | jq -r '.data.result[].metric | "\(.job): \(.instance)"'

# .bak.<unix_ts> 원본 보존 확인 (자동 삭제 X)
sudo ls -la /mnt/monitoring/ | grep prometheus.bak.
# → prometheus.bak.1783005679 같은 디렉토리 존재. §8 정리 참고.
```

### 3.4 실패 시 자동 롤백 (수동 개입 불필요)

`restore.sh`가 `_rollback`을 자동 수행:
1. 새 `/mnt/monitoring/prometheus` 삭제
2. `.bak.<ts>` 원위치로 mv back
3. `docker compose start prometheus`

실패 시 로그 확인:
```bash
grep -E "ROLLBACK|ERROR" /tmp/restore-prom-*.log | tail
```

수동 롤백이 필요한 극단 케이스:
```bash
# .bak.<ts> 확인
sudo ls -la /mnt/monitoring/ | grep prometheus.bak.

# 자동 롤백이 실패한 경우 수동 복원
sudo docker compose -f ~/plg-stack/monitoring/docker-compose.yml stop prometheus
sudo rm -rf /mnt/monitoring/prometheus
sudo mv /mnt/monitoring/prometheus.bak.<ts> /mnt/monitoring/prometheus
sudo docker compose -f ~/plg-stack/monitoring/docker-compose.yml start prometheus
curl -sf http://localhost:9090/-/ready
```

---

## 4. 복원 절차 — Loki 단독

### 4.1 사전 확인

```bash
sshmon
cd ~/plg-stack

docker compose -f monitoring/docker-compose.yml ps loki

sudo ./monitoring/scripts/restore.sh --target=loki
# 사용 가능 timestamp 목록 확인
```

### 4.2 복원 실행

```bash
SNAPSHOT=20260701-1447

sudo ./monitoring/scripts/restore.sh \
  --target=loki \
  --snapshot=${SNAPSHOT} 2>&1 | tee /tmp/restore-loki-$(date +%Y%m%d-%H%M).log
```

예상 소요: **30~60초** (다운로드 2s + 압축 해제 5s + 헬스 폴링 30s).

### 4.3 성공 확인

```bash
# Loki healthy
curl -sf http://localhost:3100/ready

# 라벨 조회 (복원 시점 이전 로그 접근성)
curl -sf 'http://localhost:3100/loki/api/v1/labels' | jq -r '.data[]' | head

# .bak 원본 보존
sudo ls -la /mnt/monitoring/ | grep loki.bak.
```

---

## 5. 복원 절차 — both (동시 복구)

두 스토어를 모두 잃은 시나리오 (예: 블록볼륨 손실).

### 5.1 실행

```bash
SNAPSHOT=20260703-0300

sudo ./monitoring/scripts/restore.sh \
  --target=both \
  --snapshot=${SNAPSHOT} 2>&1 | tee /tmp/restore-both-$(date +%Y%m%d-%H%M).log
```

예상 소요: **~5분** (Prom 3~4분 + Loki 30초, 순차 실행).

**핵심**: `restore.sh`는 Prom과 Loki를 **독립 시도**한다 (Q3=B). 한쪽 실패해도 다른 쪽 계속 진행 → 부분 복원 결과 발생 가능.

### 5.2 부분 성공 시 대응

```bash
# 로그에서 각 스토어별 결과 확인
grep -E "===== (prometheus|loki) 복원 완료|===== (prometheus|loki).*실패" /tmp/restore-both-*.log

# 실패한 스토어만 재실행 (--target=<실패 스토어>)
# 성공한 스토어의 .bak.<ts>는 그대로 두고 진행
```

---

## 6. 복원 후 검증 쿼리

### 6.1 Prometheus

```bash
# 기본 헬스
curl -sf http://localhost:9090/-/ready
curl -sf http://localhost:9090/-/healthy

# 저장된 지표 시리즈 수
curl -sf 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_head_series' \
  | jq -r '.data.result[0].value[1]'

# 특정 스크레이프 대상 살아있는지
curl -sf 'http://localhost:9090/api/v1/query?query=up' \
  | jq -r '.data.result[] | "\(.metric.job)/\(.metric.instance): \(.value[1])"'
# up=1 이어야 정상

# 복원 시점 이전 데이터가 실제로 조회되는지 (예: 24h 전)
curl -sf 'http://localhost:9090/api/v1/query?query=up&time='$(date -d '24 hours ago' +%s) \
  | jq
```

### 6.2 Loki

```bash
# 기본 헬스
curl -sf http://localhost:3100/ready

# 사용 가능한 라벨
curl -sf 'http://localhost:3100/loki/api/v1/labels' | jq -r '.data[]'

# 특정 라벨의 로그가 있는지 (백업 시점 이전 범위)
curl -sf --data-urlencode 'query={job="loki"}' \
  'http://localhost:3100/loki/api/v1/query_range?start='$(date -d '2 hours ago' +%s000000000) \
  | jq -r '.data.result | length'
# 0 이상이면 정상 (백업 시점 이전 로그 확인됨)
```

### 6.3 백업 무결성 수동 확인

정기 백업은 업로드 직후 인라인으로 무결성을 검증한다. 특정 스냅샷을 즉시 재확인하려면
저장된 tar.gz를 내려받아 해시를 재계산해 비교한다.

```bash
# 확인할 스냅샷 키 (store/YYYYMMDD-HHMM-store.*)
BASE_KEY=prometheus/20260701-1447-prometheus

oci --profile BACKUP_MON_READER os object get \
  -bn qasker-monitoring-backup --name "${BASE_KEY}.tar.gz" --file /tmp/chk.tar.gz
oci --profile BACKUP_MON_READER os object get \
  -bn qasker-monitoring-backup --name "${BASE_KEY}.sha256" --file /tmp/chk.sha256

# 재계산 해시와 저장된 해시 비교 (일치해야 정상)
sha256sum /tmp/chk.tar.gz | awk '{print $1}'
awk '{print $1}' /tmp/chk.sha256

# quarantine 없는지 재확인
oci --profile BACKUP_MON_READER os object list \
  -bn qasker-monitoring-backup --prefix "quarantine/" --all \
  | jq -r '.data[].name'
```

---

## 7. Quarantine 관리

### 7.1 quarantine 발생 감지

Slack에 `prometheus` 또는 `loki` ERROR 알림 도착 (backup.sh 인라인 검증이 무결성 불일치를 감지하면 해당 객체를 quarantine으로 이동).

```bash
sshmon
cd ~/plg-stack

# quarantine된 객체 목록
oci --profile BACKUP_MON_READER os object list \
  -bn qasker-monitoring-backup --prefix "quarantine/" --all \
  | jq -r '.data[].name'
```

### 7.2 조사 절차

```bash
# 격리된 tar.gz 다운로드
TARGET_KEY=quarantine/prometheus/20260701-1447-prometheus.tar.gz
oci --profile BACKUP_MON_READER os object get \
  -bn qasker-monitoring-backup --name "$TARGET_KEY" \
  --file /tmp/quarantine-tar.gz

# sha256 다운로드
SHA_KEY=quarantine/prometheus/20260701-1447-prometheus.sha256
oci --profile BACKUP_MON_READER os object get \
  -bn qasker-monitoring-backup --name "$SHA_KEY" \
  --file /tmp/quarantine-sha256

# 로컬에서 재검증
sha256sum /tmp/quarantine-tar.gz
cat /tmp/quarantine-sha256
# 두 해시 비교 → 원인 판단
```

### 7.3 조사 결과별 처리

| 결과 | 판정 | 처리 |
|------|------|------|
| tar.gz와 sha256 일치 | 인라인 검증 오탐 | §7.4 원위치 복원 |
| sha256만 손상 | 부분 손상 | §7.5 tar.gz 복원 + sha256 재생성 |
| tar.gz 손상 | 데이터 손상 확정 | §7.6 완전 삭제 |

### 7.4 원위치 복원 (오탐)

```bash
# tar.gz + sha256 둘 다 원위치로 rename back
BASE_KEY=prometheus/20260701-1447-prometheus
oci --profile BACKUP_MON_WRITER os object rename \
  -bn qasker-monitoring-backup \
  --source-name "quarantine/${BASE_KEY}.tar.gz" \
  --new-name "${BASE_KEY}.tar.gz"

oci --profile BACKUP_MON_WRITER os object rename \
  -bn qasker-monitoring-backup \
  --source-name "quarantine/${BASE_KEY}.sha256" \
  --new-name "${BASE_KEY}.sha256"

# 재검증: §6.3 백업 무결성 수동 확인 절차로 해시 일치 확인
```

### 7.5 부분 손상 (tar.gz 정상 + sha256 손상)

```bash
BASE_KEY=prometheus/20260701-1447-prometheus

# tar.gz만 원위치로
oci --profile BACKUP_MON_WRITER os object rename \
  -bn qasker-monitoring-backup \
  --source-name "quarantine/${BASE_KEY}.tar.gz" \
  --new-name "${BASE_KEY}.tar.gz"

# 손상 sha256 삭제
oci --profile BACKUP_MON_WRITER os object delete \
  -bn qasker-monitoring-backup \
  --name "quarantine/${BASE_KEY}.sha256" --force

# 새 sha256 생성 후 재업로드
oci --profile BACKUP_MON_READER os object get \
  -bn qasker-monitoring-backup --name "${BASE_KEY}.tar.gz" \
  --file /tmp/tar.gz
NEW_HASH=$(sha256sum /tmp/tar.gz | awk '{print $1}')
printf '%s  %s\n' "$NEW_HASH" "${BASE_KEY##*/}.tar.gz" > /tmp/new.sha256

oci --profile BACKUP_MON_WRITER os object put \
  -bn qasker-monitoring-backup \
  --name "${BASE_KEY}.sha256" \
  --file /tmp/new.sha256 --force

# 재검증: §6.3 백업 무결성 수동 확인 절차로 해시 일치 확인
```

### 7.6 완전 삭제 (손상 확정)

```bash
BASE_KEY=quarantine/prometheus/20260701-1447-prometheus

oci --profile BACKUP_MON_WRITER os object delete \
  -bn qasker-monitoring-backup --name "${BASE_KEY}.tar.gz" --force

oci --profile BACKUP_MON_WRITER os object delete \
  -bn qasker-monitoring-backup --name "${BASE_KEY}.sha256" --force
```

### 7.7 정기 정리 정책

- quarantine이 30일 이상 누적되면 원인 조사 후 확정 처리
- 다음날 backup.sh가 새 백업을 생성하므로 오래된 손상은 대체됨
- 90일 이상 격리된 객체는 원인 미규명이라도 삭제 검토 (RUNBOOK 정기 검토 대상)

---

## 8. `.bak.<ts>` 디렉토리 정리

`restore.sh` 성공 시 원본은 `/mnt/monitoring/<store>.bak.<unix_ts>`로 보존 (자동 삭제 X).

### 8.1 확인

```bash
sudo du -sh /mnt/monitoring/*.bak.* 2>/dev/null
# 예: 900M   /mnt/monitoring/prometheus.bak.1783005679
#     120M   /mnt/monitoring/loki.bak.1783005576
```

### 8.2 정리 절차

**대전제**: 복원 후 서비스가 정상 동작함을 최소 24시간 이상 확인한 뒤에만 정리.

```bash
# 최소 24시간 지난 것만 대상 (unix ts로 판단)
NOW=$(date +%s)
CUTOFF=$((NOW - 86400))  # 24h 이전

for BAK in $(sudo ls -d /mnt/monitoring/*.bak.* 2>/dev/null); do
    TS=$(echo "$BAK" | grep -oE '[0-9]+$')
    if [ "$TS" -lt "$CUTOFF" ]; then
        echo "삭제 대상: $BAK (unix_ts=$TS)"
        # 삭제 실행은 수동 (안전 지향)
        # sudo rm -rf "$BAK"
    fi
done
```

주석 해제하기 전에 반드시:
1. `docker compose ps` 정상
2. Grafana에서 대시보드 조회 정상
3. §6.3 백업 무결성 수동 확인 통과

---

## 8-B. 월간 아카이브 (옛날 로그 장기 보존)

Prometheus/Loki 자체가 180일 retention이라 그보다 오래된 데이터는 매일 백업에도 담기지 않는다. 옛날 로그를 장기 보존하려면 **매월 대표본 하나만 별도 접두사에 영구 보관**한다.

### 8-B.0 아카이브 대상 상세

**매월 1일 KST 05:00에 아카이브되는 것은 다음 4개 객체입니다.**

| 원본 위치 (Standard tier) | 아카이브 위치 (Standard tier, 영구 보존) |
|---------------------------|-------------------------------|
| `prometheus/YYYYMMDD-HHMM-prometheus.tar.gz` | `monthly-archive/YYYYMM-prometheus.tar.gz` |
| `prometheus/YYYYMMDD-HHMM-prometheus.sha256` | `monthly-archive/YYYYMM-prometheus.sha256` |
| `loki/YYYYMMDD-HHMM-loki.tar.gz` | `monthly-archive/YYYYMM-loki.tar.gz` |
| `loki/YYYYMMDD-HHMM-loki.sha256` | `monthly-archive/YYYYMM-loki.sha256` |

- 4개 객체 합계 **약 1 GiB/월** (Prom 927 MiB + Loki 117 MiB + 소량 sha256)
- 파일명은 원본 timestamp 대신 `YYYYMM` 태그로 단순화 (예: `202607-prometheus.tar.gz`)
- 원본 timestamp는 그 달의 **마지막 백업 시점**이 자동 선택됨 (`list_available_snapshots`에서 `YYYYMM-*`로 시작하는 것 중 최신)

**각 아카이브 파일이 담고 있는 데이터 범위**:

| 아카이브 | tar.gz 안의 실제 데이터 범위 |
|----------|-------------------------------|
| `202606-*.tar.gz` (2026-06 마지막 백업) | 2025-12 말 ~ 2026-06 말 (약 180일) |
| `202607-*.tar.gz` (2026-07 마지막 백업) | 2026-01 말 ~ 2026-07 말 |
| `202608-*.tar.gz` (2026-08 마지막 백업) | 2026-02 말 ~ 2026-08 말 |

**옛날 로그 유지 원리**: full backup의 특성상 각 아카이브 파일에 그 시점까지의 최대 180일치가 담긴다. 오래된 시점의 아카이브 파일을 삭제하지 않으면 **그 시점의 데이터가 무기한 살아있다**. 예를 들어 2025-12 데이터를 5년 후에도 조회하려면 `202606-*` 파일만 있으면 됨.

**실행 예시** (2026-08-01 KST 05:00):
1. YYYY_MM = `202607`
2. `prometheus/`에서 `20260731-*` 중 최신 조회 → 예: `20260731-0300`
3. READER로 원본 다운로드 → 해시 검증 → WRITER로 `monthly-archive/202607-<store>.<ext>` 업로드 (Standard 유지)
4. Slack SUCCESS 알림 발송

### 8-B.1 자동 실행

- 스크립트: `monitoring/scripts/archive-monthly.sh`
- cron: 매월 1일 KST 05:00 (`/etc/cron.d/q-asker-backup`)
- 동작: 전월 마지막 백업 4개(prom+loki tar.gz + sha256)를 READER 다운로드 → 해시 검증 → WRITER로 `monthly-archive/YYYYMM-<store>.<ext>` 업로드 (Standard 유지, lifecycle 제외로 영구 보존)

### 8-B.2 저장 크기 · 정책

- 매월 4개 객체 ≈ 1 GiB (Prom 927 MiB + Loki 117 MiB + 소량 sha256)
- **자동 삭제 없음** (Terraform lifecycle에서 `monthly-archive/*` 제외)
- backup.sh의 2단계 임계 알림(80%/90%)이 저장소 압박 감지 시 알림 → 운영자 수동 정리 (아래 8-B.4)

### 8-B.3 아카이브 상태 확인

```bash
# 모든 월간 아카이브 목록 + tier
oci --profile BACKUP_MON_READER os object list \
  -bn qasker-monitoring-backup --prefix "monthly-archive/" --all \
  | jq -r '.data[] | "\(."storage-tier")  \(."time-created" | .[:10])  \(.name)"' \
  | sort
```

### 8-B.4 오래된 아카이브 수동 정리 (임계 알림 발생 시)

```bash
# 가장 오래된 아카이브부터 삭제 (예: 2년 이상 된 것)
CUTOFF_YM=$(TZ=Asia/Seoul date --date='24 months ago' +%Y%m)

for KEY in $(oci --profile BACKUP_MON_READER os object list \
              -bn qasker-monitoring-backup --prefix "monthly-archive/" --all \
              | jq -r '.data[].name' \
              | awk -F'/' '{ split($2, a, "-"); if (a[1] < "'$CUTOFF_YM'") print $0 }'); do
    echo "삭제 예정: $KEY"
    # 실제 삭제는 수동 확인 후:
    # oci --profile BACKUP_MON_WRITER os object delete -bn qasker-monitoring-backup --name "$KEY" --force
done
```

### 8-B.5 옛날 아카이브 복원

`monthly-archive/*`는 Standard tier이므로 **retrieval 없이 즉시 다운로드** 가능하다.
파일명 규칙만 `restore.sh`가 기대하는 `store/YYYYMMDD-HHMM-store.*`와 달라(월 태그 `YYYYMM`),
수동으로 내려받아 확인한다.

```bash
# 예: 2026-06 아카이브 다운로드
oci --profile BACKUP_MON_READER os object get \
  -bn qasker-monitoring-backup \
  --name "monthly-archive/202606-prometheus.tar.gz" \
  --file /tmp/202606-prometheus.tar.gz

# 해시 검증 후 격리 컨테이너에서 tar-x + Prometheus로 확인
oci --profile BACKUP_MON_READER os object get \
  -bn qasker-monitoring-backup --name "monthly-archive/202606-prometheus.sha256" --file /tmp/202606.sha256
sha256sum /tmp/202606-prometheus.tar.gz; awk '{print $1}' /tmp/202606.sha256   # 일치 확인
```

> 참고: 이 시스템은 **Archive tier를 사용하지 않는다.** 데일리 백업은 Standard로 7일 보존 후
> 삭제되고, 월간 아카이브도 Standard로 영구 보존된다. 무료 20GB는 Standard+Archive 합산이라
> Archive 전환은 비용 이득이 없고 복원 지연만 커지기 때문. (retrieval 대기 절차 불필요)

---

## 9. NSG 점검 (9090 외부 차단)

### 9.1 왜 필수인가

Prometheus admin API는 `--web.enable-admin-api` 플래그로 활성화되며, snapshot 뿐 아니라 **`delete_series`, `clean_tombstones` 같은 파괴 API도 함께 노출**된다. 외부에 9090이 열려 있으면 인증 없이 데이터 파괴 가능.

### 9.2 확인 방법

**OCI 콘솔**:
- Networking → Virtual Cloud Networks → `<모니터링 VCN>` → Network Security Groups → `nsg-monitoring`
- Ingress Rules에서 9090 인바운드가:
  - ❌ Source: 0.0.0.0/0 (공용 허용) — **위험**
  - ✅ Source: 사설망(10.0.0.0/16 등) 또는 관리자 IP만 — **정상**

**CLI로 확인**:
```bash
oci network nsg rules list \
  --nsg-id ocid1.networksecuritygroup.oc1.ap-chuncheon-1.aaaaaaaaamr2hlzkkpi76gg5dqufgszh6yzwf7rnd3ylhiyswaiwa3mscinq \
  --auth instance_principal \
  | jq '.data[] | select(.direction=="INGRESS" and .["tcp-options"]?.["destination-port-range"]?.min==9090)'
```

### 9.3 정기 점검 주기

- 분기별 GameDay 시 함께 확인
- NSG 규칙 변경 시 즉시 재점검

---

## 10. Slack 알림별 대응

### 10.1 `❌ [q-asker-backup] ERROR — prometheus` / `loki`

**backup.sh 실행 실패**.

```bash
sshmon
sudo tail -100 /var/log/q-asker-backup.log
```

원인별 대응:
| 로그 힌트 | 원인 | 대처 |
|-----------|------|------|
| `admin APIs disabled` | admin API 미활성 (T1 미적용) | `docker compose up -d --force-recreate prometheus` |
| `필수 명령 미설치: jq` | 의존성 부재 | `sudo apt install -y jq` |
| `Loki 정지 시간 X > 60s` | 대용량 Loki + SC-005 위반 | Loki 크기 확인, 로그 다이어트 검토 |
| `무결성 불일치 → quarantine 이동` | 인라인 검증 실패 (업로드 손상 등) | §7 Quarantine 관리 절차 진행 |
| `OCI ... 401/403/NotAuthorized` | 자격 증명 문제 | `~/.oci/config` 프로필 재점검 |

수동 재실행:
```bash
sudo ./monitoring/scripts/backup.sh --target=both
```

### 10.2 `⚠️/❌ [q-asker-backup] storage-threshold`

**저장소 사용률 2단계 경고** — 80% 도달 시 `⚠️ WARN`(조기), 90% 도달 시 `❌ ERROR`(임박).
단계가 올라갈 때만 발송되고(재발송 억제), 회복 시 다시 무장된다.

```bash
# 현재 사용량 확인
oci --profile BACKUP_MON_READER os bucket get \
  -bn qasker-monitoring-backup --fields approximateSize \
  | jq -r '.data."approximate-size"'
# (null 반환은 OCI 지연으로 정상, T7 후속 개선 후보)

# 객체 개수 및 크기 합산 (정확값)
oci --profile BACKUP_MON_READER os object list \
  -bn qasker-monitoring-backup --all \
  | jq '[.data[].size] | add'
```

대응 옵션:
1. **백업 주기 늘리기(개발자 판단 레버)**: PLG 백업 빈도를 낮춰 발자국 증가를 늦춘다.
   관측 데이터라 RPO 여유가 크다(운영 데이터 MySQL은 6h 유지). `/etc/cron.d/q-asker-backup`에서:
   ```bash
   # 매일 → 이틀마다 (예)
   # 0 3 * * *  →  0 3 */2 * *
   sudo sed -i 's|^0 3 \* \* \* |0 3 */2 * * |' /etc/cron.d/q-asker-backup
   sudo systemctl restart cron
   ```
   되돌릴 땐 다시 `0 3 * * *`로. (보관일 자체를 줄이는 `--retention-days`도 있으나, 복구 깊이가 줄어 비권장)
2. **정상 성장**: 오래된 월간 아카이브 정리(§8-B.4) 또는 유료 전환 판단 (무료 20GB는 Standard+Archive 합산이라 Archive 전환은 이득 없음)
3. **retention 미동작**: `/var/log/q-asker-backup.log`에서 retention_cleanup 로그 확인
4. **quarantine 누적**: §7.7 정기 정리
5. **테스트 잔여물**: GameDay/디버깅 산출물 삭제

### 10.3 `⚠️ [q-asker-backup] WARN — loki-downtime`

**Loki 정지 시간 60초 초과 (SC-005 위반)**.

- 원인: 대용량 chunks + 파일 개수 증가로 `cp -al` 오래 걸림
- 대응:
  1. Loki 데이터 크기 확인: `sudo du -sh /mnt/monitoring/loki`
  2. 초기라면 재실행으로 정상 확인
  3. 지속 시 로그 카디널리티 정리 (Alloy relabel drop)

---

## 11. GameDay 체크리스트 (분기 1회)

**목적**: SC-001(RTO 4h) 실측 + SC-007(재현성) 확인.

### 11.1 준비 (실행 24시간 전)

- [ ] 담당자 지정, 알림 채널에 GameDay 실시 공지
- [ ] Grafana 대시보드 스냅샷 확보 (평시 기준값)
- [ ] 이전 GameDay Log 검토 (§12)
- [ ] Slack alert 채널을 임시 테스트 채널로 전환 검토

### 11.2 실행 (당일)

- [ ] 사전 확인
  ```bash
  sshmon
  cd ~/plg-stack
  git status                                         # working tree clean
  docker compose -f monitoring/docker-compose.yml ps # 모든 컨테이너 up
  curl -sf http://localhost:9090/-/ready             # prom healthy
  curl -sf http://localhost:3100/ready               # loki healthy
  ```
- [ ] 사용 가능 snapshot 확인
  ```bash
  sudo ./monitoring/scripts/restore.sh --target=both
  ```
- [ ] **회차 1** Prometheus 단독 복원 시각 측정
  ```bash
  START=$(date +%s)
  sudo ./monitoring/scripts/restore.sh --target=prometheus --snapshot=<선택>
  END=$(date +%s)
  echo "회차 1 Prom RTO: $((END - START))s"
  ```
- [ ] **회차 2, 3** 동일 반복 → 평균/최댓값 계산
- [ ] Loki 단독 복원 1회 측정 (보조 지표)
- [ ] `.bak.<ts>` 원본 무영향 확인, 서비스 정상 동작 확인
- [ ] NSG 점검 (§9)
- [ ] 결과를 §12에 기록

### 11.3 사후 (실행 후 24시간 이내)

- [ ] `.bak.<ts>` 정리 (§8)
- [ ] Slack alert 채널 원복 (임시 변경했다면)
- [ ] 발견된 절차 개선점을 이 RUNBOOK에 즉시 반영
- [ ] 다음 분기 GameDay 일정 캘린더 등록
- [ ] SC-004(분기 1회) + SC-007(3회 누적 재현성) 진행률 업데이트

---

## 12. GameDay Log (부록)

*T8에서 첫 실측 결과가 이 섹션에 기록됩니다. 이하 템플릿.*

### 12.1 템플릿

```markdown
### YYYY-QN 회차 GameDay (YYYY-MM-DD)

**담당**: <이름>
**환경**: OCI-3 운영 인스턴스
**소스**: git commit <sha>

| 지표 | 회차 1 | 회차 2 | 회차 3 | 평균 | 최댓값 | SC 판정 |
|------|--------|--------|--------|------|--------|---------|
| Prom RTO (초) | | | | | | ≤14400 |
| Loki RTO (초) | | | | | | ≤14400 |
| 무결성 검증 | ✅/❌ | ✅/❌ | ✅/❌ | | | 100% |
| .bak 복원 성공률 | 100% | | | | | 100% |

**이슈**:
- (없음 or 요약)

**개선사항**:
- (없음 or RUNBOOK/스크립트 개선 후보)

**결론**: PASS / FAIL
```

### 12.2 2026-Q3 회차 GameDay (2026-07-04 KST)

**환경**: OCI-3 운영 인스턴스 (`q-asker-monitoring-20260306`)
**소스**: git commit `b894b8e`
**SNAPSHOT**: `20260703-0205`
**실행 스크립트**: `monitoring/scripts/gameday.sh` (Q1=a 반복 스냅샷, Q2=a Slack 무력화, Q3=a 즉시 반복, Q4=a Prom 3회 후 Loki 1회)
**시간대**: KST 00:59:20 ~ 01:08:09 (심야, 트래픽 최저)

**Prometheus 3회 실측**

| 회차 | 시작 (UTC) | 종료 (UTC) | RTO (초) | exit |
|------|-----------|-----------|----------|------|
| 1 | 2026-07-03T15:59:20Z | 2026-07-03T16:01:49Z | **149** | 0 |
| 2 | 2026-07-03T16:01:49Z | 2026-07-03T16:04:44Z | **175** | 0 |
| 3 | 2026-07-03T16:04:44Z | 2026-07-03T16:07:16Z | **152** | 0 |

- **MIN**: 149초 (2분 29초)
- **MAX**: 175초 (2분 55초)
- **AVG**: 158초 (2분 38초)
- **SC-001 판정** (RTO ≤ 14400s = 4h): ✅ **PASS** — MAX 대비 82× 여유 (99.0%)

**Loki 보조 1회**

| 시작 (UTC) | 종료 (UTC) | RTO (초) | exit |
|-----------|-----------|----------|------|
| 2026-07-03T16:07:16Z | 2026-07-03T16:08:08Z | **52** | 0 |

**사후 확인**:
- Prometheus /-/ready = 200
- Loki /ready = 200
- 4개 신규 `.bak.<ts>` 정상 생성 (Prom 3 + Loki 1)

**이슈**: 없음. 3회 모두 정상 완료, 자동 롤백 트리거 없음.

**개선사항**:
- 실행 흐름 자체는 안정적. RUNBOOK/스크립트 즉시 반영 필요 항목 없음.
- 후속 별건 개선 후보 (T8 종료 후 별도 commit):
  - `get_bucket_usage_bytes`를 `object list` 합산 방식으로 개선 (OCI `approximate-size` null 지연 회피)
  - Object Storage lifecycle rule에 `quarantine/` 접두사 제외 명시 (Terraform 별도 저장소)
  - SPRINGBOOT_HOST 죽은 변수 정리 (`.env`)

**부산물 (24시간 관찰 후 정리)**:
- `/mnt/monitoring/prometheus.bak.{1783094385, 1783094550, 1783094720}` (각 ~2.7 GiB, 총 ~8 GiB)
- `/mnt/monitoring/loki.bak.1783094841` (~143 MiB)
- 정리 절차: §8

**결론**: ✅ **PASS**. SC-004 진행률 1/4 (분기 1회 리허설 첫 회 완료). SC-007 재현성 3회 누적 근거 첫 회.

---

### 12.3 다음 GameDay 예정

- 2026-Q4 GameDay: 2026-10 이내 실시 예정
- 담당자·일정은 팀 캘린더에 등록

---

## 13. 자주 발생하는 실수

| 실수 | 결과 | 대처 |
|------|------|------|
| `git pull` 후 `docker compose up -d`만 실행 | volume/command 변경 미반영 | `--force-recreate` 명시 |
| `restore.sh` 성공 후 `.bak.<ts>` 즉시 삭제 | 문제 발견 시 롤백 불가 | 24시간 이상 관찰 후 정리 |
| 컨테이너 내부에서 chown 실행 | root 컨테이너 UID 매핑 이슈 | 호스트에서 `sudo chown -R 65534:65534 ...` |
| `.env` 값에 `(` 포함하면서 따옴표 없음 | `load_env` 정규식 파싱 통과 필수 | 값 자체는 문제 없음. bash source 방식 회피 이유 |
| 로컬 Mac에서 `docker compose up`로 검증 | `/mnt/monitoring` 없음 | OCI-3에서만 실측 |
| 잘못된 `--snapshot` 형식 | exit 2 | 형식: `YYYYMMDD-HHMM` (예: `20260701-1447`) |
| quarantine 테스트 후 원본 미복원 | 해당 스냅샷이 정상 복원 경로에서 누락 | §7.4 원위치 복원 or §7.5 sha 재생성 |
| NSG 9090 공용 허용 | admin API 파괴 위험 노출 | §9 정기 점검 |

---

## 관련 문서

- [프로메테우스로키백업복구설명.md](프로메테우스로키백업복구설명.md) — 배경 지식 · 스크립트 구성 · 흐름도
- Spec: `specs/001-prometheus-loki-backup-recovery/spec.md` (로컬만)
- 헌법: `.specify/memory/constitution.md` (로컬만)
