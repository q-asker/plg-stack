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
- **q_asker_backup_verify_success_total / fail_total{store}** — 무결성 재검증 결과
- **q_asker_backup_storage_usage_ratio** — 저장소 사용률 (90% 알림 기준)

### 1.2 매일 아침 확인 절차 (60초)

```bash
sshmon
```

```bash
# 어제 백업 성공 여부
sudo tail -30 /var/log/q-asker-backup.log | grep -E "backup.sh 정상 종료|verify.sh 정상 종료|ERROR"

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
# 0.9 미만이어야 함

# quarantine 누적 확인
oci --profile BACKUP_MON_READER os object list \
  -bn qasker-monitoring-backup --prefix "quarantine/" --all \
  | jq -r '.data[].name' | wc -l
# 0이 정상. 발생 시 §7 quarantine 관리 참고

# .bak.<ts> 디렉토리 누적 확인
sudo ls -la /mnt/monitoring/ | grep -E "\.bak\." | wc -l
# 최근 GameDay/복원 리허설 결과만 있어야 함. §8 참고
```

---

## 2. 장애 감지 → 의사결정 트리

```
[알림 또는 이상 감지]
   │
   ├─ Slack "q_asker_backup ERROR" 알림
   │  ├─ prometheus 관련 → §3 Prometheus 복원
   │  ├─ loki 관련        → §4 Loki 복원
   │  └─ 저장소·verify    → §7 Quarantine 관리 or §10.3 임계 알림
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

### 6.3 백업 시스템 자체 재검증

```bash
# verify.sh를 수동 실행 (다음 KST 04:00을 기다리지 않고)
sudo ./monitoring/scripts/verify.sh 2>&1 | tail -10
# 성공=N, 실패=0 이어야 정상

# quarantine 없는지 재확인
oci --profile BACKUP_MON_READER os object list \
  -bn qasker-monitoring-backup --prefix "quarantine/" --all \
  | jq -r '.data[].name'
```

---

## 7. Quarantine 관리

### 7.1 quarantine 발생 감지

Slack에 `verify-prometheus` 또는 `verify-loki` ERROR 알림 도착.

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
| tar.gz와 sha256 일치 | verify.sh 오탐 | §7.4 원위치 복원 |
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

# 재검증
sudo ./monitoring/scripts/verify.sh --scope=prometheus
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

# 재검증
sudo ./monitoring/scripts/verify.sh --scope=prometheus
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
3. verify.sh 재검증 성공

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
| `OCI ... 401/403/NotAuthorized` | 자격 증명 문제 | `~/.oci/config` 프로필 재점검 |

수동 재실행:
```bash
sudo ./monitoring/scripts/backup.sh --target=both
```

### 10.2 `❌ [q-asker-backup] ERROR — verify-prometheus` / `verify-loki`

**무결성 실패 → quarantine 이동**. §7 Quarantine 관리 절차 진행.

### 10.3 `⚠️ [q-asker-backup] WARN — storage-threshold`

**저장소 사용률 90% 초과**.

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
1. **정상 성장**: FREE 논리 문서 참조하여 Archive tier 이관 (Terraform lifecycle rule 추가)
2. **retention 미동작**: `/var/log/q-asker-backup.log`에서 retention_cleanup 로그 확인
3. **quarantine 누적**: §7.7 정기 정리
4. **테스트 잔여물**: GameDay/디버깅 산출물 삭제

### 10.4 `⚠️ [q-asker-backup] WARN — loki-downtime`

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

### 12.2 첫 실측 (예정)

- 2026-QN GameDay: T8에서 진행 예정.

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
| verify.sh 손상 시나리오 테스트 후 원본 미복원 | 다음 verify에서 계속 알림 | §7.4 원위치 복원 or §7.5 sha 재생성 |
| NSG 9090 공용 허용 | admin API 파괴 위험 노출 | §9 정기 점검 |

---

## 관련 문서

- [프로메테우스로키백업복구설명.md](프로메테우스로키백업복구설명.md) — 배경 지식 · 스크립트 구성 · 흐름도
- Spec: `specs/001-prometheus-loki-backup-recovery/spec.md` (로컬만)
- 헌법: `.specify/memory/constitution.md` (로컬만)
