"""약봉투 OCR — 이미지에서 약 이름·용법을 추출한다.

Flowchart OCR-04 노드에 대응한다. 인식 결과는 사용자 확인(OCR-05)을 반드시 거치므로
이 엔드포인트는 판단하지 않고 읽은 것만 돌려준다.

담당: 이석윤 / Phase2-A (9/8~9/12)
"""

from typing import Annotated

from fastapi import APIRouter, File, UploadFile

from app.config import get_settings
from app.errors import AiServiceError
from app.schemas import MedicationItem, OcrOut

router = APIRouter(prefix="/v1/ocr", tags=["ocr"])

MAX_IMAGE_BYTES = 10 * 1024 * 1024
ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png"}

# 백엔드 MockOCRProvider와 같은 값 — mock 모드에서 양쪽 응답이 일치해야
# 어댑터 교체가 무해함을 확인할 수 있다.
_MOCK_ITEMS = [
    MedicationItem(name="아모잘탄정", dose_frequency_per_day=1, confidence=0.96),
    MedicationItem(name="메트포르민서방정", dose_frequency_per_day=2, confidence=0.93),
]


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

    # TODO(Phase2-A): Claude vision 호출로 교체.
    #   - app/clients/claude.py 의 recognize_label(contents) 사용
    #   - 프롬프트는 evals/ocr/ 평가셋으로 측정하며 조정
    #   - 인식 실패는 UpstreamError("OCR_UPSTREAM_ERROR", ...) 로 올린다
    raise AiServiceError(
        501, "NOT_IMPLEMENTED", "OCR provider가 아직 구현되지 않았습니다."
    )
