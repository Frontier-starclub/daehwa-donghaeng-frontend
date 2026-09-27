# Android 알림 수정 APK 재빌드

## 수정 내용

- `res/raw/keep.xml`: 알림 플러그인이 이름으로 찾는 `ic_stat_medication`을 릴리스 리소스 축소 과정에서 보존한다.
- `proguard-rules.pro`: flutter_local_notifications 17.2.4의 Gson 직렬화에 필요한 타입 및 어노테이션 정보를 보존한다.
- `build.gradle.kts`: 릴리스 빌드에 해당 ProGuard 규칙을 연결한다.

기존 APK에서는 `ic_stat_medication` 리소스를 찾지 못했고, 알림 권한 요청 전 초기화가 실패했다. 수정 후 실제 릴리스 APK에서 알림 도착을 다시 확인해야 한다.

근거: [플러그인 17.2.4 릴리스 설정](https://pub.dev/packages/flutter_local_notifications/versions/17.2.4#release-build-configuration), [동일 버전 공식 ProGuard 예제](https://github.com/MaikuB/flutter_local_notifications/blob/flutter_local_notifications-v17.2.4/flutter_local_notifications/example/android/app/proguard-rules.pro).

## Ubuntu에서 실행

실행 중인 Backend·AI·DB는 이 작업으로 재배포하거나 재시작할 필요가 없다. Ubuntu는 기존 Flutter 빌드 도구와 APK 서명 키를 재사용하기 위한 빌드 호스트다.

1. 원래 APK를 빌드한 저장소에서 작업 내용을 확인하고 해당 브랜치를 갱신한다. 로컬 변경이 있으면 먼저 보존한다.

   ```bash
   git status --short
   git branch --show-current
   git pull --ff-only origin feature/gemini-integration
   cd client-repo/app
   ```

2. **기존 빌드에 사용한 비공개 Dart define JSON**을 재사용한다. `API_BASE_URL`은 공용 서버의 `/api/v1` 주소, `TEST_ACCESS_TOKEN`은 기존 팀 접근 키여야 한다. 설정 파일 내용과 키를 터미널 출력·Git·채팅에 남기지 않는다.

   ```bash
   # 실제 기존 설정 파일의 경로를 지정한다. 키 값을 명령에 직접 넣지 않는다.
   read -r -p 'Existing private Dart define JSON path: ' DAEHWA_DEFINES
   test -f "$DAEHWA_DEFINES" || exit 1
   flutter pub get
   flutter test test/reminders_test.dart test/settings_schedules_test.dart test/api_client_test.dart
   flutter build apk --release --dart-define-from-file="$DAEHWA_DEFINES"
   ```

3. 결과는 `build/app/outputs/flutter-apk/app-release.apk`다. 기존 APK는 debug signing 설정으로 빌드하므로 **원래 빌드 계정의 `~/.android/debug.keystore`를 유지**한다. 다른 컴퓨터·계정의 debug 키로 만든 APK는 기존 앱에 덮어 설치할 수 없다.

4. 결과 APK를 Windows의 `창업클럽/daehwa-donghaeng-e2e.apk`로 전달한다. APK 및 비공개 설정·서명 키는 Git에 올리지 않는다.

## Windows에서 덮어 설치 및 E2E

기존 APK를 보관하고 두 APK의 서명 인증서 SHA-256이 같은지 Android Build Tools의 `apksigner verify --print-certs`로 확인한다. 이후 실행한다.

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb -s emulator-5554 install -r .\daehwa-donghaeng-e2e.apk
& $adb -s emulator-5554 shell am start -n kr.frontier.daehwa_donghaeng/.MainActivity
```

서명 불일치 시 중단하고 원래 서명 키로 재빌드한다. 앱 삭제나 데이터 초기화로 해결하지 않는다.

검증 순서:

1. 기존 AndroidTest 사용자와 약 목록이 유지되는지 확인한다.
2. `설정 → 알림 권한 확인 및 다시 연결`에서 알림 권한 및 정확한 알람 권한을 허용한다.
3. 테스트 약에 현재보다 3분 이상 뒤의 복약 시간을 저장한다.
4. 홈으로 나가 앱을 백그라운드로 두고 해당 시각에 실제 알림이 도착하는지 확인한다. `force-stop`은 알림 검증 중 사용하지 않는다.
5. 알림을 눌러 앱의 복약 화면이 열리는지 확인한다.
6. 테스트 일정을 삭제하고 예약이 취소됐는지 확인한다. 실제 복용 기록은 입력하지 않는다.
7. 텍스트 연속 대화와 약 등록·목록·주의사항 조회를 재확인한다.

앱 실행 성공, 서버 저장 성공, OS 알림 도착 성공을 각각 기록한다. 테스트 전에 알림이 고쳐졌다고 단정하지 않는다.

## CI/CD와의 관계

이 절차는 Git으로 소스를 전달하고 사람이 빌드·설치하는 수동 과정이다. 커밋을 계기로 자동 검사·빌드하면 CI, 결과물을 자동 전달·배포하면 CD다. 이 수정은 CI/CD 파이프라인을 추가하지 않는다.
