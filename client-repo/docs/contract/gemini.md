# Gemini 연동

`feature/gemini-integration`에서 OCR·문맥 대화·동의된 세션 분석에 Gemini를 선택할 수 있다.
앱 → Backend → AI 요청/응답 계약은 동일하다. DUR는 식약처 API를 계속 사용한다.

자신의 PC에서 Android 앱을 실행할 때는 Backend 저장소의
[로컬 Android 실행 안내](https://github.com/Frontier-starclub/daehwa-donghaeng/blob/feature/gemini-integration/docs/local-android.md)를 먼저 따른다.

## 로컬 통합 실행

형제 저장소 `daehwa-donghaeng/.env`에 설정한다. 이 환경의 `.env`는 이미 Gemini를
선택하도록 구성했다. 키는 Git에 올리거나 앱에 넣지 않는다.

```dotenv
LLM_PROVIDER=gemini
GEMINI_API_KEY=발급받은_키
DATA_GO_KR_SERVICE_KEY=공공데이터_Decoding_키
GEMINI_OCR_MODEL=gemini-3.8-flash
GEMINI_CHAT_MODEL=gemini-3.8-flash
```

```sh
cd daehwa-donghaeng
./scripts/start_local.sh --check
./scripts/start_local.sh
# 별도 터미널
./scripts/run_web.sh
# http://127.0.0.1:3000
```

`--check`는 선택한 제공자의 키 존재와 로컬 도구·포트를 확인하며 키 유효성을
검증하지 않는다. API 키는 AI 프로세스에만 전달된다. 새로운 개발 환경 준비는
Backend의 `scripts/setup_local.sh`, 전체 기능 설명은 `docs/e2e-ready.md`를 참고한다.

Claude를 사용하려면 `LLM_PROVIDER=anthropic`과 `ANTHROPIC_API_KEY`를 설정한다.
로컬 실행에는 `--llm-provider anthropic` 옵션도 있다. `OCR_MODEL`, `CHAT_MODEL`은
Claude 전용이며 Gemini 모델 설정과 섞이지 않는다. 제공자를 생략한 기존 설정은
Claude를 사용한다. 실패 시 다른 제공자나 mock으로 자동 전환하지 않는다.

## Compose / AI 단독 실행

앱·AI 저장소에서 Compose를 실행한다면 `client-repo/.env.example`을 `.env`로
복사하고 위 키를 입력한다. `AI_PROVIDER_MODE=remote`를 설정한다.

```sh
cd client-repo
docker compose -f compose.integration.yaml up --build --wait
# AI만: docker compose up --build
```

Backend 저장소의 `compose.yaml` + `compose.integration.yaml` 조합도 같은 변수를
지원한다. 각 Compose는 자신이 실행되는 저장소의 `.env`를 읽는다.

Python으로 AI만 실행한다면 `ai/.env.example`을 `ai/.env`로 복사한다.
이때는 `AI_PROVIDER_MODE` 대신 `PROVIDER_MODE=remote`를 사용한다.

```sh
cd client-repo/ai
uv sync --extra dev
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8100
```

## 구현

- `app/clients/gemini.py`: 기존 `httpx`로 공식
  [Interactions v1 REST API](https://ai.google.dev/api/interactions-api-v1)를 호출한다.
  별도 Google SDK 의존성은 필요하지 않다. API 키는 URL이 아닌 헤더로 전달한다.
- 요청마다 `store=false`를 보내 검색 가능한 Interaction 저장을 끈다.
  세션 문맥은 Backend가 제한한 최근 대화만 전달하고 서버 상태 ID를 사용하지 않는다.
  이 설정은 Google의 별도 서비스 데이터 처리 정책 전체를 바꾸는 옵션은 아니다.
  [Interaction 저장 설정](https://ai.google.dev/gemini-api/docs/interactions-overview#data-storage-and-retention)
- OCR은 JPEG/PNG를 inline base64 이미지로 전송한다. 원본 최대 10MiB 제한과
  약 이름·횟수 후처리를 유지한다. Google의 inline 입력은 전체 요청 20MB 제한이므로
  이 크기의 이미지와 현재 짧은 프롬프트를 담을 수 있다.
  [이미지 입력](https://ai.google.dev/gemini-api/docs/image-understanding)
- OCR과 분석은 JSON Schema를 요청하고 Pydantic으로 응답을 다시 검증한다.
  분석은 제한된 숫자 두 개만 허용한다.
  [구조화 출력](https://ai.google.dev/gemini-api/docs/structured-output)
- 완료된 텍스트만 사용한다. thought 단계는 제외하고, 미완료·빈 출력·예상하지 않은
  도구 응답·형식 위반은 기존 `*_UPSTREAM_ERROR` 502로 처리한다.
  대화의 위기 발화 고정 응답과 생성된 답변 검증도 그대로 적용한다.
- 연결 시간 제한 5초, 읽기 시간 제한 25초, 자동 재시도 없음. 인증·할당량 오류의
  원문이나 키를 사용자 응답에 노출하지 않는다.

## 검증 방법과 한계

2026-09-22 확인 결과:

- AI 325 passed, Backend 108 passed. Backend는 실제 PostgreSQL에서 실행했다.
- 양쪽 저장소 Ruff 검사와 `git diff --check` 통과.
- 세 Compose 구성 각각 Gemini/Claude 선택·환경변수 전달 검증 통과.
- `start_local.sh --fixture --llm-provider gemini`와 `run_web.sh`로 띄운 실제 웹에서
  Chromium E2E 통과: 사진 등록 → OCR → DUR → 복약 기록 → 새로고침 복구 →
  동의 → 문맥 대화 → 분석 → 보호자 초대·리포트.
- 위 외부 HTTP 응답은 테스트 데이터다. 실제 키를 사용한 검증은 아직 수행하지 않았다.

```sh
cd client-repo/ai
.venv/bin/python -m pytest

cd ../../../daehwa-donghaeng/apps/backend
.venv/bin/python -m pytest tests/test_dev_stack.py tests/test_e2e_remote.py
```

AI 테스트는 실제 HTTP 직렬화, 이미지·JSON Schema·대화 문맥, 오류·타임아웃,
키 누락, mock 모드, Claude 회귀를 검사한다. Backend E2E는 `anthropic`, `gemini`
각각 실제 Backend/AI HTTP 서버를 실행하고 외부 HTTP만 가상 응답으로 대체한다.
OCR → 약 저장 → DUR 세 종류 → 복약 → 문맥 대화 → 분석 → 보호자 공유·철회 경로다.

키 없이 Gemini 경로를 앱에서 확인하려면 Backend에서 다음과 같이 실행한다.

```sh
./scripts/start_local.sh --fixture --llm-provider gemini
# 별도 터미널
./scripts/run_web.sh
```

fixture 모드는 별도 테스트 DB와 가상 약·응답을 사용한다. 실제 Gemini 인증·모델
접근 권한·사진 인식 품질·응답 지연은 키 입력 후 확인해야 한다. Android 실제 기기
알림 도착은 별도 검증 항목이다.
