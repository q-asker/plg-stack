---
description: '새 기능/대규모 작업의 PRD 명세와 Shrimp Task 계획을 수립하는 계획 커맨드 (코드 구현 없음)'
references:
  - references/task-planning-guide.md
  - references/prd-generation-guide.md
---

사용자가 설명한 새 기능/대규모 작업에 대해 다음 순서로 진행한다:

## STEP 0 — 선행 조건 체크

`.claude/rules/workflow.md`의 **세션 시작 가드**를 실행한다. 하나라도 실패하면 **즉시 중단**한다.

선행 조건을 모두 통과하면 아래 단계를 진행한다.

---

1. `git branch --show-current`로 현재 브랜치명을 확인하고, `docs/{브랜치명}/`을 작업 디렉토리로 사용한다
    - 예: 브랜치가 `ICC-276-libreoffice`이면 → `docs/ICC-276-libreoffice/PRD.md`
2. `docs/{브랜치명}/PRD.md` 존재 여부를 확인한다
    - 있으면: 읽고 현재 제품 명세를 파악한다
    - 없으면: `references/prd-generation-guide.md`를 참조하여 PRD를 새로 생성한다
3. `references/prd-generation-guide.md`를 참조하여 PRD에 새 기능 명세를 추가한다 (2단계에서 새로 생성한 경우 건너뛴다)
4. Shrimp Task Manager `init_project_rules`를 실행하여 프로젝트 규칙을 초기화한다
5. Shrimp Task Manager `plan_task`로 작업을 계획한다
    - PRD의 기능 명세를 기반으로 태스크를 설계한다
    - `references/task-planning-guide.md`의 분석 방법론과 작성 규칙을 참조한다
    - `analyze_task` → `reflect_task` → `split_tasks`로 세부 태스크를 등록한다
6. WebGUI 링크를 확인하고 안내한다
    - Shrimp Task Manager DATA_DIR 경로에서 `WebGUI.md` 파일을 찾아 읽는다
    - `WebGUI.md`가 존재하면 파일 내용에서 URL을 추출하여 안내한다
    - `WebGUI.md`가 없으면 WebGUI가 비활성 상태임을 알린다:
      > ⚠️ Shrimp WebGUI가 비활성 상태입니다. MCP 서버 설정에서 `ENABLE_GUI=true` 환경변수를 추가하세요.
7. 결과 요약을 출력한다 (코드 구현은 하지 않는다)
    - WebGUI가 활성 상태면 결과 요약에 WebGUI 링크를 포함한다
8. Shrimp Task Manager의 `execute_task`로 태스크를 실행할 수 있음을 안내하고, WebGUI가 활성 상태면 태스크 현황을 확인할 수 있음을 함께 안내한다

## 금지 사항

이 커맨드 실행 중 다음 작업을 수행하지 않는다:

- 코드 파일 생성/수정
- 패키지 설치 (`npm install` 등)
- 빌드/서버 실행
- Task 자동 구현

## 입력

$ARGUMENTS
