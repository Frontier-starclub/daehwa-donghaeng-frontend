# 프론트엔드 인수인계 — 2026-09-17

기존 Flutter 디자인을 유지하면서 약 등록·복약 시간·DUR·음성 대화와 백엔드 호출을 구현했다.
실제 OCR/식약처/LLM 구현과 DB 변경은 포함하지 않았다.

## 기준과 실행

- 기준 백엔드: https://github.com/Frontier-starclub/daehwa-donghaeng
- 확인 커밋: `4c8def13995a1a5eb93e4080c6326abe048e982a`.
- 계약 근거: 백엔드 `docs/server-integration.md`, `docs/chat-session.md`, `app/api/`, `app/schemas.py`.
- 앱 소스는 현재 `client-repo/app`에 유지한다. GitHub 업로드·브랜치 생성은 이번에 하지 않았다.
- 실행 방법: [앱 README](../../app/README.md). 신규 실제 사용자는 앱에서 이름 입력 후 bootstrap한다.
- 앱 `USE_MOCK=true`는 메모리 예시 데이터이고 재실행하면 초기화된다.
- 앱 `USE_MOCK=false`는 실제 Backend API를 사용한다. Backend가 `PROVIDER_MODE=mock`이어도 약·복약·대화 기록은 Backend DB에 저장된다. OCR/DUR/대화 내용만 예시다.

## 앱 → 백엔드 API 연결표

상대 경로의 기본 주소는 `http://10.0.2.2:8090/api/v1`이다. 실기기는 개발 PC의 LAN 주소로 설정한다.
bootstrap과 이후 요청은 같은 기기 ID를 사용한다. 모든 요청에 `X-Device-ID`를 보낸다.

| 기능 | 호출 | 입력 / 처리 |
| --- | --- | --- |
| 사용자 등록 | `POST /users/bootstrap` | `{device_id, display_name}`; 이름은 성공 후에만 해당 서버 주소별로 로컬 저장 |
| 사진 OCR | `POST /medication-scans` | multipart `image`, JPEG/PNG ≤10MiB; `id`, `provider`, `items` 보존 |
| 약 등록 | `POST /medications/batch` | `{scan_id, items}`; 직접 입력은 `scan_id:null` |
| 약 목록 | `GET /medications` | 활성 약 목록 표시·복약 시간 설정 진입 |
| 복약 시간 | `PUT /medications/{id}/schedules` | `{schedules:[{time_slot,remind_at}]}`; 직접 선택한 1~8개 시간 |
| 오늘의 약 | `GET /medication-events/today` | 서버가 생성한 일정 이벤트 사용 |
| 복약 응답 | `PUT /medication-events/{id}/response` | `{status:"taken"}` 또는 `not_taken` |
| DUR 확인 | `POST /dur-checks` | `{}`; 현재 서버가 사용자의 모든 활성 약을 포함 |
| DUR 재조회 | `GET /dur-checks/{id}` | Repository에 구현, 통합 테스트에서 저장 결과 확인 |
| 대화 복구 | `GET /chat/sessions/current` | 활성 세션과 메시지 복구; 없으면 참여 화면 |
| 참여/거절 | `POST /chat/sessions` | `{decision:"accepted"}` 또는 `declined` |
| 대화 전송 | `POST /chat/sessions/{id}/messages` | `{client_message_id,content}` |
| 대화 종료 | `POST /chat/sessions/{id}/end` | 세션 종료; 서버의 멱등성 사용 |

실제 앱은 `scenario`를 전송하지 않는다. 오류 시 예시 결과로 자동 전환하지 않는다.
서버의 422 `OCR_EMPTY`, 502 `OCR_PROVIDER_ERROR`/`DUR_PROVIDER_ERROR`/`CHAT_PROVIDER_ERROR` 및 통신·응답 해석 오류를 처리한다.

## 상태와 오류 처리

- OCR의 `ingredient_name`, `ingredient_code`, `item_seq`, `confidence`, `dose_frequency_per_day`를 보존한다. 약 이름을 변경하면 이전 이름의 성분·코드·신뢰도는 제거한다. 1일 횟수는 용량을 뜻하지 않는다.
- 사진 인식 취소·화면 종료 후 늦은 결과는 적용하지 않는다. OCR 결과를 사용자 확인 없이 저장하지 않는다.
- 약 저장 POST는 자동 재전송하지 않는다. 저장 중 버튼/뒤로가기를 막고, 응답 유실·네트워크 오류·잘못된 성공 응답·5xx처럼 저장 여부가 불명확하면 내 약 목록 확인을 안내한다.
- 저장 성공 후 약을 재등록하는 경로로 돌아가지 않는다. 시간 설정과 DUR 실패는 각각 해당 요청만 다시 시도한다.
- 복약 횟수로 시간이나 용량을 추측하지 않는다. 복약 시간 설정 전에는 약 목록에만 있고 오늘의 약에 아직 나타나지 않을 수 있다. 시간 설정은 기존 일정 전체를 교체하는 API임을 화면에 안내한다.
- DUR 결과는 `warnings`, `no_warnings`, 그 외 확인 불가/실패로 표시한다. `no_warnings`를 안전하다는 의미로 표현하지 않는다. 성공 결과에는 서버 `disclaimer`를 그대로 표시한다. 오류 응답에는 `disclaimer`가 없으므로 받은 오류 메시지와 확인 실패 상태를 표시한다.
- 대화 재시도는 같은 `client_message_id`와 본문을 보존한다. 실패한 전송이 남아 있으면 내용을 수정한 새 메시지를 보내지 않는다. 서버 복구 결과에 해당 ID가 있으면 보류 상태를 해제한다.
- STT 결과는 화면에서 확인한 뒤 전송한다. 음성 파일을 Backend/AI로 보내지 않는다. OS/브라우저의 음성 인식 엔진은 자체 네트워크를 사용할 수 있어 오프라인 동작을 보장하지 않는다.
- TTS 동안 새 녹음을 시작하지 않는다. 중지·화면 이탈·앱 백그라운드 전환 시 녹음과 재생을 중지하고 늦은 응답을 무시한다. 한국어 STT/마이크가 불가능하면 글로 입력하며, TTS 실패 시 답변 텍스트를 유지한다.
- Android는 마이크 권한·음성 서비스 조회 설정을 추가했다. 이번 범위는 휴대폰 마이크이며 Bluetooth 전용 연결은 비활성화했다.

## 검증

- Flutter 3.47.2 / Dart 3.13.2.
- `flutter analyze --no-pub`: 문제 0건.
- `flutter test --no-pub --dart-define=RUN_BACKEND_INTEGRATION=true`: **37개 통과**.
- 실제 HTTP 통합: Flutter의 실제 Repository → 팀 Backend FastAPI → 임시 SQLite. Backend 내부 AI mock 사용. 마지막 측정 전체 흐름 **582ms**, 단일 로컬 실행이며 실제 AI 응답 속도 측정이 아니다.
- 통합 확인: bootstrap, OCR 스캔 ID, 약 2개 및 직접 입력 약 저장·재조회, 복약 일정·복약 기록 재조회, DUR 저장·재조회·경고/실패, 대화 참여·메시지·중복 재전송·복구·종료·거절.
- UI 테스트: 320×640에서 글자 2배 확대, 직접 입력, 약 저장 이후 이동, 시간 설정 실패 후 재시도, DUR 오류/경고, 마이크 거부 후 텍스트 대화.
- 웹 빌드 성공(42.2초). Flutter의 CupertinoIcons 미포함 경고가 있으나 빌드는 성공했고 앱은 Material 아이콘을 사용한다.
- Chrome 390×844 화면에서 홈·직접 입력·약 등록 완료·DUR 결과·시간 설정 진입을 확인했다. 기본 뒤로가기·남은 글자 수 같은 접근성 문구도 한국어로 표시하도록 지역화를 추가했다.
- Chrome에서 예시 대화 참여·텍스트 전송·답변 표시와 읽기 상태 전환도 확인했다. 콘솔 오류 0건. 음성의 실제 청취 품질이나 휴대폰 STT 검증을 의미하지 않는다.
- `USE_MOCK=false` 웹 빌드도 별도 성공(47.8초). `http://localhost:3000`의 실제 앱에서 `http://localhost:18090`의 테스트 Backend로 사용자 등록 → 홈 조회를 확인했고 콘솔 오류는 없었다.
- PostgreSQL·Docker·Android APK·실기기 카메라/STT/TTS는 이번 환경에서 검증하지 못했다. `flutter doctor -v`에서 Android SDK가 없고 Android 기기가 발견되지 않았다.

## AI·백엔드 담당에게 남기는 항목

1. 실제 OCR, 약품 매칭, 식약처 DUR, LLM 구현. 키와 프롬프트는 서버에서 관리한다.
2. AI가 이전 대화를 이해하도록 Backend → AI `history` 계약 합의. 앱의 대화 복구/표시는 구현됐지만 현재 AI 호출에는 이전 대화가 없다.
3. DUR 약품별 매칭 실패·부분 조회 상태 표현. 현 `warnings` 계약만으로는 빈 결과와 부분 미확인을 구분할 수 없다. 앱이 이를 추정해서 안전 결과로 바꾸지 않는다.
4. 활성 약 30개 초과 시 DUR 처리 방식. 앱은 임의 분할 검사나 새 백엔드 제한을 추가하지 않았다.
5. 약 저장 batch의 멱등성 또는 스캔 확정 결과 조회 계약. 현재 프론트는 불명확한 저장의 자동 재전송을 막는다.
6. 기존 복약 시간 조회 API와 일정 변경 시 기존 복약 기록 보존 확인. 현 계약에는 조회가 없어 시간 설정 화면은 기존 시간을 미리 채우지 않고 전체 교체임을 안내한다.
7. 웹 테스트는 현재 Backend CORS가 허용하는 `http://localhost:3000`에서 실행한다. 다른 웹 주소 배포는 Backend에서 해당 origin 허용이 필요하다.

Android 환경을 준비한 담당자는 실제 촬영/앨범 복귀, 마이크 허용·거부, 한국어 STT, 답변 TTS·중지, 전화/백그라운드 전환, 실기기에서 개발 PC 서버 접속을 확인한다.
