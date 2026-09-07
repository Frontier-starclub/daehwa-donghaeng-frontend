# 결정: FE·AI 파트 저장소 분리 및 백엔드 연동 경계

- **날짜**: 2026-09-06
- **작성**: 이석윤
- **관련자**: 배해원(PM), 김민섭(BE), 정진수(AI)
- **근거 문서**: `0807 회의록`, `03_대화동행_Flowchart_v2.1`, `04_대화동행_화면설계서_v2.1`
- **상태**: 제안 — BE·PM 확인 대기

---

## 1. 결정

저장소를 **2개**로 운영한다. 이석윤·정진수는 **한 저장소**를 함께 쓴다.

| 저장소 | 소유 | 범위 |
| --- | --- | --- |
| `frontier-starclub/daehwa-donghaeng` | 김민섭 | 백엔드 API, PostgreSQL, migration |
| `frontier-starclub/daehwa-donghaeng-client` | 이석윤 | Flutter 앱, AI 서비스 |

### 이석윤·정진수를 한 저장소에 두는 이유

저장소를 나누는 단위는 사람이 아니라 배포 단위다. 두 사람은 역할이 고정되어 있지 않고
번갈아 작업하기로 했으므로, 사람 기준으로 쪼개면 저장소 2개를 오가는 PR 왕복이
2인 팀의 개발 시간을 그대로 잠식한다. Flutter(Dart)와 AI(Python)는 한 저장소 안에서도
디렉터리와 CI path filter로 완전히 분리된다.

### 백엔드 저장소와 분리하는 이유

1. **경계가 이미 코드에 있다.** `apps/backend/app/providers.py`의 `OCRProvider`,
   `DURProvider`, `ChatProvider` Protocol이 정확히 FE·AI 파트의 경계다. Mock 자리에
   실제 구현을 꽂는 것은 `docs/architecture.md`가 이미 그린 구조 그대로다.
2. **의존성 격리.** AI 실험 코드는 무거운 라이브러리를 끌고 온다. 이를 백엔드 이미지에
   넣으면 백엔드 배포가 AI 실험 상태에 묶인다.
3. **비밀키 책임 분리.** `ANTHROPIC_API_KEY`, `DATA_GO_KR_SERVICE_KEY`는 client 저장소
   담당자가 발급·보관·회전한다. 백엔드 배포 환경에 이 키들을 넣지 않는다.

### 검토했으나 채택하지 않은 안

- **AI 코드를 백엔드 저장소에 직접 기여**: 서비스가 1개로 단순해지지만 위 2·3번이 깨지고,
  BE 리뷰 대기가 AI 파트 이터레이션 속도의 상한이 된다.
- **AI와 FE를 각각 별도 저장소로**: 두 사람이 번갈아 작업하는 실제 운영 방식과 충돌한다.

---

## 2. 연동 경계

호출 방향은 단방향이다. **앱 → 백엔드 → AI 서비스.** 앱은 AI 서비스를 직접 호출하지 않으며
`docs/api/README.md`의 `X-Device-ID` 계약을 그대로 따른다.

```
[Flutter 앱] --REST/multipart--> [백엔드 :8090] --HTTP--> [AI 서비스 :8100]
                                       |                        |
                                  PostgreSQL          Claude API / 식약처 공공 API
```

백엔드에 필요한 변경은 **어댑터 3개 + 환경변수 2개**뿐이다. 상세 요청은
`docs/contract/backend-adapter-request.md` 참조.

```python
# apps/backend/app/providers.py
class HttpOCRProvider:   name = "remote"   # POST {AI_SERVICE_URL}/v1/ocr/prescription-label
class HttpDURProvider:   name = "remote"   # POST {AI_SERVICE_URL}/v1/dur/check
class HttpChatProvider:  name = "remote"   # POST {AI_SERVICE_URL}/v1/chat/reply

# PROVIDER_MODE=mock|remote   (기본 mock 유지)
# AI_SERVICE_URL=http://ai:8100
```

AI 서비스의 요청·응답 스키마는 `providers.py`의 `RecognizedMedication`,
`MedicationForCheck`, `DurProviderWarning` dataclass와 **필드를 1:1로 맞춘다.**
그래야 어댑터가 각 30줄 이하로 끝나고 Mock↔Remote 전환이 환경변수 하나가 된다.

### AI 서비스 계약

```
POST /v1/ocr/prescription-label   multipart(image)
    -> {items:[{name, ingredient_name?, ingredient_code?, item_seq?,
                dose_frequency_per_day?, confidence?}]}

POST /v1/dur/check                {medications:[{id, name, ingredient_code, item_seq}]}
    -> {warnings:[{warning_type, medication_ids, message, source_code?}]}

POST /v1/chat/reply               {opening:bool, user_message_count:int, content:str}
    -> {content:str}

POST /v1/drugs/resolve            {names:[str]}
    -> {matches:[{name, item_seq, ingredient_code, confidence}]}

GET  /health/live
```

실패 시 5xx + `{code, message}`를 반환한다. 백엔드는 이를 기존 `OCR_PROVIDER_ERROR` /
`DUR_PROVIDER_ERROR`로 매핑하며, `apps/backend/app/api/medications.py`의 기존 예외 처리를
그대로 재사용하므로 백엔드 로직 수정은 필요 없다.

---

## 3. 함께 기록하는 사실

### 3.1 Phase1 진행 상황

백엔드는 `providers.py`에 Mock을 꽂고 `scripts/smoke_test.py`로 10단계 흐름을 단독 검증하도록
설계되어 있어 앱 없이 독립 완성이 가능했고 실제로 그렇게 진행됐다. FE에서 BE로 넘겼어야 할
산출물은 없었다. 다만 두 가지를 기록해 둔다.

- 회의록 Phase1은 *복약 캘린더 + 보호자 연동*이다. 복약 캘린더(`medication_schedules`,
  `medication_events`)는 완성이나, 보호자 쪽은 `consents.caregiver_share_allowed` 플래그만
  있고 Caregiver 모델·API가 없다. 이는 회의록 결정사항 1("8월은 MVP 2단계 OCR+DUR에 집중")과
  안건1 결론("분석은 제외")에 따라 팀이 의도적으로 뒤로 민 것이지 누락이 아니다.
  → **M3(12월) 스코프로 명시 확정 요청** (PM).
- 남은 것은 앱이며 FE 몫이다. 9/7 Phase1 완료 정의를 *"Flutter 골격 + 백엔드 연동 왕복 확인
  (bootstrap → 약 등록 → 오늘의 약 → 복약 응답)"* 으로 확정한다.

### 3.2 OCR·DUR의 성격

회의록에 "AI 학습"이라는 표현은 없다. 근거:

- M1 완료기준: "약봉투 사진 → **Claude API** OCR → 약 이름 자동 추출"
- 플로우차트 OCR-04 노드: "Claude API · 이미지 인식"
- 최종 목표: "AI 기술을 **활용하여** 개발"
- DUR은 식약처 공공 API HTTP 요청 + 파싱 + 규칙 로직으로, AI가 아니다

즉 AI 파트의 산출물은 프롬프트, 응답 파싱, 후처리, API 클라이언트다. 이에 따라 AI 담당
업무를 다음 3개로 정의한다.

| 트랙 | 내용 | MVP 기여 |
| --- | --- | --- |
| (a) 약 이름 → 품목기준코드 매핑 | 화면설계서 Blocker B | **필수 블로커.** MVP에서 모델링 여지가 있는 유일한 지점 |
| (b) OCR 평가셋 + 프롬프트 튜닝 | 회의록 리스크 #2 대응 | 인식률 지표 확보 |
| (c) 대화 어휘·문장구조 변화 지표 선행연구 | FT-05 선행 | Phase3 이후 |

### 3.3 화면 구현 범위와 검증 범위

화면설계서 `MVP: MUST` 35화면은 **전부 구현**한다. 화면설계서가 Screen ID별로 목적·표시정보·
버튼·다음 화면·필요 데이터·오류 예외까지 명세하고 있어 코드 생성 자체는 병목이 아니다.

실제 병목은 검증 왕복, 미결정 사항(Blocker A/B/C), 실기기 확인, 코드 응집도다. 따라서
**9/16 통합 테스트와 소규모 파일럿 시나리오만 Core 22화면으로 한정**한다. 이는 화면설계서
Decision Log S-3("팀 미확정")에 대한 제안이며 PM 승인 대상이다.

| Flow | Core (통합·파일럿 필수) | Extended (구현하되 파일럿 시나리오 제외) |
| --- | --- | --- |
| 온보딩 | ONB-01, ONB-03, ONB-06 | ONB-02, 04, 05, 07 |
| 홈 | HOME-01 (UI A안) | — |
| OCR | OCR-01, 02, 04, 05, 07, E1 | OCR-03, OCR-06 |
| DUR | DUR-01, 02, 03, E1 | DUR-04 |
| 복약 | MED-01, 03, 04, 06, 07 | MED-02, MED-05 |
| 대화 | CHAT-01, 02, 03 | CHAT-E1 |
| 설정 | SET-01 | SET-02, SET-03 |
| 분석·리포트 | — | INSIGHT-01/02, REPORT-01/02 → M3 이월 |

Core는 버그 0 + 실기기 검증 완료가 기준, Extended는 화면 진입·이탈 동작이 기준이다.

**모든 DUR 화면에 "의사·약사 상담을 권고합니다" 문구를 유지한다** (회의록 결정사항 2).
백엔드 `DurCheckOut.disclaimer`가 해당 문자열을 내려주므로 앱에서 하드코딩하지 않고
응답값을 렌더링한다.

---

## 4. 기술·환경 결정

### 4.1 앱 프레임워크는 Flutter를 유지한다

Python 모바일 프레임워크(Kivy/BeeWare/Flet)를 검토했으나 채택하지 않는다. 이 앱의 핵심
기능 3개 — 로컬 복약 알림(정시 백그라운드), 카메라 촬영(OCR-02), 온디바이스 STT/TTS(CHAT-02) —
가 정확히 해당 프레임워크들의 취약 지점이며 네이티브 브릿지를 직접 작성해야 한다.
프레임워크 교체는 수정이 아니라 앱 전체 재작성이고, KPI "파일럿 10명"은 실제 배포 가능한
앱을 요구한다. `docs/architecture.md`와 `apps/mobile/README.md`가 이미 Flutter를 전제하며
백엔드 API가 그 가정 위에 설계되어 있다.

> **PM 확인 필요**: "정식 배포 없이 시연만"이라는 전제가 팀 차원에서 유효한지 확인이 필요하다.
> 시연만으로 확정될 경우 절약되는 것은 Play 등록 단계이지 프레임워크가 아니다.

### 4.2 OCR 모델은 Claude API로 시작하고 평가셋으로 검증한다

ChatGPT 구독(Codex 포함)은 API 접근권이 아니다. ChatGPT 구독 결제와 Platform API 결제는
분리된 과금 체계이며 구독 크레딧이 API로 이월되지 않는다. 어느 provider를 쓰든 `/v1/ocr`
구현에는 별도 API 키와 종량 결제가 필요하다.

기본값은 회의록 M1 완료기준의 "Claude API"를 따른다. 비용은 선택 근거가 되지 못한다 —
약봉투 이미지 1장이 약 1.5k 입력 토큰이므로 100장 스캔이 1달러 미만이다. 모델 교체는
평가셋 20건 측정 결과로만 판단하며 변경 시 PM 승인을 받는다.

### 4.3 개발 OS

Ubuntu 24.04를 권장한다. Docker 네이티브 실행(백엔드 `compose.yaml`이 PostgreSQL까지 띄운다),
KVM 기반 Android 에뮬레이터, AI 라이브러리 호환성에서 유리하며 iOS는 대상이 아니므로
손실이 없다. 다만 Windows에 Flutter·Android Studio가 이미 구성되어 있다면 앱은 Windows
네이티브, 백엔드·AI·Docker는 WSL2로 나누는 편이 빠르다.

저장소 `.gitattributes`가 `* text=auto eol=lf` + `*.ps1 eol=crlf`로 정규화하고 있어 줄바꿈
충돌은 없다. 백엔드 README가 PowerShell 기준이므로 client 저장소 스크립트는 크로스플랫폼
(sh + Python)으로 작성한다.

---

## 5. Blocker 처리 계획

| ID | 내용 | 담당 | 기한 | 방향 |
| --- | --- | --- | --- | --- |
| A | 직접 입력(OCR-07) 항목 범위 | 이석윤 | 9/8 | 약 이름 + 1일 복용 횟수만. `MedicationDraft`의 나머지 필드가 nullable이므로 스키마 변경 불필요 |
| B | 약 이름 → 코드 매핑 | 정진수 | 9/9 | DUR API 요청 파라미터 실측 후 결정. `medications.ingredient_code` / `item_seq` 컬럼이 이미 존재 |
| C | 기존 복용약 확보 | 이석윤 | 9/8 | 앱 등록 이력 자동 사용. `POST /dur-checks`가 이미 활성 약 전체를 스냅샷하므로 추가 개발 없음 |
| S-3 | MVP 컷라인 | 이석윤 → PM | 9/7 | 위 3.3 Core 22 / Extended 13 |

---

## 6. 확인 요청 사항

**김민섭(BE)**

1. `docs/contract/backend-adapter-request.md`의 어댑터 3개 + 환경변수 2개 추가
2. 보호자(Caregiver) 연동을 M3로 이월하는 것에 대한 확인

**배해원(PM)**

1. MVP 컷라인(S-3) — Core 22 / Extended 13 구분 승인
2. 보호자 연동 M3 이월 승인
3. 프로젝트 목표 정렬 — 정식 배포(Play 등록·파일럿 10명) 대 시연 중심 중 어느 쪽인지 확정
