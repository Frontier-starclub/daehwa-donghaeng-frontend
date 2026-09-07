# 압축 파일 사용법

> 2026-09-07 업데이트: Flutter 약 등록/OCR 프론트엔드 mock 흐름과 Android/Web 플랫폼 파일을 추가했습니다.
> 현재 실행 방법과 검증 결과는 [앱 README](client-repo/app/README.md)를 보세요.
> 아래 내용은 2026-09-06 최초 전달본 기록입니다.

2026-09-06 세션 산출물입니다. 두 덩어리로 나뉘어 있습니다.

```
client-repo/         → 새로 만들 저장소의 루트 내용
backend-repo-docs/   → 김민섭님 저장소에 추가할 문서 2개
```

---

## 1. `backend-repo-docs/` → 기존 백엔드 저장소

`frontier-starclub/daehwa-donghaeng`의 `claude/dev-structure-planning-51p1d2` 브랜치에
올리면 됩니다.

```sh
cd ~/work/daehwa-donghaeng
git checkout claude/dev-structure-planning-51p1d2
cp -r /path/to/backend-repo-docs/docs/. docs/
git add docs/decisions docs/contract
git commit -m "docs: FE·AI 파트 저장소 분리 결정과 백엔드 어댑터 요청"
git push -u origin claude/dev-structure-planning-51p1d2
```

포함 파일:

| 파일 | 용도 | 수신 |
| --- | --- | --- |
| `docs/decisions/2026-09-06-repo-split.md` | 저장소 분리 결정·근거 | 팀 전체 |
| `docs/contract/backend-adapter-request.md` | 어댑터 3개 + 환경변수 2개 요청 | 김민섭 |

---

## 2. `client-repo/` → 새 저장소

`frontier-starclub/daehwa-donghaeng-client` (private)로 만드는 것을 제안드렸습니다.

```sh
mkdir -p ~/work/daehwa-donghaeng-client
cp -r /path/to/client-repo/. ~/work/daehwa-donghaeng-client/
cd ~/work/daehwa-donghaeng-client

git init
git add .
git commit -m "chore: Flutter 앱 + AI 서비스 스캐폴딩"
git remote add origin git@github.com:frontier-starclub/daehwa-donghaeng-client.git
git push -u origin main
```

> 백엔드 저장소와 **형제 디렉터리**로 두세요. `compose.integration.yaml`이
> `../daehwa-donghaeng/apps/backend`를 참조합니다.
>
> ```
> ~/work/daehwa-donghaeng/          (백엔드)
> ~/work/daehwa-donghaeng-client/   (여기)
> ```

숨김 파일(`.github/`, `.gitignore`, `.gitattributes`, `.env.example`)이 포함되어 있으니
복사할 때 `cp -r source/. target/` 형태로 **끝의 `/.`을 꼭 붙이세요.**

---

## 3. 동작 확인

### AI 서비스 — 바로 됩니다

```sh
cd ~/work/daehwa-donghaeng-client/ai
python3 -m venv .venv
. .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -e ".[dev]"
pytest                        # 7 passed 여야 합니다
ruff check .                  # All checks passed 여야 합니다
uvicorn app.main:app --port 8100
```

```sh
curl http://localhost:8100/health/live
# {"status":"ok","provider_mode":"mock"}
```

이 컨테이너(Python 3.11)에서 위 두 명령이 통과하는 것까지 확인했습니다.

### Flutter 앱 — 확인이 필요합니다

**이 세션에는 Flutter SDK가 없어서 컴파일을 확인하지 못했습니다.** `app/lib/**`의 Dart
코드는 정적으로 작성한 것이라 첫 `flutter analyze`에서 오류가 날 수 있습니다.

플랫폼 폴더(`android/`)도 없습니다. 로컬 SDK 버전에 맞춰 생성해야 하므로 일부러 넣지
않았습니다.

```sh
cd ~/work/daehwa-donghaeng-client/app
flutter create . --project-name daehwa_donghaeng --org kr.frontier --platforms android
flutter pub get
flutter analyze     # ← 여기서 나온 오류를 먼저 잡으세요
flutter test test
```

`flutter create`는 기존 `lib/`와 `pubspec.yaml`을 덮어쓰지 않고 빠진 것만 채웁니다.
이후 `AndroidManifest.xml` 권한 추가가 필요합니다 — `app/README.md`에 적어뒀습니다.

---

## 4. 이어서 할 일

| 항목 | 대상 | 기한 |
| --- | --- | --- |
| `docs/decisions/pm-confirmations.md` 3개 항목 확인 | 배해원 PM | 9/7 |
| `docs/contract/backend-adapter-request.md` 전달 | 김민섭 | 9/12까지 반영 |
| **DUR API 요청 파라미터 실측 (Blocker B 스파이크)** | 정진수 | 9/8 |
| `flutter analyze` 통과시키기 | 이석윤 | 9/7 |

가장 중요한 것은 **9/8 스파이크**입니다. DUR API가 제품명으로도 조회되는지 먼저 확인하면
약 이름 → 품목기준코드 매핑 작업 자체가 없어질 수 있습니다. 매핑 코드를 짜기 전에
이것부터 확인하세요. 상세는 `docs/decisions/blockers.md`에 있습니다.
