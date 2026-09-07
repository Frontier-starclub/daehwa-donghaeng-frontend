# 백엔드 어댑터 추가 요청

- **요청자**: 이석윤 (FE·AI)
- **수신**: 김민섭 (BE)
- **날짜**: 2026-09-06
- **배경**: `docs/decisions/2026-09-06-repo-split.md`
- **기한**: 9/12 (Phase2-A 종료) — 9/15~16 통합 테스트 전까지

---

## 요약

AI 파트(약봉투 OCR, DUR 조회, 대화 응답)를 별도 저장소의 독립 서비스로 구현합니다.
백엔드에는 **HTTP 어댑터 3개와 환경변수 2개**만 추가하면 됩니다. 기존 API 계약, 스키마,
예외 처리, 테스트는 건드리지 않습니다.

`PROVIDER_MODE`의 기본값은 `mock`을 유지하므로, 이 변경을 넣어도 **기존 동작은 그대로**입니다.
`remote`로 띄웠을 때만 AI 서비스를 호출합니다.

---

## 1. 환경변수 2개

`apps/backend/app/config.py`의 `Settings`에 추가:

```python
class Settings(BaseSettings):
    ...
    provider_mode: str = "mock"          # 기존 — "mock" | "remote"
    ai_service_url: str = "http://ai:8100"   # 신규
    ai_service_timeout: float = 30.0         # 신규 (OCR은 vision 호출이라 여유 필요)
```

`.env.example`에도 함께 추가 부탁드립니다.

```
PROVIDER_MODE=mock
AI_SERVICE_URL=http://ai:8100
AI_SERVICE_TIMEOUT=30
```

---

## 2. 어댑터 3개

`apps/backend/app/providers.py` 하단, 기존 Mock 클래스들 아래에 추가합니다.
**응답 필드가 기존 dataclass와 1:1로 일치**하도록 AI 서비스를 설계했으므로 변환 로직이
거의 없습니다.

```python
import httpx
from app.config import get_settings


def _ai_client() -> httpx.Client:
    settings = get_settings()
    return httpx.Client(
        base_url=settings.ai_service_url,
        timeout=settings.ai_service_timeout,
    )


class HttpOCRProvider:
    name = "remote"

    def recognize(self, image: bytes, scenario: str) -> list[RecognizedMedication]:
        try:
            with _ai_client() as client:
                response = client.post(
                    "/v1/ocr/prescription-label",
                    files={"image": ("label.jpg", image, "image/jpeg")},
                )
                response.raise_for_status()
        except httpx.HTTPError as exc:
            raise RuntimeError("AI OCR service call failed") from exc
        return [RecognizedMedication(**item) for item in response.json()["items"]]


class HttpDURProvider:
    name = "remote"

    def check(
        self, medications: list[MedicationForCheck], scenario: str
    ) -> list[DurProviderWarning]:
        payload = {"medications": [asdict(item) for item in medications]}
        try:
            with _ai_client() as client:
                response = client.post("/v1/dur/check", json=payload)
                response.raise_for_status()
        except httpx.HTTPError as exc:
            raise RuntimeError("AI DUR service call failed") from exc
        return [DurProviderWarning(**item) for item in response.json()["warnings"]]


class HttpChatProvider:
    name = "remote"

    def _reply(self, payload: dict) -> str:
        try:
            with _ai_client() as client:
                response = client.post("/v1/chat/reply", json=payload)
                response.raise_for_status()
        except httpx.HTTPError as exc:
            raise RuntimeError("AI chat service call failed") from exc
        return response.json()["content"]

    def opening_message(self) -> str:
        return self._reply(
            {"opening": True, "user_message_count": 0, "content": ""}
        )

    def reply(self, user_message_count: int, content: str) -> str:
        return self._reply(
            {
                "opening": False,
                "user_message_count": user_message_count,
                "content": content,
            }
        )
```

`asdict`는 `dataclasses`에서, `httpx`는 이미 `pyproject.toml`의 dev 의존성에 있습니다.
runtime 의존성으로 옮기거나 별도 추가가 필요합니다.

### provider 선택

파일 하단의 모듈 레벨 인스턴스를 `PROVIDER_MODE`로 분기합니다.

```python
_settings = get_settings()
_remote = _settings.provider_mode == "remote"

ocr_provider: OCRProvider = HttpOCRProvider() if _remote else MockOCRProvider()
dur_provider: DURProvider = HttpDURProvider() if _remote else MockDURProvider()
chat_provider: ChatProvider = HttpChatProvider() if _remote else MockChatProvider()
```

---

## 3. 예외 처리 — 수정 불필요

어댑터가 실패 시 `RuntimeError`를 던지므로,
`apps/backend/app/api/medications.py`의 기존 처리가 그대로 동작합니다.

- OCR 실패 → `502 OCR_PROVIDER_ERROR`, `medication_scans.status = "failed"`
- DUR 실패 → `502 DUR_PROVIDER_ERROR`, `dur_checks.status = "failed"`

`scenario` 쿼리 파라미터는 mock 전용 제어값이므로 어댑터에서는 무시합니다.
`remote` 모드에서 `scenario`를 넘겨도 실제 결과가 반환됩니다.

---

## 4. compose 연동 (선택)

로컬에서 3자 통합 테스트를 하려면 `compose.yaml`에 AI 서비스를 추가하면 됩니다.
client 저장소가 override 파일 예시를 제공합니다.

```yaml
  ai:
    image: daehwa-ai:dev          # 또는 build: ../daehwa-donghaeng-client/ai
    ports:
      - "8100:8100"
    environment:
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}
      DATA_GO_KR_SERVICE_KEY: ${DATA_GO_KR_SERVICE_KEY}
    healthcheck:
      test: ["CMD", "python", "-c",
             "import urllib.request; urllib.request.urlopen('http://localhost:8100/health/live')"]
      interval: 5s
      timeout: 3s
      retries: 10

  backend:
    environment:
      PROVIDER_MODE: remote
      AI_SERVICE_URL: http://ai:8100
    depends_on:
      ai:
        condition: service_healthy
```

**API 키는 client 저장소 담당자가 관리합니다.** 백엔드 배포 환경에 키를 넣지 않습니다.

---

## 5. 검증 방법

이 변경이 옳다는 기준은 **기존 smoke test가 두 모드에서 동일하게 통과**하는 것입니다.

```sh
# mock 모드 — 기존과 동일하게 통과해야 함
PROVIDER_MODE=mock docker compose up -d
python apps/backend/scripts/smoke_test.py

# remote 모드 — AI 서비스를 띄운 뒤 동일 스크립트 통과
PROVIDER_MODE=remote docker compose up -d
python apps/backend/scripts/smoke_test.py
```

기존 테스트(`apps/backend/tests/`)는 mock 기준이므로 **수정 없이 통과**해야 합니다.
통과하지 않으면 어댑터가 계약을 벗어난 것입니다.

---

## 6. 별건 확인 요청 — 보호자(Caregiver) 연동

회의록 Phase1은 *복약 캘린더 + 보호자 연동*인데, 현재 백엔드에는
`consents.caregiver_share_allowed` 플래그만 있고 Caregiver 모델·API가 없습니다.

이는 회의록 결정사항 1("8월은 MVP 2단계 OCR+DUR에 집중")과 안건1 결론("분석은 제외")에
따라 팀이 의도적으로 뒤로 민 것으로 이해하고 있습니다. 맞다면 **M3(12월) 스코프로 확정**하고,
client 쪽에서도 REPORT-01/02, INSIGHT-01/02 화면을 같은 시점으로 잡겠습니다.

인식이 다르다면 알려주세요.
