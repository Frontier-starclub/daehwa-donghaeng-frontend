"""AI 서비스 요청·응답 스키마.

필드는 백엔드 `apps/backend/app/providers.py`의 dataclass와 1:1로 대응한다.
이 대응이 깨지면 백엔드 어댑터에 변환 로직이 생기므로 변경 시 양쪽을 함께 수정한다.

- MedicationItem      <-> RecognizedMedication
- MedicationForCheck  <-> MedicationForCheck
- DurWarning          <-> DurProviderWarning
"""

from pydantic import BaseModel, Field


class MedicationItem(BaseModel):
    """OCR이 인식한 약 1건. 약 이름만 필수이고 나머지는 선택값이다."""

    name: str = Field(min_length=1, max_length=100)
    ingredient_name: str | None = Field(default=None, max_length=200)
    ingredient_code: str | None = Field(default=None, max_length=50)
    item_seq: str | None = Field(default=None, max_length=50)
    dose_frequency_per_day: int | None = Field(default=None, ge=1, le=10)
    confidence: float | None = Field(default=None, ge=0, le=1)


class OcrOut(BaseModel):
    items: list[MedicationItem]


class MedicationForCheck(BaseModel):
    id: str
    name: str
    ingredient_code: str | None = None
    item_seq: str | None = None


class DurCheckIn(BaseModel):
    medications: list[MedicationForCheck] = Field(min_length=1, max_length=30)


class DurWarning(BaseModel):
    warning_type: str = Field(max_length=40)
    medication_ids: list[str]
    message: str
    source_code: str | None = Field(default=None, max_length=50)


class DurCheckOut(BaseModel):
    warnings: list[DurWarning]


class ChatReplyIn(BaseModel):
    opening: bool = False
    user_message_count: int = Field(default=0, ge=0)
    content: str = Field(default="", max_length=2000)


class ChatReplyOut(BaseModel):
    content: str


class DrugResolveIn(BaseModel):
    names: list[str] = Field(min_length=1, max_length=30)


class DrugMatch(BaseModel):
    name: str
    item_seq: str | None = None
    ingredient_code: str | None = None
    confidence: float = Field(ge=0, le=1)


class DrugResolveOut(BaseModel):
    matches: list[DrugMatch]


class ErrorBody(BaseModel):
    code: str
    message: str
