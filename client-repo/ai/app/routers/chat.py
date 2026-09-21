"""말벗 대화 응답 생성.

Flowchart FC-04에 대응한다. 음성은 앱에서 STT/TTS로 처리하므로 이 서비스는 텍스트만 다룬다
(백엔드 `docs/chat-session.md` 계약 — 음성 파일은 서버로 오지 않는다).

세션 상태·메시지 순서·멱등성은 백엔드가 관리한다. 이 엔드포인트는 상태를 갖지 않는다.

담당: 정진수 / Phase2-B (9/13~9/16)
"""

import re
import unicodedata

from fastapi import APIRouter

from app.config import get_settings
from app.errors import UpstreamError
from app.schemas import ChatReplyIn, ChatReplyOut

router = APIRouter(prefix="/v1/chat", tags=["chat"])

_MOCK_OPENING = "오늘 하루 어떻게 보내셨어요?"
_MOCK_REPLIES = (
    "그랬군요. 오늘 그중에서 가장 기억에 남은 일은 무엇이었나요?",
    "말씀해 주셔서 고마워요. 그때 기분은 어떠셨어요?",
    "천천히 들려주셔도 괜찮아요. 조금 더 이야기해 주시겠어요?",
)

_REMOTE_OPENING = "안녕하세요. 오늘은 어떻게 지내고 계세요?"

_SYSTEM_PROMPT = """당신은 고령 사용자의 이야기를 편안하게 들어 주는 말벗입니다.
사용자의 현재 발화에만 답하고, 알 수 없는 이전 대화를 기억하는 것처럼 말하지 마세요.

반드시 다음 규칙을 지키세요.
- 따뜻하고 차분한 존댓말로 답하며 재촉하지 마세요.
- 답변은 평문 1~3문장으로만 쓰세요. 마크다운, 목록, 이모지, 괄호 설명을 쓰지 마세요.
- 질문은 답변 전체에서 최대 1개만 하세요.
- 의료 진단, 증상 해석, 복용 여부·용량·중단·변경 같은 복약 지시는 하지 마세요.
- 흉통, 호흡곤란, 과다복용 등 급한 신체 증상에는 짧게 공감한 뒤 119에 연락하거나
  가까운 가족에게 바로 알리고 의사 또는 약사에게 도움을 요청하라고 안내하세요.
- 자해나 자살을 암시하면 짧게 공감하고, 즉시 119 또는 자살예방상담전화 109에 연락하며
  가까운 가족이나 믿을 수 있는 사람에게 알리도록 안내하세요.
"""

_CHAT_ERROR_CODE = "CHAT_UPSTREAM_ERROR"
_CHAT_ERROR_MESSAGE = "대화 응답을 생성하지 못했습니다. 잠시 후 다시 시도해 주세요."

_SELF_HARM = re.compile(
    r"자살|자해|죽고\s*싶(?!지)|죽을래|죽어\s*버릴|살고\s*싶지"
    r"|목숨을\s*끊|극단적\s*선택|없어지고\s*싶"
)
_CHEST_EMERGENCY = re.compile(
    r"흉통(?:이|을)?\s*(?:있|왔|느껴|심해)"
    r"|가슴(?:이|에)?\s*.{0,8}(?:아프(?!지)|조여|쥐어짜)"
    r"|가슴(?:이|에)?\s*.{0,8}통증(?:이|을)?\s*(?:있|왔|느껴|심해|생겨)"
)
_BREATHING_EMERGENCY = re.compile(
    r"호흡(?:이)?\s*곤란(?:이\s*(?:있|왔|와|느껴|심해)"
    r"|을\s*(?:느껴|겪고)|해|이에요|입니다|이야|이야요)"
    r"|숨(?:이|을)?\s*.{0,6}(?:안\s*쉬|못\s*쉬|쉬기\s*힘|막혀|가빠)"
)
_MEDICATION_CONTEXT = re.compile(
    r"(?:이|그)?\s*약(?:을|은|이|도|과|만)?(?=\s|$)|복용|처방|용량"
    r"|수면제|진통제|항생제|혈압약|당뇨약|감기약|타이레놀|아스피린"
    r"|와파린|리피토|메트포르민"
    r"|[0-9A-Za-z가-힣]{3,}(?:프릴|사르탄|스타틴|피린|졸|롤|민|린|펠|신|람|탄|틴)"
    r"|[0-9A-Za-z가-힣]{2,}(?:정|캡슐|시럽|주사|연고|패치)"
)
_OVERDOSE = re.compile(
    r"과다\s*복용(?:을\s*)?(?:했|해\s*버|한\s*것\s*같|하고\s*난)"
    r"|(?:약|수면제|진통제|항생제|타이레놀|아스피린).{0,20}"
    r"(?:너무\s*많이|한꺼번에|여러\s*(?:알|정)|"
    r"(?:[1-9]\d+|열|스무|서른|마흔|쉰|예순|일흔|여든|아흔)\s*(?:알|정))"
    r".{0,10}(?:먹|복용)"
)
_MEDICATION_ADVICE_CUE = re.compile(
    r"언제.{0,10}(?:먹|복용|드셔)|몇\s*(?:알|정)"
    r"|(?:먹|복용|드셔).{0,8}(?:어야|해도|어도|을까|좋을까)"
    r"|(?:먹|복용하|드)(?:나요|는지|을까요|면\s*되나요)"
    r"|같이\s*(?:먹|복용)"
    r"|(?:끊|중단|늘리|줄이|바꾸|변경).{0,8}"
    r"(?:해도|할까|해야|하면|돼|될까)|용량|복용\s*(?:시간|횟수)"
    r"|식전|식후|공복|취침\s*전"
)
_MEDICATION_DIRECTIVE = re.compile(
    r"(?:먹으|드|복용하)세요"
    r"|(?:먹어|드셔|복용해)도\s*(?:됩니다|돼요|괜찮아요)"
    r"|(?:끊으|중단하|늘리|줄이|바꾸|변경하)세요"
    r"|(?:끊어|중단해|늘려|줄여|바꿔|변경해)\s*주세요"
    r"|(?:먹으면|드시면|복용하면)\s*(?:돼요|됩니다|좋아요|괜찮아요)"
    r"|(?:식전|식후|공복|취침\s*전).{0,12}(?:먹|드|복용)"
    r"|하루.{0,10}(?:\d+|한|두|세|네|다섯|여섯|일곱|여덟|아홉)\s*(?:알|정)"
    r"|(?:\d+|한|두|세|네|다섯|여섯|일곱|여덟|아홉)\s*(?:알|정)(?:이|을)?"
    r".{0,8}(?:적당|드세요|먹으세요|복용하세요)"
    r"|(?:먹|드시|복용하|끊|중단하|거르)지\s*마세요"
    r"|피하세요|거르세요"
)
_IMPLICIT_MEDICATION_CONTEXT = re.compile(
    r"식전|식후|공복|취침\s*전"
    r"|(?:\d+|한|두|세|네|다섯|여섯|일곱|여덟|아홉)\s*(?:알|정)"
)
_DIAGNOSTIC_CLAIM = re.compile(
    r"(?P<condition>(?:우울증|치매|감기|독감|폐렴|심근경색|뇌졸중|고혈압|저혈압"
    r"|당뇨|공황장애|[0-9A-Za-z가-힣]+(?:염|암|증|병|장애|경색|질환)))"
    r"(?:입니다|이에요|예요|으로\s*(?:보입니다|판단됩니다|의심됩니다)"
    r"|(?:인|일)\s*(?:것\s*)?(?:같아요|수\s*있어요)"
    r"|(?:일\s*)?가능성이?\s*있어요)"
)
_NON_MEDICAL_JEUNG_TERMS = (
    "등록증",
    "신분증",
    "면허증",
    "학생증",
    "영수증",
    "보증",
    "인증",
    "검증",
)
_ADVERSE_EFFECT_CLAIM = re.compile(
    r"(?:약|복용).{0,12}부작용"
    r"(?:입니다|이에요|예요|으로\s*보입니다"
    r"|일\s*(?:것\s*)?(?:같아요|수\s*있어요)"
    r"|일\s*가능성이?\s*있어요)"
)
_CARE_DISCOURAGEMENT = re.compile(
    r"(?:병원|응급실|의사|약사|119).{0,20}(?:"
    r"안\s*(?:가|찾|연락|부르|문의|물어)"
    r"|(?:가지|찾지|연락하지|부르지|문의하지|물어보지)\s*"
    r"(?:않아도|말아도|않으셔도)"
    r"|(?:갈|찾을|연락할|부를|문의할|물어볼)\s*필요(?:가)?\s*없"
    r"|(?:가|찾|연락하|부르|문의하|물어보)지\s*마)"
)
_MARKDOWN = re.compile(
    r"[`*_#>]|\[[^\]]+\]\([^\)]+\)|^\s*(?:\d+[.)]|[-+])\s|[•‣⁃∙◦▪▫●○]"
)
_DISRESPECTFUL_ADDRESS = re.compile(
    r"(?:^|\s)(?:너|너는|넌|너를|널|네가|니가)(?:\s|[,.!?。！？]|$)"
)


def _safety_reply(user_content: str) -> str | None:
    """Handle explicit crisis and medication-advice requests deterministically."""

    compact = " ".join(user_content.split())
    if _SELF_HARM.search(compact):
        return (
            "많이 힘드신 상황으로 들려요. 지금 바로 119나 자살예방상담전화 109에 "
            "연락하고 가까운 가족이나 믿을 수 있는 분께 알려 주세요."
        )
    if (
        _CHEST_EMERGENCY.search(compact)
        or _BREATHING_EMERGENCY.search(compact)
        or _OVERDOSE.search(compact)
    ):
        return (
            "많이 불편하고 걱정되시겠어요. 지금 바로 119에 연락하거나 가까운 가족에게 "
            "알리고 의사 또는 약사에게 도움을 요청해 주세요."
        )
    if _MEDICATION_CONTEXT.search(compact) and _MEDICATION_ADVICE_CUE.search(compact):
        return "복약 방법은 제가 판단해 드릴 수 없어요. 처방한 의사나 약사에게 확인해 주세요."
    return None


def _contains_diagnostic_claim(reply: str) -> bool:
    for match in _DIAGNOSTIC_CLAIM.finditer(reply):
        condition = match.group("condition")
        if condition.endswith("증") and any(
            term in condition for term in _NON_MEDICAL_JEUNG_TERMS
        ):
            continue
        return True
    return _ADVERSE_EFFECT_CLAIM.search(reply) is not None


def _validate_generated_reply(content: str) -> str:
    """Enforce the TTS and safety constraints that cannot rely on prompting alone."""

    reply = content.strip()
    if not reply or len(reply) > 500 or "\n" in reply or "\r" in reply:
        raise ValueError("chat response has an invalid length or line break")
    if _MARKDOWN.search(reply) or any(char in reply for char in "()[]{}（）"):
        raise ValueError("chat response is not plain text")
    if any(unicodedata.category(char) in {"So", "Sk"} for char in reply):
        raise ValueError("chat response contains emoji or symbols")
    if reply.count("?") + reply.count("？") > 1:
        raise ValueError("chat response contains too many questions")
    sentences = [
        part.strip() for part in re.split(r"[.!?。！？]+", reply) if part.strip()
    ]
    if not 1 <= len(sentences) <= 3:
        raise ValueError("chat response must contain one to three sentences")
    if _MEDICATION_DIRECTIVE.search(reply) and (
        _MEDICATION_CONTEXT.search(reply) or _IMPLICIT_MEDICATION_CONTEXT.search(reply)
    ):
        raise ValueError("chat response contains medication instructions")
    if _contains_diagnostic_claim(reply):
        raise ValueError("chat response contains a diagnostic claim")
    if _CARE_DISCOURAGEMENT.search(reply):
        raise ValueError("chat response discourages professional care")
    if _DISRESPECTFUL_ADDRESS.search(reply):
        raise ValueError("chat response uses disrespectful address")
    if any(
        not re.search(r"(?:요|니다|세요|십시오|죠|네)$", sentence)
        for sentence in sentences
    ):
        raise ValueError("chat response is not consistently honorific")
    return reply


def _extract_text(response: object) -> str:
    """완결된 Claude 응답에서 비어 있지 않은 text 블록만 읽는다."""

    if getattr(response, "stop_reason", None) != "end_turn":
        raise ValueError("chat response did not end normally")

    text_parts: list[str] = []
    for block in getattr(response, "content", ()):
        if getattr(block, "type", None) != "text":
            continue
        text = getattr(block, "text", None)
        if isinstance(text, str) and text.strip():
            text_parts.append(text.strip())

    return _validate_generated_reply(" ".join(text_parts))


@router.post("/reply", response_model=ChatReplyOut)
def generate_reply(payload: ChatReplyIn) -> ChatReplyOut:
    settings = get_settings()

    if settings.is_mock:
        if payload.opening:
            return ChatReplyOut(content=_MOCK_OPENING)
        index = (max(payload.user_message_count, 1) - 1) % len(_MOCK_REPLIES)
        return ChatReplyOut(content=_MOCK_REPLIES[index])

    if payload.opening:
        return ChatReplyOut(content=_REMOTE_OPENING)

    safe_reply = _safety_reply(payload.content)
    if safe_reply is not None:
        return ChatReplyOut(content=safe_reply)

    try:
        # mock 모드와 첫 인사는 SDK 설치·키 상태와 무관하게 동작해야 하므로 지연 import한다.
        from anthropic import Anthropic

        if not settings.anthropic_api_key:
            raise ValueError("ANTHROPIC_API_KEY is not configured")
        with Anthropic(
            api_key=settings.anthropic_api_key,
            timeout=25.0,
            max_retries=0,
        ) as client:
            response = client.messages.create(
                model=settings.chat_model,
                max_tokens=16_000,
                output_config={"effort": "low"},
                system=_SYSTEM_PROMPT,
                messages=[{"role": "user", "content": payload.content}],
            )
        return ChatReplyOut(content=_extract_text(response))
    except Exception:
        # 외부 오류의 원문에는 키·요청 정보가 포함될 수 있으므로 노출하거나 기록하지 않는다.
        raise UpstreamError(_CHAT_ERROR_CODE, _CHAT_ERROR_MESSAGE) from None
