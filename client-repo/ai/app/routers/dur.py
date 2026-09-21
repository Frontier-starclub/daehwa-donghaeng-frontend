"""식약처 DUR 병용금기 조회와 요청 약 쌍 판정."""

from __future__ import annotations

import logging
import re
from collections.abc import Sequence

from fastapi import APIRouter

from app.clients.mfds import (
    DurEvidence,
    DurProfile,
    MedicationDurLookup,
    MedicationLookupStatus,
    MedicationQuery,
    MfdsClient,
    get_mfds_client,
)
from app.config import get_settings
from app.errors import UpstreamError
from app.schemas import DurCheckIn, DurCheckOut, DurWarning, MedicationForCheck

router = APIRouter(prefix="/v1/dur", tags=["dur"])
logger = logging.getLogger(__name__)

_DUR_ERROR_MESSAGE = "식약처 의약품 정보를 확인하지 못했습니다. 잠시 후 다시 시도해 주세요."
_UNVERIFIED_NOT_FOUND = "식약처 목록에서 이 약 이름을 찾지 못해 확인하지 못했습니다."
_UNVERIFIED_TOO_BROAD = "약 이름이 너무 포괄적이어서 식약처 정보를 확인하지 못했습니다."
_FALLBACK_PROHIBITION = "함께 복용하면 안 되는 조합으로 등재되어 있습니다."

# 이름 뒤의 함량만 제거한다. 중간의 숫자나 약 이름 자체는 바꾸지 않는다.
_DOSE_TAIL = re.compile(
    r"""
    \s*
    \d+(?:[.,]\d+)?(?:\s*/\s*\d+(?:[.,]\d+)?)*
    \s*(?:밀리그램|마이크로그램|밀리리터|그램|mg|mcg|[μµ]g|ug|ml|g|iu|%|㎎)
    (?:
        \s*/\s*\d+(?:[.,]\d+)?
        \s*(?:밀리그램|마이크로그램|밀리리터|그램|mg|mcg|[μµ]g|ug|ml|g|iu|%|㎎)
    )?
    \s*$
    """,
    re.IGNORECASE | re.VERBOSE,
)
_PARENTHETICAL_TAIL = re.compile(r"\s*[\(\[\{（].*$")
_FORMULATION_WORDS = (
    "구강붕해정",
    "필름코팅정",
    "연질캡슐",
    "경질캡슐",
    "서방정",
    "장용정",
    "현탁액",
    "점안액",
    "흡입액",
    "발포정",
    "캡슐",
    "시럽",
    "과립",
    "크림",
    "연고",
    "패치",
    "주사",
    "정",
    "액",
    "산",
)


@router.post("/check", response_model=DurCheckOut)
def check_interactions(payload: DurCheckIn) -> DurCheckOut:
    settings = get_settings()
    if settings.is_mock:
        # 백엔드 MockDURProvider와 동일한 계약을 유지한다.
        if len(payload.medications) >= 2:
            return DurCheckOut(
                warnings=[
                    DurWarning(
                        warning_type="demo_warning",
                        medication_ids=[
                            payload.medications[0].id,
                            payload.medications[1].id,
                        ],
                        message="시연용 주의사항입니다. 실제 의약 정보가 아닙니다.",
                        source_code="MOCK-001",
                    )
                ]
            )
        return DurCheckOut(warnings=[])

    # 비교할 쌍이 없으므로 외부 API나 키가 없어도 안전하게 빈 결과를 낼 수 있다.
    if len(payload.medications) < 2:
        return DurCheckOut(warnings=[])

    try:
        return _check_remote(payload.medications, get_mfds_client())
    except UpstreamError:
        raise
    except Exception as exc:
        # 예외 문자열에는 외부 요청 URL이나 사용자 약 이름이 들어갈 수 있어 기록하지 않는다.
        logger.error("DUR response processing failed (%s)", type(exc).__name__)
        raise UpstreamError("DUR_UPSTREAM_ERROR", _DUR_ERROR_MESSAGE) from None


def _check_remote(
    medications: Sequence[MedicationForCheck],
    client: MfdsClient,
) -> DurCheckOut:
    results: list[MedicationDurLookup | None] = [None] * len(medications)
    query_positions: list[int] = []
    queries: list[MedicationQuery] = []

    for index, medication in enumerate(medications):
        item_seq = medication.item_seq.strip() if medication.item_seq else ""
        if item_seq:
            query = MedicationQuery.by_item_seq(item_seq)
        else:
            candidates = _name_candidates(medication.name)
            if not candidates:
                continue
            query = MedicationQuery.by_name_candidates(*candidates)
        query_positions.append(index)
        queries.append(query)

    looked_up = client.lookup_many(queries)
    if len(looked_up) != len(query_positions):
        raise ValueError("MFDS result count does not match request")
    for position, result in zip(query_positions, looked_up, strict=True):
        results[position] = result

    warnings: list[DurWarning] = []
    for medication, result in zip(medications, results, strict=True):
        if result is None or result.status is MedicationLookupStatus.NOT_FOUND:
            warnings.append(_unverified_warning(medication, _UNVERIFIED_NOT_FOUND))
        elif result.status is MedicationLookupStatus.TOO_BROAD:
            warnings.append(_unverified_warning(medication, _UNVERIFIED_TOO_BROAD))
        elif result.status is not MedicationLookupStatus.VERIFIED or result.profile is None:
            raise ValueError("MFDS returned an invalid medication lookup")

    for left_index, left_medication in enumerate(medications):
        left = results[left_index]
        if left is None or left.status is not MedicationLookupStatus.VERIFIED:
            continue
        assert left.profile is not None
        for right_index in range(left_index + 1, len(medications)):
            right = results[right_index]
            if right is None or right.status is not MedicationLookupStatus.VERIFIED:
                continue
            assert right.profile is not None
            evidence = _pair_evidence(left.profile, right.profile)
            if not evidence:
                continue
            warnings.append(
                _interaction_warning(
                    left_medication,
                    medications[right_index],
                    evidence,
                )
            )

    return DurCheckOut(warnings=warnings)


def _name_candidates(name: str) -> tuple[str, ...]:
    """Build conservative MFDS partial-name queries from the stored display name."""

    if not isinstance(name, str):
        return ()
    raw = name.strip()
    if not raw:
        return ()
    normalized = " ".join(raw.split())

    without_parenthetical = _PARENTHETICAL_TAIL.sub("", normalized).strip()
    without_dose = _DOSE_TAIL.sub("", without_parenthetical).strip()
    stem = _formulation_stem(without_dose)
    if len(stem.replace(" ", "")) <= 2:
        return ()

    candidates: list[str] = []

    def add(candidate: str) -> None:
        cleaned = candidate.strip(" ,;/")
        if len(cleaned.replace(" ", "")) <= 2 or cleaned in candidates:
            return
        candidates.append(cleaned)

    add(raw)
    add(normalized)
    add(without_parenthetical)
    add(without_dose)
    add(stem)

    return tuple(candidates)


def _formulation_stem(value: str) -> str:
    """Trim text after a dosage-form word without cutting a brand such as 정로환."""

    valid_ends: list[int] = []
    for formulation in _FORMULATION_WORDS:
        for match in re.finditer(re.escape(formulation), value):
            remainder = value[match.end() :]
            if not remainder or re.match(r"^[\s\d\(\[\{（,;/]", remainder):
                valid_ends.append(match.end())
    return value[: max(valid_ends)] if valid_ends else value


def _pair_evidence(left: DurProfile, right: DurProfile) -> tuple[DurEvidence, ...]:
    evidence: dict[tuple[str, str | None], DurEvidence] = {}
    for ingredient_code in right.ingredient_codes:
        for item in left.evidence_for(ingredient_code):
            evidence[(item.dur_seq, item.prohibition_content)] = item
    for ingredient_code in left.ingredient_codes:
        for item in right.evidence_for(ingredient_code):
            evidence[(item.dur_seq, item.prohibition_content)] = item

    def order(item: DurEvidence) -> tuple[int, str]:
        if not item.dur_seq.isdigit():
            raise ValueError("MFDS DUR_SEQ is not numeric")
        return int(item.dur_seq), item.prohibition_content or ""

    return tuple(sorted(evidence.values(), key=order))


def _interaction_warning(
    left: MedicationForCheck,
    right: MedicationForCheck,
    evidence: Sequence[DurEvidence],
) -> DurWarning:
    contents: list[str] = []
    for item in evidence:
        if item.prohibition_content is None:
            continue
        content = " ".join(item.prohibition_content.split())
        if content and content not in contents:
            contents.append(content)

    names = sorted((left.name.strip(), right.name.strip()))
    reason = " ".join(contents) if contents else _FALLBACK_PROHIBITION
    message = f"{names[0]} / {names[1]}: {reason}"
    source_code = min(evidence, key=lambda item: int(item.dur_seq)).dur_seq
    if len(source_code) > 50:
        raise ValueError("MFDS DUR_SEQ is too long")
    return DurWarning(
        warning_type="usjnt_taboo",
        medication_ids=[left.id, right.id],
        message=message,
        source_code=source_code,
    )


def _unverified_warning(
    medication: MedicationForCheck,
    reason: str,
) -> DurWarning:
    display_name = medication.name.strip() or "해당 약"
    return DurWarning(
        warning_type="unverified",
        medication_ids=[medication.id],
        message=f"{display_name}: {reason}",
        source_code=None,
    )
