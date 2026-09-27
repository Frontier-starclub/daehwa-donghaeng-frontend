# 2026-09-22 추가 구현

이 문서는 과거 인수인계의 미구현 항목을 갱신한다. 초기 계획의 대시보드 방식을
사용해 별도 이메일 API 키 없이 보호자 리포트를 제공한다.

- Home → 지난 복약 기록 / 내 변화 요약 / 보호자 연결과 리포트 / 설정을 추가했다.
- 처음 이용 시 분석·공유 동의는 OFF다. 모두 꺼도 OCR·복약·대화 이용이 가능하다.
- 설정에서 항목별 공유, 동의 철회, 매일 이야기 시간 알림을 바꾼다.
- 약 목록에서 이름 수정·복용 종료, 일정에서 기존 시각 조회·삭제·저장을 지원한다.
- Android 로컬 알림은 권한, 매일 한국 시간 예약, 재부팅 복구, 알림 진입을 연결했다.
  웹은 서버 기능과 화면을 확인하는 경로이며 OS 백그라운드 알림은 지원하지 않는다.
- 채팅은 현재 세션의 최근 10개 완결된 대화 쌍을 LLM에 전달한다.
- DUR는 병용금기·노인주의·효능군중복을 조회한다. 모호한 품목, 부분 실패는
  `unverified`로 표시한다. 매칭되지 않은 약을 안전하다고 표시하지 않는다.
- 분석은 동의된 종료 세션의 구조화 지표만 만들며 진단·인지장애 판정을 생성하지 않는다.
  7일 기간 두 개를 비교하고, 각각 3세션·10발화 미만이면 기록 축적 화면을 표시한다.
- 보호자는 24시간 유효한 1회용 코드로 연결한다. 허용된 집계만 조회하며 대화 원문은 없다.
  철회 즉시 연결·초대를 없애고 분석 철회 시 이전 분석을 삭제한다.

## 실행

현재 workspace의 `daehwa-donghaeng`에서:

```sh
# .env에 LLM_PROVIDER=gemini, GEMINI_API_KEY, DATA_GO_KR_SERVICE_KEY 설정
./scripts/start_local.sh
# 별도 터미널, 웹 http://127.0.0.1:3000
./scripts/run_web.sh
```

전체 설명은 백엔드 `docs/e2e-ready.md`에 있다. 다른 환경은 두 저장소를 형제로
배치하고 백엔드 `scripts/setup_local.sh`를 실행한다. Docker 사용 시 이 디렉터리의
`.env.example` → `.env` 복사 후 `docker compose -f compose.integration.yaml up --build --wait`.
Claude 선택 방법을 포함한 [Gemini 연동 설정](gemini.md)도 참고한다.

## 검증

```sh
cd ai && .venv/bin/python -m pytest
cd ../app && flutter analyze && flutter test
```

Backend의 `tests/test_e2e_remote.py`는 PostgreSQL에서도 실행할 수 있으며 실제 AI
라우터와 Claude/Gemini 외부 API 클라이언트를 각각 통과한다.
`ai/tests/e2e_fixture_server.py`는 명시적인
`E2E_EXTERNAL_FIXTURES=1` 없이는 실행할 수 없고 프로덕션 코드에서 import하지 않는다.
실제 키·실제 의약 정보 결과로 간주하지 않는다.

`app/tool/web_e2e.py`는 빌드한 웹 앱과 해당 fixture 서버를 Playwright로 조작한다.
새 사용자를 만들고 사진 업로드→등록→DUR→시간→복약 응답→대화 흐름을 확인한다.
실제 키의 권한, 실제 사진 인식 품질과 기기별 카메라·음성·절전 알림 도착은 외부 검증이다.
