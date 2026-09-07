"""계약 테스트.

이 파일이 지키는 것은 '기능이 맞다'가 아니라 '백엔드가 기대하는 모양이 맞다'이다.
백엔드 어댑터가 응답을 dataclass 생성자에 그대로 넣기 때문에, 키 이름이 하나만
달라도 통합이 깨진다.
"""

import base64
import io

from fastapi.testclient import TestClient

# 백엔드 providers.py의 dataclass 필드 집합. 여기를 바꾸려면 양쪽을 함께 바꿔야 한다.
RECOGNIZED_MEDICATION_FIELDS = {
    "name",
    "ingredient_name",
    "ingredient_code",
    "item_seq",
    "dose_frequency_per_day",
    "confidence",
}
DUR_WARNING_FIELDS = {"warning_type", "medication_ids", "message", "source_code"}


# 1x1 PNG. 내용은 검사하지 않으므로 최소 바이트열이면 충분하다.
_PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR4nGP4"
    "z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
)


def _png() -> io.BytesIO:
    return io.BytesIO(_PNG_1X1)


def test_health_reports_provider_mode(client: TestClient) -> None:
    response = client.get("/health/live")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "provider_mode": "mock"}


def test_ocr_items_match_backend_dataclass(client: TestClient) -> None:
    response = client.post(
        "/v1/ocr/prescription-label",
        files={"image": ("label.png", _png(), "image/png")},
    )
    assert response.status_code == 200
    items = response.json()["items"]
    assert items, "mock 모드는 최소 1건을 돌려준다"
    for item in items:
        assert set(item) == RECOGNIZED_MEDICATION_FIELDS


def test_ocr_rejects_non_image(client: TestClient) -> None:
    response = client.post(
        "/v1/ocr/prescription-label",
        files={"image": ("note.txt", io.BytesIO(b"hello"), "text/plain")},
    )
    assert response.status_code == 415
    assert response.json()["code"] == "UNSUPPORTED_IMAGE"


def test_dur_warning_matches_backend_dataclass(client: TestClient) -> None:
    response = client.post(
        "/v1/dur/check",
        json={
            "medications": [
                {"id": "a", "name": "아모잘탄정", "ingredient_code": None, "item_seq": None},
                {"id": "b", "name": "메트포르민서방정", "ingredient_code": None, "item_seq": None},
            ]
        },
    )
    assert response.status_code == 200
    warnings = response.json()["warnings"]
    assert len(warnings) == 1
    assert set(warnings[0]) == DUR_WARNING_FIELDS
    assert warnings[0]["medication_ids"] == ["a", "b"]


def test_dur_single_medication_has_no_warning(client: TestClient) -> None:
    response = client.post(
        "/v1/dur/check",
        json={"medications": [{"id": "a", "name": "아모잘탄정"}]},
    )
    assert response.status_code == 200
    assert response.json()["warnings"] == []


def test_chat_opening_and_reply(client: TestClient) -> None:
    opening = client.post(
        "/v1/chat/reply",
        json={"opening": True, "user_message_count": 0, "content": ""},
    )
    assert opening.status_code == 200
    assert opening.json()["content"]

    reply = client.post(
        "/v1/chat/reply",
        json={"opening": False, "user_message_count": 1, "content": "잘 지냈어요"},
    )
    assert reply.status_code == 200
    assert reply.json()["content"] != opening.json()["content"]


def test_drugs_resolve_returns_one_match_per_name(client: TestClient) -> None:
    response = client.post("/v1/drugs/resolve", json={"names": ["아모잘탄정", "타이레놀"]})
    assert response.status_code == 200
    matches = response.json()["matches"]
    assert [match["name"] for match in matches] == ["아모잘탄정", "타이레놀"]
