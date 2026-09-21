from types import SimpleNamespace
from typing import Any

import anthropic
import pytest

from app.errors import AiServiceError
from app.routers import chat
from app.schemas import ChatReplyIn


def _remote_settings(**overrides: Any) -> SimpleNamespace:
    values = {
        "is_mock": False,
        "anthropic_api_key": "test-anthropic-key",
        "chat_model": "test-chat-model",
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def _install_fake_anthropic(
    monkeypatch: pytest.MonkeyPatch,
    response: object,
) -> tuple[dict[str, Any], dict[str, Any]]:
    client_arguments: dict[str, Any] = {}
    request_arguments: dict[str, Any] = {}

    class FakeMessages:
        def create(self, **kwargs: Any) -> object:
            request_arguments.update(kwargs)
            return response

    class FakeAnthropic:
        def __init__(self, **kwargs: Any) -> None:
            client_arguments.update(kwargs)
            self.messages = FakeMessages()

        def __enter__(self) -> "FakeAnthropic":
            return self

        def __exit__(self, *_args: object) -> None:
            client_arguments["closed"] = True

    monkeypatch.setattr(anthropic, "Anthropic", FakeAnthropic)
    return client_arguments, request_arguments


def _generate_reply() -> Any:
    return chat.generate_reply(
        ChatReplyIn(
            opening=False,
            user_message_count=2,
            content="오늘 산책했어요.",
        )
    )


def test_mock_responses_are_unchanged(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fail_if_called(**_kwargs: Any) -> None:
        pytest.fail("mock 모드에서는 Anthropic client를 만들면 안 됩니다")

    monkeypatch.setattr(anthropic, "Anthropic", fail_if_called)

    opening = chat.generate_reply(
        ChatReplyIn(opening=True, user_message_count=0, content="")
    )
    reply = chat.generate_reply(
        ChatReplyIn(
            opening=False,
            user_message_count=2,
            content="오늘 산책했어요.",
        )
    )

    assert opening.content == "오늘 하루 어떻게 보내셨어요?"
    assert reply.content == "말씀해 주셔서 고마워요. 그때 기분은 어떠셨어요?"


def test_remote_opening_uses_fixed_greetings_without_anthropic(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(chat, "get_settings", lambda: _remote_settings())

    def fail_if_called(**_kwargs: Any) -> None:
        pytest.fail("첫 인사에는 Anthropic client를 만들면 안 됩니다")

    monkeypatch.setattr(anthropic, "Anthropic", fail_if_called)

    contents = []
    for count in range(3):
        response = chat.generate_reply(
            ChatReplyIn(opening=True, user_message_count=count, content="")
        )
        contents.append(response.content)

    assert contents == [chat._REMOTE_OPENING] * 3


def test_remote_reply_calls_anthropic_and_extracts_text_blocks(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(chat, "get_settings", lambda: _remote_settings())
    upstream_response = SimpleNamespace(
        stop_reason="end_turn",
        content=[
            SimpleNamespace(type="thinking", thinking="internal reasoning"),
            SimpleNamespace(type="text", text="  산책을 다녀오셨군요.  "),
            SimpleNamespace(type="text", text="기분은 어떠셨어요?\n"),
        ],
    )
    client_arguments, request_arguments = _install_fake_anthropic(
        monkeypatch, upstream_response
    )

    response = _generate_reply()

    assert response.content == "산책을 다녀오셨군요. 기분은 어떠셨어요?"
    assert client_arguments == {
        "api_key": "test-anthropic-key",
        "timeout": 25.0,
        "max_retries": 0,
        "closed": True,
    }
    assert request_arguments["model"] == "test-chat-model"
    assert request_arguments["max_tokens"] == 16_000
    assert request_arguments["output_config"] == {"effort": "low"}
    assert request_arguments["messages"] == [
        {"role": "user", "content": "오늘 산책했어요."}
    ]
    assert "temperature" not in request_arguments
    assert "thinking" not in request_arguments
    assert all(message["role"] != "assistant" for message in request_arguments["messages"])

    system_prompt = request_arguments["system"]
    for required_rule in ("존댓말", "1~3문장", "질문", "진단", "복약", "119", "109"):
        assert required_rule in system_prompt
    for contact in ("가족", "의사", "약사"):
        assert contact in system_prompt


@pytest.mark.parametrize(
    ("content", "expected"),
    [
        ("죽고 싶어요", "109"),
        ("죽을래요", "109"),
        ("가슴이 너무 아프고 숨이 안 쉬어져요", "119"),
        ("숨을 못 쉬겠어요", "119"),
        ("호흡곤란이에요", "119"),
        ("호흡이 곤란해요", "119"),
        ("수면제 스무 알을 먹었어요", "119"),
        ("이 약을 같이 먹어도 될까요", "의사나 약사"),
        ("타이레놀 먹어도 될까요", "의사나 약사"),
        ("혈압약은 언제 먹어야 하나요?", "의사나 약사"),
        ("타이레놀 몇 알 먹어야 하나요?", "의사나 약사"),
        ("이 약은 식전에 복용하나요?", "의사나 약사"),
        ("와파린은 언제 먹어야 하나요?", "의사나 약사"),
        ("리피토는 몇 알 먹어야 하나요?", "의사나 약사"),
        ("메트포르민을 같이 먹어도 될까요?", "의사나 약사"),
    ],
)
def test_explicit_safety_messages_do_not_call_anthropic(
    monkeypatch: pytest.MonkeyPatch,
    content: str,
    expected: str,
) -> None:
    monkeypatch.setattr(chat, "get_settings", lambda: _remote_settings())

    def fail_if_called(**_kwargs: Any) -> None:
        pytest.fail("명시적인 안전 발화는 외부 모델을 호출하면 안 됩니다")

    monkeypatch.setattr(anthropic, "Anthropic", fail_if_called)
    response = chat.generate_reply(
        ChatReplyIn(opening=False, user_message_count=1, content=content)
    )

    assert expected in response.content
    assert "\n" not in response.content


@pytest.mark.parametrize(
    "content",
    [
        "약을 두 번 먹어요",
        "하루에 약을 두 번 먹으라고 했어요",
        "가슴이 아프지 않아요",
        "가슴 통증은 없어요",
        "과다복용이 무엇인가요?",
        "호흡곤란이 무엇인가요?",
        "죽고 싶지 않아요",
        "달걀 몇 알 샀어요?",
        "메추리알 몇 알 먹을까요?",
        "오늘 저녁은 언제 먹어야 하나요?",
        "밥은 언제 먹어야 하나요?",
        "간식을 같이 먹어도 될까요?",
    ],
)
def test_non_crisis_phrases_do_not_trigger_a_fixed_safety_reply(content: str) -> None:
    assert chat._safety_reply(content) is None


@pytest.mark.parametrize(
    "upstream_response",
    [
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="   ")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="thinking", thinking="no visible response")],
        ),
        SimpleNamespace(
            stop_reason="refusal",
            content=[SimpleNamespace(type="text", text="응답할 수 없습니다.")],
        ),
        SimpleNamespace(
            stop_reason="max_tokens",
            content=[SimpleNamespace(type="text", text="잘린 응답")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="* 약을 끊으세요")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="하나요? 둘인가요?")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="하나. 둘. 셋. 넷.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="약을 바로 중단하세요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[
                SimpleNamespace(type="text", text="타이레놀을 하루 두 알 드세요.")
            ],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="그 약은 계속 드셔도 됩니다.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="• 오늘 산책하셨군요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="그 증상은 심근경색입니다.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="우울증으로 보입니다.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="아마 약 부작용이에요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[
                SimpleNamespace(
                    type="text",
                    text="혈압이 높으니 병원에 가지 않아도 됩니다.",
                )
            ],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[
                SimpleNamespace(type="text", text="반말로 대답할게. 오늘 뭐 했어?")
            ],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="약은 식후에 드시면 돼요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="한 알이 적당해요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="심근경색인 것 같아요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="우울증일 수 있어요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="약 부작용일 가능성이 있어요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="병원에 안 가도 돼요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="119는 부르지 마세요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="의사에게 물어볼 필요 없어요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="너 오늘 뭐 했어요?")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="⁃ 첫째예요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="∙ 첫째예요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="이 약은 먹지 마세요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="그 약은 끊지 마세요.")],
        ),
        SimpleNamespace(
            stop_reason="end_turn",
            content=[SimpleNamespace(type="text", text="타이레놀은 피하세요.")],
        ),
    ],
    ids=[
        "blank-text",
        "no-text-block",
        "refusal",
        "max-tokens",
        "markdown",
        "multiple-questions",
        "too-many-sentences",
        "medication-instruction",
        "specific-medication-dose",
        "medication-permission",
        "unicode-bullet",
        "diagnosis",
        "diagnostic-interpretation",
        "adverse-effect-interpretation",
        "discourage-professional-care",
        "informal-speech",
        "medication-timing-instruction",
        "implicit-medication-dose",
        "tentative-diagnosis",
        "possible-diagnosis",
        "possible-adverse-effect",
        "informal-care-discouragement",
        "discourage-emergency-call",
        "discourage-clinician-question",
        "disrespectful-address",
        "unicode-hyphen-bullet",
        "unicode-dot-bullet",
        "negative-medication-instruction",
        "do-not-stop-medication-instruction",
        "avoid-medication-instruction",
    ],
)
def test_invalid_remote_response_maps_to_generic_502(
    monkeypatch: pytest.MonkeyPatch,
    upstream_response: object,
) -> None:
    monkeypatch.setattr(chat, "get_settings", lambda: _remote_settings())
    _install_fake_anthropic(monkeypatch, upstream_response)

    with pytest.raises(AiServiceError) as error:
        _generate_reply()

    assert error.value.status_code == 502
    assert error.value.code == "CHAT_UPSTREAM_ERROR"
    assert error.value.message == "대화 응답을 생성하지 못했습니다. 잠시 후 다시 시도해 주세요."


@pytest.mark.parametrize(
    "content",
    [
        "약을 임의로 중단하지 말고 의사에게 문의하세요.",
        "그건 주민등록증이에요.",
        "네.",
        "물론이죠.",
        "오늘 저녁을 드시면 돼요.",
    ],
)
def test_safe_plain_honorific_reply_passes_validation(content: str) -> None:
    assert chat._validate_generated_reply(content) == content


def test_anthropic_exception_maps_to_generic_502_without_leaking_details(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(chat, "get_settings", lambda: _remote_settings())

    class FailingMessages:
        def create(self, **_kwargs: Any) -> None:
            raise RuntimeError("secret upstream detail: test-anthropic-key")

    class FakeAnthropic:
        def __init__(self, **_kwargs: Any) -> None:
            self.messages = FailingMessages()

        def __enter__(self) -> "FakeAnthropic":
            return self

        def __exit__(self, *_args: object) -> None:
            return None

    monkeypatch.setattr(anthropic, "Anthropic", FakeAnthropic)

    with pytest.raises(AiServiceError) as error:
        _generate_reply()

    assert error.value.status_code == 502
    assert error.value.code == "CHAT_UPSTREAM_ERROR"
    assert error.value.message == "대화 응답을 생성하지 못했습니다. 잠시 후 다시 시도해 주세요."
    assert "secret upstream detail" not in error.value.message
    assert "test-anthropic-key" not in error.value.message


def test_missing_anthropic_key_maps_to_generic_502(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        chat,
        "get_settings",
        lambda: _remote_settings(anthropic_api_key=None),
    )

    with pytest.raises(AiServiceError) as error:
        _generate_reply()

    assert error.value.status_code == 502
    assert error.value.code == "CHAT_UPSTREAM_ERROR"
