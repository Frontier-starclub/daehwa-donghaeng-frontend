"""Exercise real Gemini HTTP serialization and route validation without API keys."""

import base64
import json

import anthropic
import httpx
import pytest
from pydantic import ValidationError

from app.clients import gemini
from app.config import Settings, get_settings


def completed(text):
    return {
        "status": "completed",
        "steps": [
            {"type": "thought", "summary": [{"type": "text", "text": "private thought"}]},
            {"type": "model_output", "content": [{"type": "text", "text": text}]},
        ],
    }


@pytest.fixture(autouse=True)
def gemini_settings(monkeypatch):
    for key, value in {
        "PROVIDER_MODE": "remote",
        "LLM_PROVIDER": "gemini",
        "GEMINI_API_KEY": "test-gemini-secret",
        "ANTHROPIC_API_KEY": "",
        "GEMINI_OCR_MODEL": "gemini-ocr-test",
        "GEMINI_CHAT_MODEL": "gemini-chat-test",
    }.items():
        monkeypatch.setenv(key, value)
    get_settings.cache_clear()

    def unexpected_claude(*args, **kwargs):
        pytest.fail("Gemini must not call Claude, including on failure")

    monkeypatch.setattr(anthropic, "Anthropic", unexpected_claude)
    monkeypatch.setattr(anthropic, "AsyncAnthropic", unexpected_claude)


@pytest.fixture
def external(monkeypatch):
    real_client = gemini.GeminiClient

    def install(payload=None, *, status=200, timeout=False):
        calls = []

        def handler(request):
            calls.append(request)
            if timeout:
                raise httpx.ReadTimeout("test-gemini-secret upstream text", request=request)
            return httpx.Response(status, json=payload)

        monkeypatch.setattr(
            gemini,
            "GeminiClient",
            lambda api_key: real_client(
                api_key,
                transport=httpx.MockTransport(handler),
            ),
        )
        return calls

    return install


def call(client, task):
    if task == "OCR":
        return client.post(
            "/v1/ocr/prescription-label",
            files={
                "image": ("label.png", b"synthetic-image", "image/png"),
            },
        )
    if task == "CHAT":
        return client.post("/v1/chat/reply", json={"content": "오늘 산책했어요"})
    return client.post("/v1/analysis/session", json={"utterances": ["오늘 기분이 좋아요"]})


def test_ocr_sends_image_schema_and_preserves_existing_postprocessing(client, external):
    calls = external(
        completed(
            json.dumps(
                {
                    "items": [
                        {"name": "  가상약A  ", "frequency_text": "1일 2회"},
                        {"name": "가상약B", "frequency_text": None},
                        {"name": "가상약A", "frequency_text": "1일 1회"},
                        {"name": None, "frequency_text": "1일 3회"},
                    ]
                }
            )
        )
    )
    result = call(client, "OCR")
    assert result.status_code == 200, result.text
    items = result.json()["items"]
    assert [item["name"] for item in items] == ["가상약A", "가상약B", "가상약A"]
    assert [item["dose_frequency_per_day"] for item in items] == [2, None, 1]
    for item in items:
        assert all(
            item[field] is None
            for field in (
                "confidence",
                "item_seq",
                "ingredient_name",
                "ingredient_code",
            )
        )
    assert len(calls) == 1
    request = calls[0]
    assert request.method == "POST" and str(request.url) == gemini.API_URL
    assert request.headers["x-goog-api-key"] == "test-gemini-secret"
    assert "test-gemini-secret" not in str(request.url) + request.content.decode()
    body = json.loads(request.content)
    assert body["model"] == "gemini-ocr-test"
    assert body["store"] is False and body["stream"] is False
    assert "추측하지" in body["system_instruction"]
    image = body["input"][0]["content"][0]
    assert image["type"] == "image" and image["mime_type"] == "image/png"
    assert base64.b64decode(image["data"]) == b"synthetic-image"
    assert body["response_format"]["mime_type"] == "application/json"
    assert set(body["response_format"]["schema"]["properties"]) == {"items"}
    assert request.extensions["timeout"]["read"] == 25


def test_chat_transmits_only_supplied_history_and_validates_output(client, external):
    calls = external(completed("산책하셨군요. 기분은 어떠셨어요?"))
    response = client.post(
        "/v1/chat/reply",
        json={
            "content": "함께 산책했어요",
            "history": [
                {"role": "user", "content": "강아지를 키워요"},
                {"role": "assistant", "content": "이름이 무엇인가요?"},
            ],
        },
    )
    assert response.status_code == 200, response.text
    assert "private thought" not in response.text
    body = json.loads(calls[0].content)
    assert body["model"] == "gemini-chat-test"
    assert body["store"] is False and "previous_interaction_id" not in body
    assert [step["type"] for step in body["input"]] == [
        "user_input",
        "model_output",
        "user_input",
    ]
    assert [step["content"][0]["text"] for step in body["input"]] == [
        "강아지를 키워요",
        "이름이 무엇인가요?",
        "함께 산책했어요",
    ]
    assert "119" in body["system_instruction"] and "진단" in body["system_instruction"]
    assert "response_format" not in body
    # The AI client has no memory between requests.
    assert call(client, "CHAT").status_code == 200
    assert len(json.loads(calls[-1].content)["input"]) == 1


def test_analysis_uses_bounded_numeric_json_schema(client, external):
    calls = external(completed('{"mood_score":0.4,"confidence":0.8}'))
    response = call(client, "ANALYSIS")
    assert response.status_code == 200
    assert response.json() == {"mood_score": 0.4, "confidence": 0.8}
    body = json.loads(calls[0].content)
    assert body["model"] == "gemini-chat-test"
    schema = body["response_format"]["schema"]
    assert schema["additionalProperties"] is False
    assert schema["properties"]["mood_score"]["minimum"] == -1
    assert schema["properties"]["mood_score"]["maximum"] == 1
    assert "진단하지" in body["system_instruction"]


@pytest.mark.parametrize("task", ["OCR", "CHAT", "ANALYSIS"])
@pytest.mark.parametrize("status", [401, 403, 429, 500, 503])
def test_upstream_errors_never_leak_secrets_or_silently_fallback(client, external, task, status):
    calls = external({"error": {"message": "test-gemini-secret raw upstream"}}, status=status)
    result = call(client, task)
    assert result.status_code == 502
    assert result.json()["code"] == task + "_UPSTREAM_ERROR"
    assert "test-gemini-secret" not in result.text and "raw upstream" not in result.text
    assert len(calls) == 1  # No retry storm or fallback to another provider.


@pytest.mark.parametrize("task", ["OCR", "CHAT", "ANALYSIS"])
def test_timeouts_are_bounded_errors(client, external, task):
    calls = external(timeout=True)
    result = call(client, task)
    assert result.status_code == 502
    assert result.json()["code"] == task + "_UPSTREAM_ERROR"
    assert "test-gemini-secret" not in result.text
    assert len(calls) == 1


@pytest.mark.parametrize("task", ["OCR", "CHAT", "ANALYSIS"])
def test_missing_key_does_not_make_an_http_request(client, external, monkeypatch, task):
    calls = external()
    monkeypatch.setenv("GEMINI_API_KEY", "  ")
    get_settings.cache_clear()
    result = call(client, task)
    assert result.status_code == 502 and not calls


@pytest.mark.parametrize(
    "payload",
    [
        {**completed("잘린 응답이에요."), "status": "incomplete"},
        {**completed("부분 응답이에요."), "status": "failed"},
        {**completed("진행 중이에요."), "status": "in_progress"},
        {**completed("취소됐어요."), "status": "cancelled"},
        {**completed("도구가 필요해요."), "status": "requires_action"},
        {"status": "completed", "steps": []},
        {"status": "completed", "steps": [{"type": "thought", "summary": []}]},
        {"status": "completed", "steps": [{"type": "function_call", "name": "foo"}]},
        {
            "status": "completed",
            "steps": [
                {
                    "type": "model_output",
                    "content": [
                        {"type": "refusal", "text": "거부했어요."},
                    ],
                }
            ],
        },
        completed("  "),
        completed("약을 바로 중단하세요."),
        completed("* 산책하셨군요."),
        completed("하나요? 둘인가요?"),
        [],
        {"status": "completed", "steps": "not a list"},
    ],
)
def test_invalid_or_incomplete_chat_is_not_returned_as_success(client, external, payload):
    external(payload)
    result = call(client, "CHAT")
    assert result.status_code == 502 and result.json()["code"] == "CHAT_UPSTREAM_ERROR"


@pytest.mark.parametrize(
    ("task", "text"),
    [
        ("OCR", "```json\n{}\n```"),
        ("OCR", '{"items":"bad"}'),
        ("OCR", '{"items":[{"name":123,"frequency_text":null}]}'),
        ("ANALYSIS", '{"mood_score":2,"confidence":0.8}'),
        ("ANALYSIS", '{"mood_score":0,"confidence":2}'),
        ("ANALYSIS", '{"mood_score":0,"confidence":0.8,"diagnosis":"forbidden"}'),
        ("ANALYSIS", '{"mood_score":NaN,"confidence":0.8}'),
        ("ANALYSIS", "{}"),
    ],
)
def test_structured_output_is_locally_validated(client, external, task, text):
    external(completed(text))
    assert call(client, task).status_code == 502


def test_opening_and_explicit_safety_replies_do_not_require_a_key(client, external, monkeypatch):
    calls = external()
    monkeypatch.setenv("GEMINI_API_KEY", "")
    get_settings.cache_clear()
    for payload in ({"opening": True}, {"content": "이 약을 같이 먹어도 될까요"}):
        assert client.post("/v1/chat/reply", json=payload).status_code == 200
    assert not calls


def test_mock_mode_stays_offline_for_gemini(client, external, monkeypatch):
    calls = external()
    monkeypatch.setenv("PROVIDER_MODE", "mock")
    monkeypatch.setenv("GEMINI_API_KEY", "")
    get_settings.cache_clear()
    for task in ("OCR", "CHAT", "ANALYSIS"):
        assert call(client, task).status_code == 200
    assert not calls


def test_gemini_accepts_image_over_claude_base64_limit(client, external):
    calls = external(completed('{"items":[]}'))
    result = client.post(
        "/v1/ocr/prescription-label",
        files={
            "image": ("label.jpg", b"x" * 7_500_001, "image/jpeg"),
        },
    )
    assert result.status_code == 200 and len(calls) == 1
    assert (
        client.post(
            "/v1/ocr/prescription-label",
            files={
                "image": ("label.jpg", b"x" * (10 * 1024 * 1024 + 1), "image/jpeg"),
            },
        ).status_code
        == 413
    )
    assert len(calls) == 1


def test_invalid_provider_is_rejected_and_model_names_are_independent(monkeypatch):
    with pytest.raises(ValidationError):
        Settings(llm_provider="typo", _env_file=None)
    monkeypatch.delenv("GEMINI_OCR_MODEL")
    monkeypatch.delenv("GEMINI_CHAT_MODEL")
    settings = Settings(ocr_model="claude-custom", chat_model="claude-chat", _env_file=None)
    assert settings.gemini_ocr_model == settings.gemini_chat_model == "gemini-3.8-flash"
