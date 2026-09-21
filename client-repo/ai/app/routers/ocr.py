"""약봉투 OCR — 이미지에서 약 이름·용법을 추출한다.

Flowchart OCR-04 노드에 대응한다. 인식 결과는 사용자 확인(OCR-05)을 반드시 거치므로
이 엔드포인트는 판단하지 않고 읽은 것만 돌려준다.

담당: 이석윤 / Phase2-A (9/8~9/12)
"""

import base64
import logging
from collections.abc import Iterable, Mapping
from typing import Annotated, Any

from fastapi import APIRouter, File, UploadFile
from pydantic import BaseModel, Field, ValidationError

from app.config import get_settings
from app.errors import AiServiceError, UpstreamError
from app.ocr_postprocess import (
    normalize_dose_frequency,
    normalize_medication_name,
    validate_confidence,
)
from app.schemas import MedicationItem, OcrOut

router = APIRouter(prefix="/v1/ocr", tags=["ocr"])
logger = logging.getLogger(__name__)

MAX_IMAGE_BYTES = 10 * 1024 * 1024
ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png"}

# Anthropic의 이미지 제한은 전송되는 base64 문자열 기준 10MB(십진 단위)다.
# 원본 바이트 제한만 검사하면 약 7.15MiB부터 API가 400을 반환할 수 있다.
MAX_BASE64_IMAGE_BYTES = 10_000_000
_ANTHROPIC_TIMEOUT_SECONDS = 25.0
_ANTHROPIC_MAX_RETRIES = 0
_ANTHROPIC_MAX_TOKENS = 16_000

_OCR_SYSTEM_PROMPT = """당신은 약봉투 이미지의 글자를 그대로 옮기는 전사 도구입니다.
이미지에서 실제로 보이는 약 이름 표기와 그 약의 용법 문구 원문만 추출하세요.
일부만 보이는 약 이름을 지식으로 완성하거나 성분, 제품 코드, 복용 횟수를 추측하지 마세요.
약 이름을 확실히 읽을 수 없는 행은 제외하세요. 약이 하나도 보이지 않으면 빈 목록을 반환하세요.
"""

_OCR_USER_PROMPT = """이 약봉투에서 약별로 다음 두 값만 옮겨 적으세요.
- name: 봉투에 보이는 약 이름 표기. 확실히 읽을 수 없으면 해당 약을 제외합니다.
- frequency_text: 해당 약의 용법 문구 원문. 보이지 않으면 null입니다.
같은 이름이 여러 행에 실제로 적혀 있다면 행을 합치지 마세요.
"""


class _ExtractedMedication(BaseModel):
    """Claude 구조화 출력용 모델. 공개 API 모델과 의도적으로 분리한다."""

    name: str | None = Field(description="이미지에 보이는 약 이름 표기 원문")
    frequency_text: str | None = Field(description="이미지에 보이는 용법 문구 원문")


class _OcrExtraction(BaseModel):
    items: list[_ExtractedMedication]


# 백엔드 MockOCRProvider와 같은 값 — mock 모드에서 양쪽 응답이 일치해야
# 어댑터 교체가 무해함을 확인할 수 있다.
_MOCK_ITEMS = [
    MedicationItem(name="아모잘탄정", dose_frequency_per_day=1, confidence=0.96),
    MedicationItem(name="메트포르민서방정", dose_frequency_per_day=2, confidence=0.93),
]


def _encoded_size(raw_size: int) -> int:
    """base64 인코딩 뒤 패딩을 포함한 정확한 바이트 수를 계산한다."""
    return 4 * ((raw_size + 2) // 3)


def _field(value: object, name: str, default: Any = None) -> Any:
    if isinstance(value, Mapping):
        return value.get(name, default)
    return getattr(value, name, default)


def _postprocess_items(extracted: Iterable[object]) -> list[MedicationItem]:
    """추출 항목을 공개 계약으로 바꾸되 한 항목의 오류를 전체 실패로 만들지 않는다."""
    if isinstance(extracted, (str, bytes, Mapping)) or not isinstance(extracted, Iterable):
        raise TypeError("OCR extraction items must be an iterable of item objects")

    items: list[MedicationItem] = []
    input_count = 0
    excluded_name_count = 0
    frequency_none_count = 0
    confidence_none_count = 0

    for raw in extracted:
        input_count += 1
        try:
            name = normalize_medication_name(_field(raw, "name"))
        except (TypeError, ValueError):
            excluded_name_count += 1
            continue

        try:
            frequency = normalize_dose_frequency(_field(raw, "frequency_text"))
        except (TypeError, ValueError):
            frequency = None
        if frequency is None:
            frequency_none_count += 1

        # 현재 Claude 추출 스키마에는 confidence가 없다. 그래도 후처리 경계는 가짜
        # 추출기나 향후 provider가 넘긴 값을 검증하고, 백분율 같은 값은 추정 변환하지 않는다.
        try:
            confidence = validate_confidence(_field(raw, "confidence"))
        except (TypeError, ValueError):
            confidence = None
        if confidence is None:
            confidence_none_count += 1

        items.append(
            MedicationItem(
                name=name,
                ingredient_name=None,
                ingredient_code=None,
                item_seq=None,
                dose_frequency_per_day=frequency,
                confidence=confidence,
            )
        )

    logger.info(
        "OCR postprocess input=%d output=%d excluded_name=%d frequency_none=%d "
        "confidence_none=%d",
        input_count,
        len(items),
        excluded_name_count,
        frequency_none_count,
        confidence_none_count,
    )
    return items


def _parse_claude_message(message: object) -> _OcrExtraction:
    """thinking 블록을 건너뛰고 구조화된 text 블록만 안전하게 꺼낸다."""
    if _field(message, "stop_reason") != "end_turn":
        raise ValueError("Claude OCR response did not finish with end_turn")

    content = _field(message, "content")
    if not isinstance(content, list):
        raise ValueError("Claude OCR response has no content list")

    text_validation_error: ValidationError | None = None
    for block in content:
        if _field(block, "type") != "text":
            continue

        parsed = _field(block, "parsed_output")
        if parsed is not None:
            return _OcrExtraction.model_validate(parsed)

        text = _field(block, "text")
        if isinstance(text, str) and text.strip():
            try:
                return _OcrExtraction.model_validate_json(text)
            except ValidationError as exc:
                text_validation_error = exc

    if text_validation_error is not None:
        raise ValueError("Claude OCR structured output did not match its schema") from (
            text_validation_error
        )
    raise ValueError("Claude OCR response has no parsed text output")


def _new_anthropic_client(api_key: str) -> Any:
    """SDK는 mock 모드와 모듈 import 시에는 필요하지 않도록 지연 import한다."""
    from anthropic import AsyncAnthropic

    return AsyncAnthropic(
        api_key=api_key,
        timeout=_ANTHROPIC_TIMEOUT_SECONDS,
        max_retries=_ANTHROPIC_MAX_RETRIES,
    )


async def _request_extraction(
    contents: bytes,
    media_type: str,
    *,
    api_key: str,
    model: str,
) -> _OcrExtraction:
    encoded_image = base64.b64encode(contents).decode("ascii")

    async with _new_anthropic_client(api_key) as client:
        message = await client.messages.parse(
            model=model,
            max_tokens=_ANTHROPIC_MAX_TOKENS,
            system=_OCR_SYSTEM_PROMPT,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": media_type,
                                "data": encoded_image,
                            },
                        },
                        {"type": "text", "text": _OCR_USER_PROMPT},
                    ],
                }
            ],
            output_format=_OcrExtraction,
            output_config={"effort": "low"},
        )

    return _parse_claude_message(message)


@router.post("/prescription-label", response_model=OcrOut)
async def recognize_prescription_label(
    image: Annotated[UploadFile, File()],
) -> OcrOut:
    if image.content_type not in ALLOWED_IMAGE_TYPES:
        raise AiServiceError(415, "UNSUPPORTED_IMAGE", "JPEG 또는 PNG만 처리합니다.")

    contents = await image.read(MAX_IMAGE_BYTES + 1)
    if len(contents) > MAX_IMAGE_BYTES:
        raise AiServiceError(413, "IMAGE_TOO_LARGE", "이미지는 10MiB 이하여야 합니다.")

    if get_settings().is_mock:
        return OcrOut(items=_MOCK_ITEMS)

    if _encoded_size(len(contents)) > MAX_BASE64_IMAGE_BYTES:
        raise AiServiceError(
            413,
            "IMAGE_TOO_LARGE",
            "base64 인코딩 후 이미지는 10MB 이하여야 합니다.",
        )

    settings = get_settings()
    try:
        if not settings.anthropic_api_key:
            raise ValueError("ANTHROPIC_API_KEY is not configured")
        extracted = await _request_extraction(
            contents,
            image.content_type,
            api_key=settings.anthropic_api_key,
            model=settings.ocr_model,
        )
        return OcrOut(items=_postprocess_items(extracted.items))
    except Exception as exc:
        # 응답 본문이나 약 이름이 로그에 섞이지 않도록 예외 형식만 기록한다.
        logger.warning("OCR upstream failure type=%s", type(exc).__name__)
        raise UpstreamError(
            "OCR_UPSTREAM_ERROR", "약봉투 인식 서비스 호출에 실패했습니다."
        ) from exc
