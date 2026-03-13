# LibreOffice와 Spring Boot 통합 아키텍처

## 개요

Q-Asker API는 **JODConverter**를 통해 LibreOffice를 Spring Boot 애플리케이션에 통합합니다. 사용자가 업로드한 PPT/DOCX 파일을 PDF로 자동 변환하는 핵심 인프라입니다.

```
사용자 업로드
    ↓
[Spring Boot 애플리케이션]
    ↓
[JODConverter]
    ↓
[LibreOffice 프로세스 풀]
    ↓
PDF 변환 완료
```

---

## 기술 스택

| 컴포넌트        | 버전      | 역할                            |
|--------------|---------|-------------------------------|
| JODConverter | 4.4.9   | 문서 변환 엔진 (LibreOffice 드라이버) |
| LibreOffice | 최신     | 문서 처리 및 PDF 변환              |
| Spring Boot  | 3.5.8   | 웹 애플리케이션 프레임워크            |

---

## 아키텍처 구조

### 레이어 분리

```
┌─────────────────────────────────────┐
│     Spring Boot 애플리케이션         │
│  (ConvertService 인터페이스)         │
└──────────────┬──────────────────────┘
               │
┌──────────────┴──────────────────────┐
│      JODConverter (Spring Starter)   │
│  - 프로세스 풀 관리                   │
│  - 변환 작업 큐                      │
│  - 타임아웃 처리                     │
└──────────────┬──────────────────────┘
               │
┌──────────────┴──────────────────────┐
│      LibreOffice 프로세스 풀         │
│  - PPTX/DOCX 파싱                   │
│  - PDF 렌더링 및 생성                │
│  - 임시 파일 관리                    │
└─────────────────────────────────────┘
```

---

## 통합 방식

### 1. JODConverter Spring Boot Starter

**역할**: LibreOffice를 로컬 프로세스로 실행하고, Spring Boot가 DocumentConverter 빈을 통해 제어

```java
// ConvertServiceImpl.java
@Service
@ConditionalOnProperty(prefix = "jodconverter.local", name = "enabled", havingValue = "true")
public class ConvertServiceImpl implements ConvertService {

  private final DocumentConverter documentConverter;  // JODConverter 제공 빈

  @Override
  public Path convertToPdf(Path inputFile) {
    documentConverter.convert(inputFile.toFile()).to(pdfFile).execute();
  }
}
```

### 2. 문서 변환 흐름

```
1. 사용자 파일 업로드 (PPTX/DOCX)
   ↓
2. AWS S3에 저장
   ↓
3. ConvertServiceImpl.convertToPdf() 호출
   ↓
4. JODConverter가 LibreOffice 프로세스 풀에서 가용 프로세스 할당
   ↓
5. LibreOffice 프로세스: 문서 파싱 → 레이아웃 계산 → PDF 렌더링
   ↓
6. 변환된 PDF를 임시 디렉토리에 저장
   ↓
7. PDF 파일을 AI 인입(Gemini)으로 전달
   ↓
8. 퀴즈 생성 완료
```

---

## 환경 설정

### application-local.yml

```yaml
jodconverter:
  local:
    enabled: true                          # JODConverter 활성화
    office-home: /Applications/LibreOffice.app/Contents  # LibreOffice 설치 경로
    port-numbers: 2002                     # LibreOffice 리스닝 포트
    max-tasks-per-process: 200             # 프로세스당 최대 변환 작업 수
    task-execution-timeout: 60000          # 변환 작업 타임아웃 (60초)
    task-queue-timeout: 120000             # 큐 대기 타임아웃 (120초)
```

### 환경별 설정

| 환경  | 활성화 | 특징                           |
|------|------|------------------------------|
| local | true | 로컬 개발: macOS/Linux LibreOffice 사용 |
| test | false | ConvertService를 NoOpConvertService로 대체 |
| prod | true | Docker 컨테이너 내 LibreOffice |

---

## Docker 컨테이너 구조

### 프로덕션 배포

Q-Asker API Docker 이미지 내에 LibreOffice가 포함:

```dockerfile
FROM openjdk:21
RUN apt-get install -y libreoffice
COPY app.jar /app.jar
ENTRYPOINT ["java", "-jar", "/app.jar"]
```

**참고**: [ICC-278] 커밋에서 LibreOffice 커스텀 베이스 이미지 전환 구현

### docker-compose.yml (로컬 개발)

```yaml
version: '3.8'
services:
  api:
    build: .
    environment:
      - SPRING_PROFILES_ACTIVE=local
    depends_on:
      - mysql
```

---

## 변환 지원 포맷

### 입력 포맷 (ConvertServiceImpl.java)

```java
private static final Set<String> SUPPORTED_EXTENSIONS =
  Set.of(".pptx", ".ppt", ".docx", ".doc");
```

### 변환 로직

```
PPTX/PPT (PowerPoint) ──┐
                         ├─→ LibreOffice ──→ PDF
DOCX/DOC (Word)    ─────┘
```

**PDF 파일**: 변환 스킵 (이미 최종 포맷)

---

## 성능 및 제약

### JODConverter 튜닝 파라미터

| 파라미터                   | 값    | 용도                         |
|--------------------------|-------|---------------------------|
| `max-tasks-per-process`  | 200   | 프로세스 재시작 트리거 (메모리 누수 방지) |
| `task-execution-timeout` | 60초  | 개별 변환 작업 타임아웃         |
| `task-queue-timeout`     | 120초 | 큐에서 대기하는 최대 시간       |

### 병목 분석

| 요소 | 영향 | 해결 방안 |
|-----|------|---------|
| LibreOffice 프로세스 수 | 동시 변환 능력 | 프로세스 풀 크기 증가 (메모리 vs 성능 트레이드오프) |
| task-execution-timeout | 느린 문서 실패율 | 타임아웃 증가 (응답 시간 증가) |
| S3 다운로드/업로드 | 네트워크 지연 | 로컬 스토리지 캐싱 |

---

## 오류 처리

### ConvertServiceImpl 예외 처리

```java
try {
  documentConverter.convert(inputFile.toFile()).to(pdfFile).execute();
} catch (CustomException e) {
  throw e;  // 이미 처리된 예외는 그대로 전파
} catch (Exception e) {
  log.error("PDF 변환 중 오류 발생: {}", inputFile, e);
  throw new CustomException(ExceptionMessage.CONVERT_FAILED);
}
```

### 발생 가능한 예외

| 예외                       | 원인                    | 처리            |
|--------------------------|----------------------|---------------|
| ConvertException         | LibreOffice 변환 실패   | CONVERT_FAILED |
| TimeoutException         | 타임아웃 초과          | CONVERT_FAILED |
| UnsupportedFileTypeException | 지원하지 않는 확장자 | UNSUPPORTED_FILE_TYPE |

---

## Test 환경

### NoOpConvertService

```java
@Service
@ConditionalOnProperty(
  prefix = "jodconverter.local",
  name = "enabled",
  havingValue = "false"
)
public class NoOpConvertService implements ConvertService {

  @Override
  public Path convertToPdf(Path inputFile) {
    // 실제 변환 없이 입력 파일을 그대로 반환
    return inputFile;
  }
}
```

**용도**: 단위 테스트에서 LibreOffice 설치 불필요 (빠른 피드백)

---

## 모니터링 및 로깅

### 로그 레벨

```
INFO  - 변환 시작/완료
ERROR - 변환 실패 (스택 트레이스 포함)
DEBUG - JODConverter 내부 동작 (필요 시 활성화)
```

### 모니터링 지표 (Prometheus)

```
jodconverter.task.execution.time  # 변환 작업 소요 시간
jodconverter.task.queue.size       # 대기 중인 작업 수
jodconverter.process.count         # 활성 LibreOffice 프로세스 수
```

---

## 보안 고려사항

### 파일 입력 검증

1. **확장자 검증**: SUPPORTED_EXTENSIONS에 명시된 포맷만 허용
2. **바이러스 검사**: (선택) AWS S3 바이러스 검사 활성화
3. **임시 파일 정리**: 변환 완료 후 임시 파일 삭제

### LibreOffice 프로세스 격리

- 각 LibreOffice 프로세스는 독립적으로 실행 (하나의 변환 실패가 다른 작업에 영향 없음)
- 프로세스 타임아웃으로 좀비 프로세스 방지

---

## 참고 문서

- [JODConverter 공식 문서](https://jodconverter.github.io/jodconverter/)
- [LibreOffice 다운로드](https://www.libreoffice.org/download/)
- CLAUDE.md — 기술 스택, 명령어
- application-{local,test,prod}.yml — 환경별 설정

---

## 히스토리

| 버전 | 날짜      | 변경 사항                           |
|------|----------|------------------------------|
| 1.0  | 2024-01-01 | JODConverter 4.4.9 기초 통합 |
| 1.1  | 2024-XX-XX | [ICC-278] LibreOffice 베이스 이미지 전환 |
