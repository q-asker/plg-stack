# 복구 가이드 (`restore.sh` 사용법 + 실제 재해 복구)

이 문서는 두 시나리오를 다룬다:

| 시나리오 | 대상 | 진입점 | 서비스 다운타임 |
|---|---|---|---|
| **격리 검증 · GameDay 훈련** | Docker 격리 컨테이너 | `restore.sh` (자동, 45초) | 없음 |
| **실제 재해 복구** | 실 HeatWave 인스턴스 | 수동 절차 (아래 §실제 재해 복구) | 있음 (endpoint 전환 시) |

**중요**: `restore.sh`는 **격리 검증 전용**이다. 실제 운영 데이터를 되돌리려면 아래 "§실제 재해 복구" 섹션의 수동 절차를 따른다.

문서 앞부분은 `restore.sh` 사용법(격리 검증), 문서 뒷부분(§실제 재해 복구)은 HeatWave 인스턴스 실제 복원 절차.

---

## Part 1 · 격리 검증 (`restore.sh`)

## 5분 안의 첫 명령 (spec SC-006)

```bash
sudo /opt/oci-mysql-backup/restore.sh --latest
```

가장 최근 백업을 자동 선택 → Docker mysql 컨테이너 생성 → 데이터 적재 → 헬스체크 → RTO 출력.

성공 시 exit 0, 격리 컨테이너 이름·호스트 포트·헬스체크 JSON 경로가 stdout에 표시된다.

## 사용법

```
restore.sh <OBJECT_KEY> [--env docker|schema]
restore.sh --latest [--env docker|schema]
restore.sh --list
restore.sh -h | --help
```

### 옵션

| 옵션 | 설명 |
|---|---|
| `<OBJECT_KEY>` | 명시적 백업 객체 지정 (예: `2026/07/01/qasker-mysql-20260701T134701Z.sql.gz`) |
| `--latest` | 버킷의 가장 최근 `sql.gz` 자동 선택 (`time-created` 내림차순) |
| `--list` | 사용 가능한 백업 목록 표시 후 종료 |
| `--env docker` | (기본) Docker mysql 컨테이너에 복구 |
| `--env schema` | 원본 서버 격리 스키마에 복구 (미구현, spec 대안) |
| `-h`, `--help` | 사용법 |

### 예시

```bash
# 최신 백업 복구
sudo /opt/oci-mysql-backup/restore.sh --latest

# 백업 목록 조회 후 명시적 지정
sudo /opt/oci-mysql-backup/restore.sh --list
sudo /opt/oci-mysql-backup/restore.sh 2026/06/29/qasker-mysql-20260629T060003Z.sql.gz

# 도움말
/opt/oci-mysql-backup/restore.sh -h
```

## 환경변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `BUCKET` | `qasker-mysql-backup` | Object Storage 버킷 |
| `OCI_PROFILE` | `BACKUP_READER` | ~/.oci/config 프로필 (읽기 전용) |
| `DOCKER_IMAGE` | `mysql:8.0` | 격리 컨테이너 이미지 |
| `LOCK_FILE` | `/var/lock/oci-mysql-backup.lock` | flock 공유 락 (backup과 동일) |
| `WORK_BASE_DIR` | `/tmp` | 임시 작업 디렉터리 위치 |
| `BASELINE_FILE` | `/etc/oci-mysql-backup/healthcheck.baseline.yml` | T7 헬스체크 규칙 |
| `HEALTHCHECK_SCRIPT` | `/opt/oci-mysql-backup/healthcheck.sh` | T7 스크립트 |

특별한 조정이 필요 없다면 기본값 그대로 사용.

## 사전 준비

### 1. Docker 설치 확인
```bash
docker --version
# 없으면: sudo apt install -y docker.io
```

### 2. Docker 이미지 사전 캐시 (권장)
```bash
sudo docker pull mysql:8.0
```
안 하면 첫 실행에서 pull이 발생 (RTO에서는 START_TS 보정으로 제외되나 훈련 시간이 늘어남).

### 3. BACKUP_READER 프로필 확인
```bash
oci --profile BACKUP_READER os ns get
# → {"data": "axluufujp1xz"} 반환하면 OK
```

### 4. healthcheck.baseline.yml 배포 확인
```bash
sudo cat /etc/oci-mysql-backup/healthcheck.baseline.yml | jq .schemas.expected
# → 4 반환하면 OK
```

## 종료 코드

| 코드 | 뜻 | 운영 인스턴스 영향 |
|---|---|---|
| 0 | PASS + RTO 기록 | 무 |
| 1 | 사용법·환경변수 오류 | 무 |
| 3 | sha256 불일치 | **무** (격리 진입 전 중단) |
| 4 | OCI 다운로드 실패 | 무 |
| 6 | 백업 객체 없음 (`--latest` 조회 실패) | 무 |
| 10 | 헬스체크 FAIL | 무 (격리 컨테이너 안에만) |
| 12 | Docker 실패 (pull/run/health) | 무 |
| 13 | dump 적재 실패 | 무 (격리 컨테이너 안에만) |
| 14 | healthcheck 스크립트 없음 | 무 |

**어떤 실패든 원본 MySQL 인스턴스는 무영향** (spec Edge Cases 명시).

## RTO 측정 정책 (FR-019)

- **시작 (START_TS)**: 다운로드 직전
- **종료 (END_TS)**: 헬스체크 PASS 시점
- **제외**: `docker pull` 시간 (START_TS 자동 보정)
- **제외**: 격리 환경 정리 시간 (컨테이너 삭제는 훈련 후 수동)

**SC-001 목표**: RTO ≤ 900초 (15분)

## 격리 컨테이너 관리 (FR-020)

### 컨테이너 이름 규칙
```
mysql-restore-<백업시각>-<유닉스타임스탬프>
예: mysql-restore-20260701T134701Z-1782913900
```
- 첫 번째 시각: 백업 자체의 생성 시각 (UTC)
- 두 번째 타임스탬프: 복구 훈련 시작 시각

**여러 훈련을 병행 실행해도 이름 충돌 없음**.

### 컨테이너 목록 조회
```bash
docker ps -a --filter "name=mysql-restore-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### 훈련 완료 후 수동 정리
```bash
# 특정 컨테이너
docker rm -f mysql-restore-20260701T134701Z-1782913900

# 모든 restore 컨테이너 (신중히)
docker ps -aq --filter "name=mysql-restore-" | xargs docker rm -f
```

**주의**: 다음 GameDay 훈련 시작 전에 이전 컨테이너를 정리해야 리소스 낭비 없음. spec FR-020에 따라 자동 삭제는 하지 않는다.

## 실행 흐름 (내부 5단계)

```
[1/5] downloading dump + meta + sha256   (BACKUP_READER)
[2/5] verifying sha256                    (불일치 시 exit 3)
[3/5] starting isolated container         (Docker health 대기 90s)
[4/5] loading dump.sql.gz                 (zcat | docker exec mysql)
[5/5] running healthcheck (T7)            (환경변수로 격리 접속 정보 주입)
    ↓
═══════════════ 복구 완료 ═══════════════
  RTO: <초>  (SC-001 target ≤ 900s)
```

## 예상 출력 (성공 케이스)

```
[2026-07-01T14:30:12Z] [START] object_key=2026/07/01/qasker-mysql-20260701T134701Z.sql.gz container=mysql-restore-20260701T134701Z-1782913812
[2026-07-01T14:30:12Z] [step 1/5] downloading dump + meta + sha256...
[2026-07-01T14:30:17Z] [step 1/5] downloaded
[2026-07-01T14:30:17Z] [step 2/5] verifying sha256...
[2026-07-01T14:30:17Z] [step 2/5] sha256 OK
[2026-07-01T14:30:17Z] [step 3/5] starting isolated container (mysql:8.0)...
[2026-07-01T14:30:17Z] [step 3/5] container=mysql-restore-..., waiting for healthy...
[2026-07-01T14:30:45Z] [step 3/5] container healthy, host_port=32789
[2026-07-01T14:30:45Z] [step 4/5] loading dump.sql.gz...
[2026-07-01T14:31:00Z] [step 4/5] dump loaded (15s)
[2026-07-01T14:31:00Z] [step 5/5] running healthcheck (T7)...
──── healthcheck 결과 ────
{
  "status": "PASS",
  "checks": [
    {"check": "schemas", "expected": 4, "actual": 4, "tolerance": 0, "status": "PASS"},
    {"check": "tables", "expected": 21, "actual": 21, "tolerance": 2, "status": "PASS"},
    {"check": "user", "expected": 1000, "actual": 1000, "tolerance": 100, "status": "PASS"},
    {"check": "problem_set", "expected": 4500, "actual": 4500, "tolerance": 500, "status": "PASS"},
    {"check": "quiz_history", "expected": 5000, "actual": 5000, "tolerance": 5000, "status": "PASS"}
  ]
}
──────────────────────

═══════════════ 복구 완료 ═══════════════
  object_key:   2026/07/01/qasker-mysql-20260701T134701Z.sql.gz
  container:    mysql-restore-20260701T134701Z-1782913812
  host_port:    32789
  dump_size:    39022013 bytes
  load_time:    15s
  RTO:          48s  (SC-001 target ≤ 900s = 15분)
  healthcheck:  PASS
  hc_result:    /tmp/healthcheck-mysql-restore-20260701T134701Z-1782913812.json

▶ 격리 컨테이너는 유지됨 (FR-020). 분석 후 수동 정리:
    docker rm -f mysql-restore-20260701T134701Z-1782913812
```

## 격리 환경 접근 (복구 후)

성공 후 컨테이너 안 MySQL에 접속해서 데이터 검사:

```bash
# 컨테이너 이름은 restore.sh 출력에서 확인
CONTAINER=mysql-restore-20260701T134701Z-1782913812

# root pwd는 restore.sh가 랜덤 생성했지만 exec로 접속 가능
docker exec -it $CONTAINER mysql -uroot qaskerdb -e 'SHOW TABLES;'

# 또는 호스트 포트 통해 접속
HOST_PORT=$(docker port $CONTAINER 3306 | awk -F: '{print $NF}' | head -1)
mysql -h 127.0.0.1 -P $HOST_PORT -uroot qaskerdb -e 'SELECT COUNT(*) FROM user;'
# password 필요 시 restore.sh 로그에서 확인 or 컨테이너 재검사
```

**Tip**: restore.sh 로그·헬스체크 JSON을 GameDay 기록에 첨부 시 함께 남길 것.

## 트러블슈팅

### exit 3 (sha256 불일치)
- **원인**: 다운로드 중 데이터 변조·저장소 손상
- **조치**: 다른 백업 객체(더 이전 시각)로 재시도. 반복되면 버킷 무결성 조사 필요.
- **운영 영향**: 없음 (격리 진입 전)

### exit 12 (컨테이너 unhealthy)
- **원인**: Docker 이미지 손상, 리소스 부족, 포트 충돌
- **조치**:
  ```bash
  docker logs mysql-restore-...   # 원인 파악
  docker ps -a                     # 이전 컨테이너 잔재 확인
  docker rm -f mysql-restore-...   # 문제 컨테이너 정리
  ```
- 재실행 전 `docker system df`로 여유 공간 확인

### exit 10 (헬스체크 FAIL)
- **원인**: 실제 복구 데이터가 기대값과 tolerance 초과 차이
- **조치**:
  ```bash
  cat /tmp/healthcheck-<컨테이너>.json | jq
  # 어느 check가 FAIL인지 확인
  # baseline.yml의 tolerance 조정 필요할지 판단
  ```
- 컨테이너 유지되므로 수동 SQL 조사 가능

### exit 4 (다운로드 실패)
- **원인**: BACKUP_READER 프로필 문제, 네트워크, 객체 키 오탈자
- **조치**:
  ```bash
  oci --profile BACKUP_READER os ns get   # 프로필 동작 확인
  oci --profile BACKUP_READER os object list -bn qasker-mysql-backup --limit 5
  ```

### exit 0인데 flock으로 skip 됨
- **원인**: backup.sh나 다른 restore.sh가 실행 중
- **조치**:
  ```bash
  systemctl status oci-mysql-backup.service
  # 실행 중이면 완료 대기 (수 분) 후 재시도
  ```

---

## Part 2 · 실제 재해 복구 (HeatWave 인스턴스 복원)

**격리 검증(`restore.sh`)과 별개로**, 운영 서비스에 실제 데이터를 되돌리는 절차. 자동화 스크립트가 없고 **사람이 수동으로 수행**한다. 이유:

- 새 인스턴스 프로비저닝 파라미터(shape·subnet·admin pwd) 판단 필요
- 애플리케이션 endpoint 전환 · 롤백 여유 확보 판단 필요
- 다운타임·데이터 정확도 트레이드오프 판단 필요

### 사고 판정 트리

```
사고 감지 → 사고 발생 후 몇 시간 경과?
             ├─ ≤ 24h → 경로 A · L1 매니지드 백업 (권장, 콘솔 클릭)
             └─ > 24h → 경로 B · L2 외부 사본 (수동 다단계)
```

Always Free 매니지드 백업의 retention이 1일이라 24시간이 경계.

### 경로 A · L1 매니지드 백업에서 복원

**전제**: 사고 후 24시간 이내에 대응 시작.

#### 콘솔 방식 (가장 빠름, 3~5분)
1. OCI Console → **MySQL** → **DB Systems** → 원본 인스턴스 선택
2. **Backups** 탭 → 자동 백업(`SYSTEM_BACKUP-YYYYMMDDT...`) 중 원하는 시점 선택
3. **Restore** 클릭
4. 새 DB System 이름 지정 (예: `qasker-restored-YYYYMMDD`)
5. 3~5분 대기 → 새 인스턴스 상태 `ACTIVE`
6. 새 endpoint 확인 → 아래 §Part 3 endpoint 전환 진행

#### CLI 방식
```bash
# 매니지드 백업 목록에서 복원 대상 선택
oci mysql backup list \
  --db-system-id <원본_DB_SYSTEM_OCID> \
  --creation-type AUTOMATIC \
  --sort-by TIME_CREATED --sort-order DESC \
  --output table

# 새 인스턴스 생성 (복원)
oci mysql db-system create \
  --source-details '{"sourceType":"BACKUP","backupId":"<선택한_BACKUP_OCID>"}' \
  --display-name "qasker-restored-$(date +%Y%m%d)" \
  --shape-name MySQL.Free \
  --compartment-id <COMPARTMENT_OCID> \
  --subnet-id <SUBNET_OCID> \
  --wait-for-state ACTIVE

# 새 endpoint 조회
oci mysql db-system get --db-system-id <NEW_OCID> \
  --query 'data.endpoints[0].hostname' --raw-output
```

**특징**:
- 관리형 스키마·설정 완전 보존
- 원본 UUID/GTID 히스토리 그대로 복사 (신원 이식)
- 원본 인스턴스 그대로 유지 → 롤백 여유

### 경로 B · L2 외부 사본에서 실제 복원

**전제**: 사고 후 24시간 초과 or L1 매니지드 영역 자체 손상.

#### Step 0 · 격리 검증 (필수)

**실제 복원 전 반드시 격리 컨테이너에서 무결성 확인**. 이 문서 Part 1의 `restore.sh` 사용.

```bash
sshmon
sudo /opt/oci-mysql-backup/restore.sh --latest
# healthcheck: PASS 확인 후 진행
```

FAIL 나오면 이전 백업으로 재시도:
```bash
sudo /opt/oci-mysql-backup/restore.sh --list
sudo /opt/oci-mysql-backup/restore.sh <이전_객체_키>
```

#### Step 1 · 대상 HeatWave 인스턴스 준비

**옵션 1** — 신규 인스턴스 생성 (권장, 원본 유지):
```bash
oci mysql db-system create \
  --display-name "qasker-l2-restored-$(date +%Y%m%d)" \
  --shape-name MySQL.Free \
  --admin-username admin \
  --admin-password '<NEW_STRONG_PWD>' \
  --data-storage-size-in-gbs 50 \
  --compartment-id <COMPARTMENT_OCID> \
  --subnet-id <SUBNET_OCID> \
  --wait-for-state ACTIVE

# endpoint 조회
NEW_ENDPOINT=$(oci mysql db-system get \
  --db-system-id <NEW_OCID> \
  --query 'data.endpoints[0].hostname' --raw-output)
```

**옵션 2** — 기존 인스턴스에 wipe + 재로드 (비상, 위험, 롤백 불가):
```sql
-- admin으로 접속 후
DROP DATABASE IF EXISTS qaskerdb;
CREATE DATABASE qaskerdb;
```

#### Step 2 · mon 서버에서 dump 다운로드 · 검증

```bash
sshmon

# 복원 대상 객체 선택 (기본: 최신)
BACKUP=$(sudo /opt/oci-mysql-backup/restore.sh --list | grep sql.gz | tail -1)
echo "선택된 백업: $BACKUP"

# 3종 다운로드
oci --profile BACKUP_READER os object get \
  -bn qasker-mysql-backup --name "$BACKUP" \
  --file /tmp/prod-restore.sql.gz

oci --profile BACKUP_READER os object get \
  -bn qasker-mysql-backup --name "${BACKUP%.sql.gz}.sha256" \
  --file /tmp/prod-restore.sha256

oci --profile BACKUP_READER os object get \
  -bn qasker-mysql-backup --name "${BACKUP%.sql.gz}.meta.json" \
  --file /tmp/prod-restore-meta.json

# sha256 검증 (필수)
ACTUAL=$(sha256sum /tmp/prod-restore.sql.gz | awk '{print $1}')
EXPECTED=$(cat /tmp/prod-restore.sha256)
[[ "$ACTUAL" == "$EXPECTED" ]] \
  && echo "✅ SHA OK" \
  || { echo "❌ SHA MISMATCH — 다른 백업으로 재시도"; exit 1; }
```

**주의**: `backup_readonly` 사용자는 write 권한 없음. 아래 로드 명령은 **admin 계정 필요**.

#### Step 3 · 새 endpoint에 로드

```bash
ADMIN_PWD='<NEW_ADMIN_PWD>'

MYSQL_PWD="$ADMIN_PWD" zcat /tmp/prod-restore.sql.gz | \
  mysql -h "$NEW_ENDPOINT" -u admin --protocol=tcp qaskerdb
```

39 MB급 dump 기준 약 15~20초 소요.

#### Step 4 · 새 endpoint 헬스체크 (권장)

`healthcheck.sh`를 새 HeatWave endpoint에 대해 직접 실행:

```bash
BASELINE_FILE=/etc/oci-mysql-backup/healthcheck.baseline.yml \
META_FILE=/tmp/prod-restore-meta.json \
RESTORED_HOST="$NEW_ENDPOINT" \
RESTORED_PORT=3306 \
RESTORED_USER=admin \
RESTORED_PASSWORD="$ADMIN_PWD" \
RESTORED_DATABASE=qaskerdb \
/opt/oci-mysql-backup/healthcheck.sh
```

**판정**:
- exit 0 (PASS) → Part 3 endpoint 전환으로 진행
- exit 10 (FAIL) → 다른 백업 시점으로 재시도

---

## Part 3 · 애플리케이션 endpoint 전환 (L1 · L2 공통)

새 HeatWave 인스턴스가 준비되면 애플리케이션을 그쪽으로 전환.

### 절차

1. **`application-secrets.yml` datasource URL 갱신**
   - Jasypt `ENC()` 재암호화 필요 (`./gradlew ...`)
2. **Blue-Green 배포로 트래픽 점진 전환** (`infra/blue-green/`)
3. **정상 확인**
   - 애플리케이션 `/actuator/health` 200 응답
   - Grafana 대시보드: DB 응답시간·에러율 정상
   - 몇 시간~1일 안정성 관찰
4. **원본 인스턴스 종료 · 삭제** (안정 확인 후)

### 롤백 조건

성능 이상, 데이터 불일치, 애플리케이션 오류 감지 시:
- 원본 endpoint로 즉시 복귀 (Blue-Green 활용)
- 원본 인스턴스는 안정 확인 전까지 삭제 금지

---

## 시나리오 비교 요약

| 항목 | 격리 검증 (Part 1) | L1 실제 복원 (Part 2·A) | L2 실제 복원 (Part 2·B) |
|---|---|---|---|
| 진입점 | `restore.sh` | OCI Console / CLI | 수동 다단계 |
| 자동화 | 완전 자동 | 반자동 (콘솔·명령) | 수동 |
| 소요 시간 | ~45초 (SC-001) | 3~5분 | 30분~1시간 |
| 원본 서비스 | 무영향 | 무영향 (병행 유지) | 무영향 (병행 유지) or 파괴 (wipe 옵션) |
| 실행 빈도 | 분기 훈련 + 수시 | 사고 시 (희망 0회) | 사고 시 (희망 0회) |
| 시점 커버리지 | 최근 14일 (L2 lifecycle) | 최근 24h (Always Free) | 최근 14일 |
| 대상 환경 | Docker 컨테이너 | 새 HeatWave 인스턴스 | 새 HeatWave 인스턴스 |
| endpoint 전환 | 불필요 | 필요 (Part 3) | 필요 (Part 3) |

---

## 관련 문서

- `spec.md` — 요구사항 (FR-007, FR-013, FR-017~FR-020, SC-001)
- `FLOW.md` — backup.sh 흐름도 (참고: restore.sh도 유사 구조)
- `RESTORE.md` (본 문서) — restore.sh 사용법
- `RUNBOOK` (T9 예정) — 운영자·GameDay 완전한 절차

## 명령 요약

| 상황 | 명령 |
|---|---|
| 최신 백업 복구 (권장) | `sudo /opt/oci-mysql-backup/restore.sh --latest` |
| 특정 백업 복구 | `sudo /opt/oci-mysql-backup/restore.sh <OBJECT_KEY>` |
| 백업 목록 | `sudo /opt/oci-mysql-backup/restore.sh --list` |
| 컨테이너 목록 | `docker ps -a --filter name=mysql-restore-` |
| 컨테이너 정리 | `docker rm -f <컨테이너명>` |
| 헬스체크 재실행 | (직접 healthcheck.sh 환경변수 주입) |
| 이미지 사전 캐시 | `sudo docker pull mysql:8.0` |
