# 모니터링 스택 이미지 승격 변경점 (2026-07)

> 티켓: **ICC-390**
> 대상 브랜치: `chore/dep-upgrade-2026-07` · 통합 커밋 기준
> 프로세스: `/dependency-upgrade-cycle` 스킬 (Renovate PR 통합)

## 반영된 버전 승격

| 컴포넌트 | 현재 → 대상 | semver | Renovate PR | 결정 |
|---|---|---|---|---|
| grafana/loki | 3.6.0 → 3.7.3 | MINOR | #7 | MERGE_NOW |
| prom/prometheus | v3.10.0 → v3.13.0 | MINOR | #9 | MERGE_NOW |
| grafana/grafana | 12.4.0 → 13.1.0 | **MAJOR** | #10 | 채택 (#6 12.4.5 superseded) |

## 컴포넌트별 개선점·영향

### 📊 Prometheus v3.10.0 → v3.13.0 — 가장 실속 있는 승격

| 구분 | 내용 | 우리 영향 |
|---|---|---|
| 🔒 보안 | XSS CVE 2건 수정 (CVE-2026-44990 sanitize-html, CVE-2026-40179 metric name 저장형 XSS) | 직접 이득 — 9090 노출 노드 |
| 🏷️ LTS | v3.13은 Long-Term Support 릴리즈 | 정례 승격 부담↓ |
| ⚡ 성능 | chunk population 오버헤드 감소 → 쿼리 ~12–15% 가속 | 1 OCPU/6GB 저사양 노드 체감 이득 |
| 🆕 기능 | `/api/v1/status/self_metrics`, PromQL `start()/end()/range()/step()`, 시계열 삭제 웹 UI | 선택적 활용 |

recording rule 20개 promtool v3.13 파싱 검증 완료 — PromQL 문법 회귀 없음.

### 🪵 Loki 3.6.0 → 3.7.3 — 정합성 확인용 승격

| 구분 | 내용 | 우리 영향 |
|---|---|---|
| ⚠️ Promtail deprecated | Promtail → Alloy 통합 | 이미 Alloy 사용 중 — 아키텍처 방향 재확인 |
| ⚠️ BoltDB 백엔드 폐기 예고 | boltdb-shipper deprecated | 무관 — 이미 `tsdb` + schema v13 사용 |
| 🆕 개선 | distributor/compactor/ingester 내부 개선, `loki` health 명령 내장, 스케줄러 워커 스레드 공유 | 운영 안정성 소폭↑ |
| 🩹 config | `-verify-config` GREEN | config 회귀 없음 |

MINOR지만 실질은 패치 수준. breaking 없음.

### 📈 Grafana 12.4.0 → 13.1.0 — 유일한 MAJOR

| 구분 | 내용 | 우리 영향 |
|---|---|---|
| ✨ Dynamic dashboards GA | 차세대 대시보드 편집 정식화 | 기존 18개 그대로 로드(검증) |
| 🎨 쿼리 에디터 재설계 | 쿼리·transform·alert 통합 뷰 | 편집 UX 개선 |
| 🗂️ 주석 클러스터링·패널 스타일 복붙 | 밀집 annotation 묶기 | before/after 대시보드 유용 |
| 🔧 enable_gzip 기본 on | HTTP 압축 기본 활성 | 명시 설정 없음 → 자동 적용, 대시보드 로딩 대역폭↓ |
| 💥 /api→/apis, 숫자 datasource id API 비활성, Scenes 비활성 불가, RBAC 강화, React 19 | breaking change | 전부 무관 — uid 참조·파일 프로비저닝·admin 인증 구성 |

## Grafana v13 MAJOR breaking change 영향 분석 (실증)

| breaking change | 영향 여부 | 근거 |
|---|---|---|
| 숫자 datasource id API 비활성화 | ❌ 무영향 | 대시보드 18개 전부 `uid`로 datasource 참조, datasources.yml에 uid 고정 |
| /api → /apis deprecation | ❌ 무영향 | 파일 프로비저닝 사용, Grafana API 호출 경로 없음 |
| RBAC 커스텀 롤 강화 | ❌ 무영향 | admin 단일 계정, 커스텀 RBAC 롤 없음 |
| Scenes 비활성 불가 | ❌ 무영향 | Scenes 비활성화 설정 안 함 |
| React 19 (IoT TwinMaker 등) | ❌ 무영향 | 해당 플러그인 미사용 |

## 회귀 안전망 (로컬 스모크 테스트)

`monitoring/local/docker-compose.yml`(gitignored)로 승격 이미지 실기동 후 검증:

| 검증 | 결과 |
|---|---|
| Prometheus v3.13.0 `/-/ready` | GREEN |
| Prometheus rules.yml (promtool) | 20개 규칙 유효 |
| Grafana v13.1.0 `/api/health` | GREEN (version 13.1.0) |
| Grafana 대시보드 프로비저닝 | 18개 전부 로드 |
| Grafana datasource 프로비저닝 | Loki/Prometheus 2개 uid 정상 |
| Loki 3.7.3 `-verify-config` | "config is valid" |

Grafana 로그의 elasticsearch/zipkin 번들 플러그인 설치 경고는 미사용 플러그인 관련 무해 항목 (우리 datasource/대시보드 프로비저닝과 무관).

## 문서 동기화

- `CLAUDE.md` 기술 스택 표: Loki 3.7.3 / Prometheus v3.13.0 / Grafana 13.1.0 갱신

## 한 줄 결론

- 가장 큰 실익: Prometheus v3.13 (보안 CVE 2건 + LTS + 쿼리 12–15% 가속)
- 가장 리스크 컸던 것: Grafana v13 MAJOR — 실측 결과 무해
- Loki: 아키텍처 방향(Alloy·tsdb) 재확인, 무손실

## 참고

- [Loki v3.7 release notes](https://grafana.com/docs/loki/latest/release-notes/v3-7/)
- [Prometheus 3.13.0](https://github.com/prometheus/prometheus/releases/tag/v3.13.0) · [3.12.0](https://github.com/prometheus/prometheus/releases/tag/v3.12.0) · [3.11.0](https://github.com/prometheus/prometheus/releases/tag/v3.11.0)
- [What's new in Grafana v13.0](https://grafana.com/docs/grafana/latest/whatsnew/whats-new-in-v13-0/) · [v13.1](https://grafana.com/docs/grafana/latest/whatsnew/whats-new-in-v13-1/)
