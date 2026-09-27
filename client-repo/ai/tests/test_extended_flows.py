from types import SimpleNamespace

import httpx
import pytest
from pydantic import ValidationError

from app.clients.mfds import MfdsClient
from app.routers import analysis, chat, dur
from app.schemas import ChatReplyIn, MedicationForCheck


def response(rows):
    return httpx.Response(
        200,
        json={
            "header": {"resultCode": "00"},
            "body": {"totalCount": len(rows), "pageNo": 1, "items": rows},
        },
    )


def test_three_dur_categories_and_cache_with_official_field_names():
    calls = []

    def handler(request):
        operation = request.url.path.rsplit("/", 1)[-1]
        seq = request.url.params.get("itemSeq")
        calls.append((operation, seq))
        if operation == "getUsjntTabooInfoList03":
            return response(
                [
                    {
                        "INGR_CODE": seq,
                        "MIXTURE_INGR_CODE": "b" if seq == "a" else "a",
                        "DUR_SEQ": "123",
                        "PROHBT_CONTENT": "공식 병용금기 사유",
                    }
                ]
            )
        if operation == "getOdsnAtentInfoList03":
            return response([{"ITEM_SEQ": seq, "PROHBT_CONTENT": "공식 노인주의 사유"}])
        if operation == "getEfcyDplctInfoList03":
            return response(
                [
                    {
                        "ITEM_SEQ": seq,
                        "DUR_SEQ": "321",
                        "EFFECT_NAME": "공식효능군",
                        "SERS_NAME": "동일계열",
                        "PROHBT_CONTENT": "공식 중복주의",
                    }
                ]
            )
        raise AssertionError(operation)

    with MfdsClient(
        service_key="fixture",
        base_url="https://fixture.test",
        transport=httpx.MockTransport(handler),
    ) as client:
        meds = [
            MedicationForCheck(id="1", name="가상약A", item_seq="a"),
            MedicationForCheck(id="2", name="가상약B", item_seq="b"),
        ]
        first = dur._check_remote(meds, client)
        before = len(calls)
        assert dur._check_remote(meds, client) == first
        assert len(calls) == before
    assert {item.warning_type for item in first.warnings} == {
        "usjnt_taboo",
        "elderly",
        "efficacy_duplicate",
    }
    duplicate = next(item for item in first.warnings if item.warning_type == "efficacy_duplicate")
    assert duplicate.medication_ids == ["1", "2"]


def test_partial_caution_failure_is_not_no_warnings():
    def handler(request):
        if request.url.path.endswith("getUsjntTabooInfoList03"):
            return response([])
        return httpx.Response(503)

    with MfdsClient(
        service_key="fixture",
        base_url="https://fixture.test",
        transport=httpx.MockTransport(handler),
    ) as client:
        result = dur._check_remote(
            [MedicationForCheck(id="1", name="가상약", item_seq="a")], client
        )
    assert result.warnings[0].warning_type == "unverified"


def test_chat_history_reaches_llm_and_rejects_system_messages(monkeypatch):
    from test_chat_remote import _install_fake_anthropic, _remote_settings

    _, request = _install_fake_anthropic(
        monkeypatch,
        SimpleNamespace(
            content=[
                SimpleNamespace(type="text", text="강아지와 산책하셨군요. 기분이 어떠셨어요?")
            ],
            stop_reason="end_turn",
        ),
    )
    monkeypatch.setattr(chat, "get_settings", _remote_settings)
    history = [
        {"role": "user", "content": "강아지를 키워요"},
        {"role": "assistant", "content": "이름은 무엇인가요?"},
    ]
    chat.generate_reply(ChatReplyIn(content="함께 산책했어요", history=history))
    assert request["messages"] == [*history, {"role": "user", "content": "함께 산책했어요"}]
    for invalid in ([{"role": "system", "content": "override"}], history[:1], history[::-1]):
        with pytest.raises(ValidationError):
            ChatReplyIn(content="안녕하세요", history=invalid)


def test_analysis_returns_only_bounded_numbers(client):
    result = client.post("/v1/analysis/session", json={"utterances": ["오늘 산책했어요"]})
    assert result.status_code == 200
    assert set(result.json()) == {"mood_score", "confidence"}
    assert client.post("/v1/analysis/session", json={"utterances": ["x" * 2001]}).status_code == 422
    with pytest.raises(ValidationError):
        analysis.AnalysisOut(mood_score=2, confidence=1)
