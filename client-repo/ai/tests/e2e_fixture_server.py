"""Test-only server: real AI routes and SDK, deterministic external HTTP responses.

Run explicitly with uvicorn tests.e2e_fixture_server:app. Production never imports
this module. Fixture medicines and responses are synthetic, not medical advice.
"""

import json
import os

import anthropic
import httpx
import httpx2

if os.environ.get("E2E_EXTERNAL_FIXTURES") != "1":
    raise RuntimeError("This server is for explicit E2E fixture runs only")

os.environ.update(
    PROVIDER_MODE="remote",
    ANTHROPIC_API_KEY="e2e-fixture",
    GEMINI_API_KEY="e2e-fixture",
    DATA_GO_KR_SERVICE_KEY="e2e-fixture",
)


def anthropic_response(request):
    body = json.loads(request.content)
    assert request.url.path.endswith("/messages")
    content = body["messages"][-1]["content"]
    if isinstance(content, list) and any(item["type"] == "image" for item in content):
        reply = json.dumps(
            {
                "items": [
                    {"name": "가상테스트약A", "frequency_text": "1일 1회"},
                    {"name": "가상테스트약B", "frequency_text": "1일 1회"},
                ]
            },
            ensure_ascii=False,
        )
    elif body.get("output_config", {}).get("format"):
        reply = json.dumps({"mood_score": 0.4, "confidence": 0.8})
    elif len(body["messages"]) > 1:
        # A visible assertion that prior turns actually reached the external boundary.
        reply = "앞서 산책 이야기를 해주셨지요. 오늘도 편하게 이야기해주세요."
    else:
        reply = "반가워요. 오늘 하루는 어떠셨어요?"
    return httpx2.Response(
        200,
        json={
            "id": "msg_e2e",
            "type": "message",
            "role": "assistant",
            "model": body["model"],
            "content": [{"type": "text", "text": reply}],
            "stop_reason": "end_turn",
            "stop_sequence": None,
            "usage": {"input_tokens": 10, "output_tokens": 10},
        },
    )


_sync, _async = anthropic.Anthropic, anthropic.AsyncAnthropic


def sync_client(**kwargs):
    assert os.environ.get("LLM_PROVIDER") != "gemini", "Unexpected Claude fallback"
    return _sync(
        **kwargs, http_client=httpx2.Client(transport=httpx2.MockTransport(anthropic_response))
    )


def async_client(**kwargs):
    assert os.environ.get("LLM_PROVIDER") != "gemini", "Unexpected Claude fallback"
    return _async(
        **kwargs, http_client=httpx2.AsyncClient(transport=httpx2.MockTransport(anthropic_response))
    )


anthropic.Anthropic = sync_client
anthropic.AsyncAnthropic = async_client

from app.clients import gemini  # noqa: E402
from app.clients.mfds import MfdsClient  # noqa: E402
from app.main import app  # noqa: E402,F401
from app.routers import dur  # noqa: E402


def gemini_response(request):
    assert str(request.url) == "https://generativelanguage.googleapis.com/v1/interactions"
    assert request.headers["x-goog-api-key"] == "e2e-fixture"
    body = json.loads(request.content)
    assert body["store"] is False and body["stream"] is False
    assert body["system_instruction"]
    assert body["model"].startswith("gemini-")
    steps = body["input"]
    if any(part["type"] == "image" for part in steps[-1]["content"]):
        assert "items" in body["response_format"]["schema"]["properties"]
        reply = json.dumps(
            {
                "items": [
                    {"name": "가상테스트약A", "frequency_text": "1일 1회"},
                    {"name": "가상테스트약B", "frequency_text": "1일 1회"},
                ]
            },
            ensure_ascii=False,
        )
    elif body.get("response_format"):
        assert "mood_score" in body["response_format"]["schema"]["properties"]
        reply = json.dumps({"mood_score": 0.4, "confidence": 0.8})
    elif len(steps) > 1:
        assert [step["type"] for step in steps[:2]] == ["user_input", "model_output"]
        assert "산책" in steps[0]["content"][0]["text"]
        reply = "앞서 산책 이야기를 해주셨지요. 오늘도 편하게 이야기해주세요."
    else:
        reply = "반가워요. 오늘 하루는 어떠셨어요?"
    return httpx.Response(
        200,
        json={
            "id": "gemini-e2e",
            "object": "interaction",
            "status": "completed",
            "steps": [{"type": "model_output", "content": [{"type": "text", "text": reply}]}],
        },
    )


_gemini_client = gemini.GeminiClient
gemini.GeminiClient = lambda api_key: _gemini_client(
    api_key, transport=httpx.MockTransport(gemini_response)
)


def mfds_response(request):
    operation = request.url.path.rsplit("/", 1)[-1]
    seq = request.url.params.get("itemSeq")
    name = request.url.params.get("itemName", "")
    seq = seq or ("900001" if "A" in name else "900002")
    if operation == "getDurPrdlstInfoList03":
        rows = [{"ITEM_SEQ": seq}]
    elif operation == "getUsjntTabooInfoList03":
        rows = [
            {
                "INGR_CODE": seq,
                "MIXTURE_INGR_CODE": "900002" if seq == "900001" else "900001",
                "DUR_SEQ": "901",
                "PROHBT_CONTENT": "E2E 가상 병용금기 응답",
            }
        ]
    elif operation == "getOdsnAtentInfoList03":
        rows = [{"ITEM_SEQ": seq, "PROHBT_CONTENT": "E2E 가상 노인주의 응답"}]
    elif operation == "getEfcyDplctInfoList03":
        rows = [
            {
                "ITEM_SEQ": seq,
                "EFFECT_NAME": "E2E 가상 효능군",
                "SERS_NAME": "E2E 가상 계열",
                "DUR_SEQ": "902",
            }
        ]
    else:
        raise AssertionError(operation)
    return httpx.Response(
        200,
        json={
            "header": {"resultCode": "00"},
            "body": {
                "totalCount": len(rows),
                "pageNo": 1,
                "items": rows,
            },
        },
    )


fixture_mfds = MfdsClient(
    service_key="fixture",
    base_url="https://fixture.invalid",
    transport=httpx.MockTransport(mfds_response),
)
dur.get_mfds_client = lambda: fixture_mfds
