# Flutter 프론트엔드

2026-09-17 기준, 기존 디자인을 유지하면서 사용자 등록·약 촬영/OCR·약 저장·복약 시간·DUR 결과·음성 대화를 구현했습니다.
앱은 백엔드를 호출하고, 실제 OCR·식약처·LLM 구현은 AI 담당이 제공합니다.
[완료 범위와 API 인수인계](../docs/contract/frontend-handoff.md)를 함께 전달하세요.

## 서버 없이 화면 확인

```powershell
cd client-repo/app
./scripts/run-mock.ps1
# 또는 Flutter가 PATH에 있으면
flutter run -d chrome --dart-define=USE_MOCK=true
```

이 모드는 OCR·DUR·대화가 예시 응답이며 등록한 약과 복약 기록도 메모리에만 보관합니다.
앱 재실행 시 초기화됩니다. 카메라/앨범과 STT/TTS는 기기의 실제 기능을 사용하며, 권한·엔진이 없으면 직접 입력할 수 있습니다.
OCR 실패 화면은 `./scripts/run-mock.ps1 -Scenario error`로 확인합니다.
`success / empty / error / timeout`을 지원합니다.

## 실제 백엔드 연결

팀 저장소 https://github.com/Frontier-starclub/daehwa-donghaeng 의 실행 방법을 따릅니다.
백엔드가 켜진 뒤 앱 디렉터리에서:

```powershell
# Chrome: 백엔드 CORS에 맞춰 localhost:3000에서 실행
./scripts/run-backend.ps1

# Android 에뮬레이터: flutter devices에서 기기 ID 확인
./scripts/run-backend.ps1 -Device emulator-5554

# 휴대폰: 같은 네트워크에서 개발 PC의 주소 사용
./scripts/run-backend.ps1 -Device <기기-ID> -ApiBaseUrl http://<개발-PC-IP>:8090/api/v1
```

스크립트는 설치된 Flutter 또는 이 작업 폴더의 `output/tooling/flutter` SDK를 사용합니다.
휴대폰에서 `localhost`는 PC를 뜻하지 않습니다. 서버가 PC의 네트워크 인터페이스에서도 접근 가능해야 합니다.

처음 실행하면 이름/별명을 입력하고 서버에 등록합니다. 같은 기기 ID를 계속 사용하고, 성공한 이름은 서버 주소별로 저장합니다.
기존 테스트용 `BOOTSTRAP_DISPLAY_NAME`도 지원합니다.
`USE_MOCK` 기본값은 `false`입니다. 앱이 실제 백엔드를 호출하더라도 백엔드의 AI 모드가 mock이면 OCR/DUR/대화 내용은 예시입니다.
실제 서비스 실패 시 앱이 예시 응답으로 자동 전환하지 않습니다.

## 구현한 흐름

- 홈 → 약 등록 → 카메라/앨범 → 사진 확인 → OCR → 결과 수정/삭제/추가 → 약 저장.
- 직접 입력도 가능하며, 스캔 ID 없이 같은 약 저장 API를 사용합니다.
- 약 이름을 수정하면 이전 약의 품목 코드·성분 정보·인식 신뢰도를 제거합니다.
- 저장 결과가 불명확하면 자동 재등록하지 않고 내 약 목록 확인을 안내합니다.
- 저장된 약 → 복약 시간 직접 설정 → 홈의 오늘의 약 갱신 → 드셨어요/아직이에요 기록.
- DUR은 약 저장 후 자동 확인하며 홈에서도 진입할 수 있습니다. 조회된 경고 없음과 확인 실패를 구분합니다.
- 대화 참여/거절 → 마이크 또는 글 입력 → 인식 문장 확인 → 전송 → 답변 표시/TTS → 대화 종료.
- 대화 재시도는 동일한 메시지 ID/본문을 유지하고, 화면 재진입 시 서버의 진행 중인 대화를 복구합니다.
- 화면 이탈/백그라운드 전환 시 음성 중지, 늦게 도착한 응답 무시, 마이크 거부·TTS 실패 시 텍스트 대화 유지.

약의 1일 횟수만으로 복약 시간을 정하지 않습니다. 서버의 일정 API 한도는 약당 1~8개 시간입니다.
시간을 설정하기 전에는 약 목록에 저장되어 있어도 오늘의 약에 나타나지 않을 수 있습니다.
시간 설정 API는 기존 일정을 전체 교체하므로 화면에서도 이를 안내합니다.

## 코드 구조

```text
lib/core/                   API·기기 ID·오류 처리
lib/design/                 기존 색상·글자·버튼 규격
lib/features/onboarding/    최초 이름 입력·사용자 등록
lib/features/ocr/           사진·인식 결과·수정·등록 흐름
lib/features/medication/    약 저장·목록·시간 설정·복약 기록
lib/features/dur/           주의사항 결과·실패·재시도
lib/features/chat/          대화 API·상태·STT/TTS·화면
lib/features/home/          오늘의 약과 각 기능 진입
```

화면은 Repository로 데이터를 받습니다. 외부 AI API 키는 Flutter에 넣지 않습니다.
Android 마이크 권한과 음성 서비스 조회 설정을 추가했으며 휴대폰 마이크를 사용합니다. Bluetooth 전용 연결은 이번 범위에서 비활성화했습니다.
배경 복약 알림·보호자 기능·분석 리포트·Play 배포는 포함하지 않습니다.

## 자동 검증

```powershell
flutter analyze --no-pub
flutter test --no-pub
flutter build web --no-pub --dart-define=USE_MOCK=true --no-web-resources-cdn --no-wasm-dry-run
```

2026-09-16~17 검증: 분석 문제 0건, HTTP 통합을 포함한 테스트 37개 통과, 웹 빌드 성공.
기본 테스트에서는 실제 백엔드 테스트 1개를 건너뜁니다. 실제 호출 테스트는 아래와 같이 별도 테스트 서버를 실행해야 합니다.

백엔드 의존성이 설치된 Python 3.13+ 환경에서, 앱 디렉터리의 첫 번째 터미널:

```powershell
python scripts/serve_test_backend.py --backend-dir <백엔드-저장소>/apps/backend --port 18090
```

두 번째 터미널:

```powershell
flutter test --no-pub --dart-define=RUN_BACKEND_INTEGRATION=true
```

런처는 팀 백엔드 코드를 변경하지 않고 앱 `build/backend-fixtures` 아래 새 임시 SQLite DB를 만들며 종료 시 정리합니다.
AI는 백엔드 내부 mock이고 외부 API 키는 필요 없습니다. 기존 사용자 DB를 사용하지 않습니다.
이 검증은 PostgreSQL의 동시성·마이그레이션이나 실제 AI 품질 검증을 대신하지 않습니다.

Android SDK와 실기기가 이 환경에 없어 APK 빌드·실제 촬영/STT/TTS 검증은 남아 있습니다.
휴대폰에서 마이크 허용/거부, 한국어 인식, 답변 읽기/중지, 앱 백그라운드 전환, 카메라 복귀를 확인해야 합니다.
웹 빌드에는 CupertinoIcons 미포함 경고가 있으나 빌드는 성공했고 앱의 아이콘은 Material 아이콘입니다.
