# Flutter 앱

## 2026-09-07 프론트엔드 구현 현황

기존 홈·디자인 토큰을 유지하고 약 등록/OCR 테스트 흐름을 추가했습니다.
`USE_MOCK=true`이면 백엔드 없이 실행됩니다. 사진을 선택해도 인식 결과는
고정 예시이며 서버에 저장되지 않습니다. 실제 OCR 연동은 백엔드 명세 확인 대기입니다.

구현한 흐름:

`홈 → 약 등록 → 카메라/앨범 → 사진 확인 → 인식 중 → 결과 확인·수정·삭제·추가 → 확인 완료`

- OCR-01~05/E1: `lib/features/ocr/screens/registration_flow_screen.dart`의 단계별 화면.
- OCR-06/07: `medication_edit_screen.dart`를 수정/직접 입력에서 재사용.
- 화면 전환·취소·수정 데이터: `ocr_flow_controller.dart`.
- 이미지 선택/Android 재시작 시 선택 결과 복구: `prescription_image_picker.dart`.
- HTTP 구현/예시 구현: `http_ocr_repository.dart` / `mock_ocr_repository.dart`.
- 결과 확정은 이번 테스트의 종료 지점입니다. 약 저장·DUR 조회를 수행하지 않습니다.
- 입력 범위는 약 이름과 선택적 1일 횟수(1~10)로 구현했습니다. 문서의 Blocker A 제안 기준이며 팀 확정 시 조정합니다.

### 서버 없이 실행

```sh
flutter pub get
flutter run -d chrome --dart-define=USE_MOCK=true
# Android 기기 연결 후
flutter run --dart-define=USE_MOCK=true
# 실패 화면 확인: success / empty / error / timeout
flutter run -d chrome --dart-define=USE_MOCK=true --dart-define=MOCK_OCR_SCENARIO=error
```

이 작업 폴더에는 Flutter 3.47.2 SDK를 `../../output/tooling/flutter`에 준비했습니다.
PATH에 Flutter가 없다면 PowerShell에서 `./scripts/run-mock.ps1`로 브라우저 실행을 시작합니다.
브라우저의 사진 촬영 동작은 브라우저·기기에 따라 파일 선택으로 표시될 수 있습니다.
Android에서는 휴대폰 기본 카메라를 사용합니다. 앱 내부 실시간 가이드 프레임은 이번 구현에 포함되지 않습니다.

### 실제 서버 연결

기존 기본 모드는 실제 백엔드 연결을 유지했습니다. 신규 테스트 사용자는 이름을 명시해 등록합니다.

```sh
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8090/api/v1 --dart-define=BOOTSTRAP_DISPLAY_NAME=테스트
```

이름을 지정하지 않으면 기존 기기 ID로 조회합니다. 온보딩 이름 입력 화면은 후속 작업입니다.
실제 OCR은 `UnconfiguredOcrRepository`가 준비 중 안내를 반환합니다.
백엔드 담당자에게 다음을 받은 뒤 `main.dart`의 해당 객체를 `HttpOcrRepository`로 교체합니다.

1. 앱→백엔드 OCR 경로, multipart 필드명, 인증 요구사항.
2. 성공·실패 응답 JSON과 스캔 ID/약 목록이 위치한 필드.
3. 테스트 서버 주소 및 실제 OCR 사용 가능 여부.

`HttpOcrRepository`는 `ApiClient`, 상대 경로, 응답 decoder를 주입받습니다.
공통 업로드 필드명은 현재 `image`입니다. 응답 경로를 임의로 가정하지 않았으며,
`docs/contract/ai-service.md`의 백엔드→AI API를 앱에서 직접 호출하지 않습니다.

### 검증

2026-09-07 결과: Flutter 3.47.2/Dart 3.13.2에서 분석 오류 0건, 테스트 14개 통과,
mock 웹 빌드 성공. [상세 검증 기록](../docs/decisions/2026-09-07-frontend-ocr.md)을 참고하세요.
Android SDK가 없어 APK 빌드·실기기 검증은 수행하지 못했습니다.

```sh
flutter analyze
flutter test test
flutter build web --dart-define=USE_MOCK=true
```

테스트는 사진 선택 취소, 늦은 OCR 응답 무시, dispose 이후 완료, 빈 결과·오류·시간 초과,
직접 입력 검증, 수정·삭제, 실제 화면 왕복, 작은 화면과 큰 글씨를 다룹니다.
백엔드 통합 테스트는 기존 `integration_test/round_trip_test.dart`이며 서버가 필요합니다.
Android SDK/실기기가 없는 환경에서는 카메라 권한·실기기 복귀·APK 동작을 검증할 수 없습니다.

Android와 웹 플랫폼 폴더 및 `pubspec.lock`을 버전 관리하도록 변경했습니다.
CI에서는 `flutter create`를 다시 실행하지 않습니다(기본 카운터 테스트 재생성 방지).
Android 평문 개발 서버 허용은 debug manifest에만 있습니다.
기본 카메라 intent를 사용하는 image_picker 방식이므로 CAMERA 권한을 임의로 추가하지 않았습니다.
알림·마이크 기능은 아직 미구현이며 해당 권한 설정도 후속 구현에서 추가합니다.

현재 폴더에서 플랫폼 생성은 다시 실행할 필요가 없습니다.


## 화면 구현 원칙

- design/tokens.dart의 글자 크기, 버튼 높이, 색상, 간격을 사용합니다.
- 화면은 Repository를 통해 데이터를 받고 직접 HTTP 요청을 만들지 않습니다.
- DUR 화면을 추가할 때 백엔드 disclaimer를 표시합니다.
- 음성 기능은 이후 앱에서 STT/TTS로 처리하고 서버에는 텍스트를 전송합니다.
- 사진은 임시 데이터로만 처리하며 원본 약봉투와 API 키를 커밋하지 않습니다.
