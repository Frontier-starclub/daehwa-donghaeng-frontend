# 대화동행 — 앱 · AI

복약관리 기반 AI 대화동행 서비스의 **Flutter 앱**과 **AI 서비스** 저장소입니다.
백엔드는 [`frontier-starclub/daehwa-donghaeng`](https://github.com/frontier-starclub/daehwa-donghaeng)에 있습니다.

담당: 이석윤(FE·OCR 연동·음성), 정진수(약 정보·DUR·AI)

2026-09-17: 사용자 등록, 실제 Backend OCR/약 저장 호출, 복약 시간, DUR 결과, 음성/텍스트 대화를 구현했습니다.
서버 없는 실행은 `cd app` 후 `flutter run -d chrome --dart-define=USE_MOCK=true`입니다.
실제 서버 실행은 `app/scripts/run-backend.ps1`을 사용합니다. Backend 내부 AI mock과 HTTP 통합을 확인했습니다.
실제 AI 구현과 Android 실기기 검증은 남아 있습니다. [앱 README](app/README.md), [프론트 인수인계](docs/contract/frontend-handoff.md)를 보세요.

## 구조

```
app/    Flutter 앱          — 화면, 촬영, STT/TTS, 로컬 알림
ai/     FastAPI AI 서비스   — 약봉투 OCR, DUR 조회, 대화 응답 (:8100)
docs/   계약·결정 기록
```

호출 방향은 단방향입니다. **앱은 AI 서비스를 직접 호출하지 않습니다.**

```
[Flutter 앱] --REST/multipart--> [백엔드 :8090] --HTTP--> [AI 서비스 :8100]
                                       |                        |
                                  PostgreSQL          Claude API / 식약처 공공 API
```

저장소를 이렇게 나눈 이유는 [`docs/decisions/`](docs/decisions/)에 있습니다.

## 빠른 실행

### AI 서비스만

```sh
docker compose up --build
curl http://localhost:8100/health/live
# → {"status":"ok","provider_mode":"mock"}
```

로컬 Python으로:

```sh
cd ai
python3 -m venv .venv && . .venv/bin/activate    # Windows: .venv\Scripts\activate
pip install -e ".[dev]"
pytest
uvicorn app.main:app --port 8100 --reload
```

### 앱

Android·웹 플랫폼 파일이 포함되어 있습니다 — [`app/README.md`](app/README.md) 참조.

```sh
cd app
flutter pub get
flutter run
```

### 3자 통합 (백엔드 + AI + 앱)

백엔드 저장소를 형제 디렉터리에 clone 한 뒤:

```sh
docker compose -f compose.integration.yaml up --build
python ../daehwa-donghaeng/apps/backend/scripts/smoke_test.py
```

## 개발 원칙

- **계약이 먼저다.** AI 서비스 응답 필드는 백엔드 `providers.py`의 dataclass와 1:1로
  맞춘다. `ai/tests/test_contract.py`가 이를 검사한다.
- **mock이 기본이다.** API 키 없이도 전체 흐름이 돌아야 한다. `PROVIDER_MODE=mock`.
- **화면은 디자인 토큰만 쓴다.** 크기를 직접 적지 않는다 (`app/lib/design/tokens.dart`).
- **음성 파일을 서버로 보내지 않는다.** STT/TTS는 앱에서만 처리한다.
- **약봉투 원본 이미지, `.env`, API 키를 커밋하지 않는다.**
- **DUR 화면에는 백엔드가 준 disclaimer를 렌더링한다.** 하드코딩하지 않는다.
- mock 응답은 의학적 사실이 아니라 연동 검증용 데이터다.

## 환경변수

`.env.example`을 복사해 `.env`를 만듭니다. **키는 커밋하지 않습니다.**

| 이름 | 용도 |
| --- | --- |
| `AI_PROVIDER_MODE` | `mock` \| `remote`. 기본 `mock` |
| `ANTHROPIC_API_KEY` | OCR·대화 응답 |
| `DATA_GO_KR_SERVICE_KEY` | 식약처 공개 API |
