---
description: '프로젝트 초기화 및 .claude/ 동기화. CLAUDE.md 없으면 생성, 있으면 보완 후 .claude/ 전체 동기화'
references:
  - references/sync-claude-spec.md
---

# /init — 프로젝트 초기화 + .claude/ 동기화

## 역할

새 프로젝트에 Claude Code 환경을 한 번에 세팅한다.
`.claude/`를 다른 프로젝트에서 통째로 복사한 상황에서도 정상 작동한다.

**Phase 1:** CLAUDE.md 생성/보완, 포맷팅 설정, Git Hook 설정
**Phase 2:** .claude/ 디렉토리 전체 동기화 (`references/sync-claude-spec.md` 참조)

---

## 자동 모드 분기

- **CLAUDE.md 없음** → Phase 1 전체 실행 (컨텍스트 수집 → CLAUDE.md 생성 → 포맷팅 → Git Hook) → Phase 2
- **CLAUDE.md 있음** → Phase 1 보완만 (스택 정합성 체크, 누락 섹션 보완) → Phase 2

---

## Phase 1 — CLAUDE.md 갱신

### STEP 1 — 컨텍스트 수집

프로젝트의 빌드 파일, 설정 파일, 디렉토리 구조를 직접 읽고 분석한다.

#### 1-1. rules 일치성 검증

`.claude/rules/` 디렉토리 존재 여부를 직접 확인한다. 존재하면 rules 파일들의 내용을 읽고 CLAUDE.md의 기술 스택 키워드와 대조하여 **ok** / *
*mismatch**를 판정한다. 없으면 **missing**으로 판정한다.

#### 1-2. 디렉토리 구조 탐색

프로젝트 규모에 맞게 depth를 조절하여 디렉토리 트리를 파악한다.

---

### STEP 2 — CLAUDE.md 작성

`CLAUDE.md` 파일 존재 여부를 직접 확인한다. 존재하면 누락 섹션만 보완(기존 내용 보존), 없으면 전체 신규 생성한다.

#### 필수 섹션

1. **프로젝트 개요** — 목적과 핵심 기능 1~2줄
2. **기술 스택** — 언어, 프레임워크, 주요 라이브러리
3. **명령어 (Scripts)** — 빌드 도구의 태스크/스크립트 기반
4. **아키텍처** — 디렉토리 구조 필수
5. **개발 도구 및 설정** — 패키지 매니저, 런타임 버전, 포맷터/린터

---

### STEP 3 — 포맷팅 설정

#### formatter가 감지된 경우

`.claude/settings.json`의 `hooks.PostToolUse`에 포맷팅 훅을 추가한다.
CLAUDE.md의 개발 도구 섹션에서 파악한 포맷 명령을 command로 사용한다. 기존 hooks가 있으면 병합한다.

#### formatter가 null인 경우

사용자에게 포맷터 도입을 제안한다. 사용자가 선택하면 해당 포맷터를 프로젝트에 설치하고(빌드 파일 수정), 훅을 설정한다. 거부하면 건너뛴다.

- `.claude/settings.json`의 `hooks.PostToolUse`에 `Edit|Write` 매처로 CLAUDE.md에서 파악한 포맷 명령을 등록한다
- Checkstyle처럼 검증만 하는 도구는 훅 대신 CLAUDE.md 명령어 섹션에 기록한다
- 훅 추가 전 사용자에게 확인을 받는다

---

### STEP 4 — Git Hook 설정

CLAUDE.md의 개발 도구 섹션에서 파악한 포맷터와 포맷 명령을 참조하여 `.githooks/` 디렉토리에 훅 파일을 **직접 작성**한다.

- 기존 훅 파일이 있어도 **사양이 다르면 덮어쓴다** (건너뛰지 않음)
- 훅 설치 전 사용자에게 확인을 받는다
- 훅 파일에 실행 권한(`chmod +x`)을 부여한다
- `git config core.hooksPath .githooks`를 설정한다

#### 1. `prepare-commit-msg`

브랜치에서 JIRA 티켓(`[A-Z]+-[0-9]+`)을 감지하여 커밋 메시지에 접두사 자동 추가.

#### 2. `pre-commit`

- `formatter`가 null이면 설치하지 않는다
- `formatCommand`(apply 명령)를 분석하여 **check 명령을 판단**한다
    - 예: `npx prettier --write` → `npx prettier --check`
    - 예: `./gradlew spotlessApply` → `./gradlew spotlessCheck`
- 포맷 위반 시 커밋을 차단하고, apply 명령을 안내한다

#### 3. `pre-push`

- `formatter`가 null이면 설치하지 않는다
- `pre-commit`과 동일한 **check 명령**을 실행한다
- rebase, merge, cherry-pick 등으로 `pre-commit`을 우회한 커밋이 push되는 것을 방지하는 **안전망** 역할
- 포맷 위반 시 push를 차단하고, apply 명령을 안내한다

---

## Phase 2 — .claude/ 동기화

`references/sync-claude-spec.md`의 STEP 1~3을 순서대로 실행한다.

1. **컨텍스트 수집** — CLAUDE.md 기반 일치성 판정
2. **동기화 실행** — rules, commands, agents, hooks, scripts, settings.json
3. **교차 일관성 검증** — 전체 파일 간 상호 참조 검증

---

## 완료 리포트 출력

아래 포맷으로 리포트를 출력한다.

### 상태 결정 규칙

- **`/plan-feature`**: `docs/PRD.md` 없음 → `⚠️ PRD 없음 — 반드시 실행` / PRD만 있음 → `⚠️ ROADMAP 없음` / 둘 다
  존재 → `✅ 건너뛰기 가능`

### 출력 포맷

```
---

## 프로젝트 초기화 완료

### Phase 1 — CLAUDE.md 갱신

- [{생성 | 보완}] CLAUDE.md
- [{생성 | 확인 | 보완}] .claude/settings.json
- [{설치 | 거부 | 미감지}] JIRA 커밋 접두사 Git Hook
- [{설치 | 거부 | 미감지}] 포맷팅 pre-commit 훅 ({formatter} — {checkCommand})
- [{설치 | 거부 | 미감지}] 포맷팅 pre-push 훅 ({formatter} — {checkCommand})

#### 채워진 섹션
- ✅ 프로젝트 개요
- ✅ 기술 스택: {파악된 스택 요약}
- ✅ 명령어
- ✅ 아키텍처
- ✅ 개발 도구 및 설정
- ...

### Phase 2 — .claude/ 동기화

| 대상 | 판정 | 처리 |
|---|---|---|
| `rules/` | {ok/mismatch/missing} | {보완 N개 / 재작성 N개 / 신규 생성 N개} |
| `commands/` | {ok/mismatch} | {수정 N개 / 이상 없음} |
| `agents/` | {ok/mismatch} | {수정 N개 / 이상 없음} |
| `hooks/` | {ok/issue} | {수정 N개 / 이상 없음} |
| `scripts/` | {ok/issue} | {수정 N개 / 이상 없음} |
| `settings.json` | {ok/mismatch} | {수정 / 이상 없음} |

#### 교차 검증 결과
- ✅ 전체 일관성 확인 완료
{또는}
- ⚠️ {불일치 항목}: {수정 내용}

### TODO (사용자 확인 필요)
- ⚠️ {항목}: {파악 불가 이유}
(없으면 이 섹션 생략)

### 초기화 진행 상황

| 단계 | 커맨드 | 상태 |
|---|---|---|
| 1 | `/init` | ✅ 완료 |
| 2 | `/plan-feature` | {상태} |

---

> 다음: {다음 미완료 커맨드 또는 "초기화 완료! 이제 개발을 시작하세요."}
```
