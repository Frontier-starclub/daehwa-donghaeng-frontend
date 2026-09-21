import asyncio
import base64
from tempfile import SpooledTemporaryFile
from types import SimpleNamespace
from typing import Any

import anthropic
import pytest
from starlette.datastructures import Headers, UploadFile

from app.errors import AiServiceError
from app.routers import ocr
from app.schemas import OcrOut


def _settings(*, is_mock: bool = False, api_key: str | None = "test-key") -> SimpleNamespace:
    return SimpleNamespace(
        is_mock=is_mock,
        anthropic_api_key=api_key,
        ocr_model="claude-opus-5",
    )


def _recognize(contents: bytes = b"image", media_type: str = "image/png") -> OcrOut:
    image_file = SpooledTemporaryFile()
    image_file.write(contents)
    image_file.seek(0)
    upload = UploadFile(
        image_file,
        filename="label.png",
        headers=Headers({"content-type": media_type}),
    )
    try:
        return asyncio.run(ocr.recognize_prescription_label(upload))
    finally:
        image_file.close()


def test_postprocess_isolates_invalid_fields_and_preserves_duplicates() -> None:
    raw_items = [
        {
            "name": "  아모잘탄정  ",
            "frequency_text": "1일 2회",
            "confidence": 0.96,
        },
        {"name": "횟수오류정", "frequency_text": "1일 12회"},
        {"name": "  ", "frequency_text": "1일 1회"},
        {"name": "신뢰도오류정", "frequency_text": None, "confidence": 95},
        {"name": "표형식정", "frequency_text": "1일 투여횟수 3"},
        {"name": "중복정", "frequency_text": "하루 두 번"},
        {"name": "중복정", "frequency_text": "하루 세 번"},
    ]

    result = ocr._postprocess_items(raw_items)

    assert [item.name for item in result] == [
        "아모잘탄정",
        "횟수오류정",
        "신뢰도오류정",
        "표형식정",
        "중복정",
        "중복정",
    ]
    assert [item.dose_frequency_per_day for item in result] == [2, None, None, None, 2, 3]
    assert [item.confidence for item in result] == [0.96, None, None, None, None, None]
    assert all(item.ingredient_name is None for item in result)
    assert all(item.ingredient_code is None for item in result)
    assert all(item.item_seq is None for item in result)


@pytest.mark.parametrize("bad_name", [None, 123, "x" * 101])
def test_postprocess_excludes_each_invalid_name_without_failing_scan(bad_name: object) -> None:
    result = ocr._postprocess_items(
        [
            {"name": bad_name, "frequency_text": "1일 1회"},
            {"name": "정상정", "frequency_text": "1일 1회"},
        ]
    )

    assert [item.name for item in result] == ["정상정"]


def test_postprocess_accepts_empty_extraction() -> None:
    assert ocr._postprocess_items([]) == []


def test_parse_message_skips_thinking_and_reads_parsed_text() -> None:
    parsed = ocr._OcrExtraction(
        items=[ocr._ExtractedMedication(name="예시약정", frequency_text="1일 3회")]
    )
    message = SimpleNamespace(
        stop_reason="end_turn",
        content=[
            SimpleNamespace(type="thinking", thinking=""),
            SimpleNamespace(type="text", text="", parsed_output=parsed),
        ],
    )

    result = ocr._parse_claude_message(message)

    assert result == parsed


def test_parse_message_validates_text_when_parsed_value_is_unavailable() -> None:
    message = {
        "stop_reason": "end_turn",
        "content": [
            {"type": "thinking", "thinking": ""},
            {
                "type": "text",
                "text": '{"items":[{"name":"예시약정","frequency_text":null}]}',
            },
        ],
    }

    result = ocr._parse_claude_message(message)

    assert result.items[0].name == "예시약정"
    assert result.items[0].frequency_text is None


@pytest.mark.parametrize("stop_reason", ["max_tokens", "refusal", "tool_use", None])
def test_parse_message_rejects_every_non_end_turn_stop(stop_reason: str | None) -> None:
    message = {
        "stop_reason": stop_reason,
        "content": [
            {
                "type": "text",
                "parsed_output": {"items": []},
                "text": '{"items":[]}',
            }
        ],
    }

    with pytest.raises(ValueError, match="end_turn"):
        ocr._parse_claude_message(message)


@pytest.mark.parametrize(
    "content",
    [
        [],
        [{"type": "thinking", "thinking": ""}],
        [{"type": "text", "text": ""}],
        [{"type": "text", "text": '{"wrong":[]}'}],
    ],
)
def test_parse_message_rejects_missing_or_malformed_structured_text(
    content: list[dict[str, object]],
) -> None:
    with pytest.raises(ValueError):
        ocr._parse_claude_message({"stop_reason": "end_turn", "content": content})


def test_anthropic_client_has_bounded_timeout_and_retry(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, Any] = {}
    sentinel = object()

    def fake_client(**kwargs: Any) -> object:
        captured.update(kwargs)
        return sentinel

    monkeypatch.setattr(anthropic, "AsyncAnthropic", fake_client)

    assert ocr._new_anthropic_client("secret") is sentinel
    assert captured == {"api_key": "secret", "timeout": 25.0, "max_retries": 0}


def test_request_uses_async_structured_vision_without_sampling(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, Any] = {}
    parsed = ocr._OcrExtraction(items=[])
    message = SimpleNamespace(
        stop_reason="end_turn",
        content=[SimpleNamespace(type="text", text="", parsed_output=parsed)],
    )

    class FakeMessages:
        async def parse(self, **kwargs: Any) -> object:
            captured["request"] = kwargs
            return message

    class FakeClient:
        messages = FakeMessages()

        async def __aenter__(self) -> "FakeClient":
            return self

        async def __aexit__(self, *args: object) -> None:
            captured["closed"] = True

    def fake_new_client(api_key: str) -> FakeClient:
        captured["api_key"] = api_key
        return FakeClient()

    monkeypatch.setattr(ocr, "_new_anthropic_client", fake_new_client)

    result = asyncio.run(
        ocr._request_extraction(
            b"binary-image",
            "image/png",
            api_key="secret",
            model="claude-opus-5",
        )
    )

    assert result == parsed
    assert captured["api_key"] == "secret"
    assert captured["closed"] is True
    request = captured["request"]
    assert request["model"] == "claude-opus-5"
    assert request["max_tokens"] == 16_000
    assert request["output_format"] is ocr._OcrExtraction
    assert request["output_config"] == {"effort": "low"}
    assert "temperature" not in request
    assert "thinking" not in request
    assert request["messages"][0]["role"] == "user"
    blocks = request["messages"][0]["content"]
    assert blocks[0]["source"] == {
        "type": "base64",
        "media_type": "image/png",
        "data": base64.b64encode(b"binary-image").decode("ascii"),
    }
    assert blocks[1]["type"] == "text"


def test_remote_route_returns_normalized_items(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(ocr, "get_settings", lambda: _settings())
    captured: dict[str, object] = {}

    async def fake_request(
        contents: bytes,
        media_type: str,
        *,
        api_key: str,
        model: str,
    ) -> ocr._OcrExtraction:
        captured.update(
            contents=contents,
            media_type=media_type,
            api_key=api_key,
            model=model,
        )
        return ocr._OcrExtraction(
            items=[
                ocr._ExtractedMedication(name="  예시약정  ", frequency_text="하루 두 번"),
                ocr._ExtractedMedication(name=" ", frequency_text="1일 1회"),
            ]
        )

    monkeypatch.setattr(ocr, "_request_extraction", fake_request)

    response = _recognize(b"fake-png")

    assert response.model_dump() == {
        "items": [
            {
                "name": "예시약정",
                "ingredient_name": None,
                "ingredient_code": None,
                "item_seq": None,
                "dose_frequency_per_day": 2,
                "confidence": None,
            }
        ]
    }
    assert captured == {
        "contents": b"fake-png",
        "media_type": "image/png",
        "api_key": "test-key",
        "model": "claude-opus-5",
    }


def test_remote_route_allows_a_successful_empty_extraction(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(ocr, "get_settings", lambda: _settings())

    async def fake_request(*args: object, **kwargs: object) -> ocr._OcrExtraction:
        return ocr._OcrExtraction(items=[])

    monkeypatch.setattr(ocr, "_request_extraction", fake_request)

    response = _recognize()

    assert response.model_dump() == {"items": []}


@pytest.mark.parametrize(
    "failure",
    [TimeoutError("slow provider"), RuntimeError("provider failed"), ValueError("interrupted")],
)
def test_remote_route_maps_every_provider_failure_to_502(
    monkeypatch: pytest.MonkeyPatch,
    failure: Exception,
) -> None:
    monkeypatch.setattr(ocr, "get_settings", lambda: _settings())

    async def fake_request(*args: object, **kwargs: object) -> ocr._OcrExtraction:
        raise failure

    monkeypatch.setattr(ocr, "_request_extraction", fake_request)

    with pytest.raises(AiServiceError) as error:
        _recognize()

    assert error.value.status_code == 502
    assert error.value.code == "OCR_UPSTREAM_ERROR"


def test_remote_route_maps_missing_key_to_502(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(ocr, "get_settings", lambda: _settings(api_key=None))

    with pytest.raises(AiServiceError) as error:
        _recognize()

    assert error.value.status_code == 502
    assert error.value.code == "OCR_UPSTREAM_ERROR"


def test_remote_route_rejects_base64_overflow_before_provider_call(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(ocr, "get_settings", lambda: _settings())
    monkeypatch.setattr(ocr, "MAX_BASE64_IMAGE_BYTES", 4)

    async def unexpected_request(*args: object, **kwargs: object) -> ocr._OcrExtraction:
        pytest.fail("provider must not be called for an oversized base64 image")

    monkeypatch.setattr(ocr, "_request_extraction", unexpected_request)

    with pytest.raises(AiServiceError) as error:
        _recognize(b"1234")

    assert error.value.status_code == 413
    assert error.value.code == "IMAGE_TOO_LARGE"


def test_mock_route_keeps_existing_raw_image_limit_semantics(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(ocr, "get_settings", lambda: _settings(is_mock=True))
    monkeypatch.setattr(ocr, "MAX_BASE64_IMAGE_BYTES", 4)

    response = _recognize(b"1234")

    assert response.items


def test_route_keeps_media_type_and_raw_size_validation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(ocr, "get_settings", lambda: _settings(is_mock=True))

    with pytest.raises(AiServiceError) as unsupported:
        _recognize(b"text", "text/plain")
    assert unsupported.value.status_code == 415
    assert unsupported.value.code == "UNSUPPORTED_IMAGE"

    monkeypatch.setattr(ocr, "MAX_IMAGE_BYTES", 3)
    with pytest.raises(AiServiceError) as oversized:
        _recognize(b"1234")
    assert oversized.value.status_code == 413
    assert oversized.value.code == "IMAGE_TOO_LARGE"


def test_base64_size_calculation_includes_padding() -> None:
    assert ocr._encoded_size(0) == 0
    assert ocr._encoded_size(1) == 4
    assert ocr._encoded_size(2) == 4
    assert ocr._encoded_size(3) == 4
    assert ocr._encoded_size(4) == 8
