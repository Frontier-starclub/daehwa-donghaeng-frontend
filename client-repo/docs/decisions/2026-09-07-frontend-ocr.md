# 프론트엔드 약 등록·OCR 테스트 흐름

- 날짜: 2026-09-07
- 범위: 기존 디자인을 유지한 Flutter 프론트엔드 구현. 실제 OCR/API 명세는 대기.
- Git commit: 작업 폴더가 Git 저장소가 아닌 전달용 폴더이므로 없음.

## 요구사항과 변경

기존 홈의 약 등록 버튼은 빈 콜백이었고 촬영·사진 확인·OCR 결과 화면이 없었다.
기존 HTML의 OCR-01~07/E1을 기준으로 단계별 화면을 추가했다.
촬영은 image_picker의 기본 카메라/앨범이며 앱 내부 실시간 가이드 프레임은 구현하지 않았다.

화면은 공통 Repository 규격을 통해 실제 API와 mock 구현을 주입받는다.
USE_MOCK=true는 프론트엔드 시연용이며 사진과 무관한 예시 응답을 제공한다.
기존 기본 실행은 백엔드 연결 모드를 유지한다. 신규 사용자 등록은
BOOTSTRAP_DISPLAY_NAME을 지정했을 때 최초 조회 전에 실행한다.
실제 OCR은 API 경로와 decoder를 주입받는 어댑터를 준비했으며 main에는 아직 연결하지 않았다.
미확인 백엔드 API를 추정하거나 AI 서비스 API를 직접 호출하지 않았다.

OCR 결과는 임시 MedicationDraft로 관리하며 수정·삭제·추가가 가능하다.
약 이름은 1~100자, 선택적 1일 횟수는 1~10회이며 최대 30건이다.
결과 확인 완료는 약 저장/DUR 조회 완료를 의미하지 않도록 화면에 명시한다.
인식 요청 세대 번호로 취소·화면 이탈·dispose 이후 도착하는 응답을 무시한다.
ApiClient 시간 초과를 ApiException으로 변환하고 이미지 업로드도 주입한 http.Client를 사용한다.

## 검증 결과

환경: Windows, Flutter 3.47.2, Dart 3.13.2. SDK는 작업 폴더 output/tooling/flutter에 준비.

| 검증 | 기대 | 실측 결과 |
| --- | --- | --- |
| flutter analyze --no-pub | 분석 오류·경고 없음 | No issues found, 6.2초 |
| flutter test --no-pub --reporter expanded | 모든 테스트 통과 | 14 passed, 테스트 출력 약 2초 |
| 320×640, 글씨 배율 2 | 스크롤로 직접 입력·결과 확인 가능 | 통과 |
| 이미지 선택→결과→수정·삭제 | 수정 결과가 화면에 반영 | widget test 통과 |
| 취소/종료 후 늦은 OCR 응답 | 화면·기존 임시 결과 불변 | 통과 |
| 빈 인식 결과·provider 오류·시간 초과 | 실패 안내 및 직접 입력 가능 | 통과 |
| multipart 요청 | 주입된 클라이언트·image 필드·기기 ID 사용 | 통과 |
| Flutter web JS release build, USE_MOCK=true | 웹 산출물 생성 | build/web 생성, 20.3초 |
| 로컬 정적 서버 | index와 앱 자산 제공 | HTTP 200, main.dart.js 2,575,405 bytes |

웹 빌드는 --no-web-resources-cdn --no-wasm-dry-run 옵션으로 수행했다.
빌드 시 CupertinoIcons 폰트 관련 비차단 경고가 있었다. 이번 화면은 Material 아이콘을 사용한다.
브라우저 자동 제어 도구에 연결된 브라우저가 없어 브라우저 직접 조작 검증은 수행하지 않았다.
UI 동작 검증은 실제 Flutter widget test로 수행했다.

## 남은 작업

1. 백엔드 OCR 경로·multipart 규격·응답·인증 계약을 받아 HttpOcrRepository 연결.
2. 실제 샘플 사진으로 인식 결과 검증. 현재 테스트 통과는 OCR 인식 정확도 증거가 아니다.
3. Android SDK와 실기기를 준비해 APK 빌드, 카메라 권한, 앱 재시작 복구 확인.
4. 약 저장·DUR 조회·알림·온보딩 등 후속 범위 확정 및 구현.

Android/Web 플랫폼 설정과 pubspec.lock을 버전 관리 대상으로 바꾸고 CI에서 플랫폼 재생성을 제거했다.
큰 글씨 테스트의 초기 실패는 화면 밖 항목을 생성·스크롤·레이아웃 갱신하기 전에 조회한 테스트 코드에서
발생했다. 실제 사용자 스크롤과 화면 갱신을 반영한 최종 테스트가 통과했다.
