"""말벗 대화 응답 생성.

Flowchart FC-04에 대응한다. 음성은 앱에서 STT/TTS로 처리하므로 이 서비스는 텍스트만 다룬다
(백엔드 `docs/chat-session.md` 계약 — 음성 파일은 서버로 오지 않는다).

세션 상태·메시지 순서·멱등성은 백엔드가 관리한다. 이 엔드포인트는 상태를 갖지 않는다.

담당: 정진수 / Phase2-B (9/13~9/16)
"""

from fastapi import APIRouter

from app.config import get_settings
from app.errors import AiServiceError
from app.schemas import ChatReplyIn, ChatReplyOut

router = APIRouter(prefix="/v1/chat", tags=["chat"])

_MOCK_OPENING = "오늘 하루 어떻게 보내셨어요?"
_MOCK_REPLIES = (
    "그랬군요. 오늘 그중에서 가장 기억에 남은 일은 무엇이었나요?",
    "말씀해 주셔서 고마워요. 그때 기분은 어떠셨어요?",
    "천천히 들려주셔도 괜찮아요. 조금 더 이야기해 주시겠어요?",
)


@router.post("/reply", response_model=ChatReplyOut)
def generate_reply(payload: ChatReplyIn) -> ChatReplyOut:
    if get_settings().is_mock:
        if payload.opening:
            return ChatReplyOut(content=_MOCK_OPENING)
        index = (max(payload.user_message_count, 1) - 1) % len(_MOCK_REPLIES)
        return ChatReplyOut(content=_MOCK_REPLIES[index])

    # TODO(Phase2-B): LLM 호출로 교체.
    #   - 고령자 말벗 톤: 짧은 문장, 한 번에 질문 하나, 재촉하지 않기
    #   - 의학적 조언·진단으로 읽힐 표현 금지 (의료법 포지셔닝)
    #   - 백엔드가 대화 이력을 갖고 있으므로 필요하면 계약에 history 필드를 추가한다
    raise AiServiceError(
        501, "NOT_IMPLEMENTED", "Chat provider가 아직 구현되지 않았습니다."
    )
