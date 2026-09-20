"""이미지·OCR provider 없이 실행하는 문자열 후처리 회귀 테스트."""

import json
import unicodedata
from pathlib import Path

import pytest

from app.ocr_postprocess import (
    normalize_dose_frequency,
    normalize_medication_name,
    validate_confidence,
)

_CASES_PATH = Path(__file__).resolve().parents[1] / "evals/ocr/normalization_cases.jsonl"
_CASES = [
    json.loads(line)
    for line in _CASES_PATH.read_text(encoding="utf-8").splitlines()
    if line.strip()
]


def _normalize_case(raw: dict) -> dict:
    # frequency_text는 fixture 내부 입력이며, 공개 API 모델에 추가하지 않는다.
    return {
        "name": normalize_medication_name(raw["name"]),
        "dose_frequency_per_day": normalize_dose_frequency(raw.get("frequency_text")),
    }


def test_jsonl_cases_are_well_formed() -> None:
    ids = [case["id"] for case in _CASES]
    assert _CASES
    assert len(ids) == len(set(ids))
    for case in _CASES:
        assert ("expected" in case) != ("expected_error" in case), case["id"]


@pytest.mark.parametrize("case", _CASES, ids=[case["id"] for case in _CASES])
def test_jsonl_case(case: dict) -> None:
    if "expected_error" in case:
        with pytest.raises(ValueError, match=case["expected_error"]):
            _normalize_case(case["raw"])
        return

    result = _normalize_case(case["raw"])
    assert result == case["expected"]
    assert normalize_medication_name(result["name"]) == result["name"]
    frequency = result["dose_frequency_per_day"]
    assert normalize_dose_frequency(frequency) == frequency


@pytest.mark.parametrize("value", [None, True, False, 3, 1.5, [], {}])
def test_name_rejects_non_strings(value: object) -> None:
    with pytest.raises(TypeError, match="name"):
        normalize_medication_name(value)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("예시약\t  A정\n500mg", "예시약 A정 500mg"),
        (" 예시약（서방정）　５／１０ｍｇ ", "예시약(서방정) 5/10mg"),
        ("예시약 0.5mg/mL + A-B (서방정) ²", "예시약 0.5mg/mL + A-B (서방정) ²"),
        ("약 A정", "약 A정"),
        ("아모잘탄졍", "아모잘탄졍"),
        ("가" * 100, "가" * 100),
        ("﻿예시약", "예시약"),
        ("예시약­정 ½정", "예시약정 ½정"),
        # 호환 단위와 라벨은 이번 범위에서 변환·제거하지 않는다.
        ("예시약정 500㎎", "예시약정 500㎎"),
        ("예시약정 500㎍", "예시약정 500㎍"),
        ("약품명: 예시약정", "약품명: 예시약정"),
    ],
)
def test_name_preserves_information(raw: str, expected: str) -> None:
    result = normalize_medication_name(raw)
    assert result == expected
    assert normalize_medication_name(result) == result


def test_name_composes_nfd_hangul() -> None:
    decomposed = unicodedata.normalize("NFD", "예시약정 500mg")
    assert decomposed != "예시약정 500mg"
    assert normalize_medication_name(decomposed) == "예시약정 500mg"


@pytest.mark.parametrize(
    "value",
    ["", "\t\n　", "가" * 101, "​", "﻿", "­", " ​﻿　 "],
)
def test_name_rejects_invalid_normalized_length(value: str) -> None:
    with pytest.raises(ValueError, match="name"):
        normalize_medication_name(value)


@pytest.mark.parametrize("value", [True, False, 2.0, 2.5, [], {}])
def test_frequency_rejects_invalid_types(value: object) -> None:
    with pytest.raises(TypeError, match="dose_frequency_per_day"):
        normalize_dose_frequency(value)


@pytest.mark.parametrize("count", range(1, 11))
def test_frequency_accepts_only_valid_integer_counts(count: int) -> None:
    assert normalize_dose_frequency(count) == count
    assert normalize_dose_frequency(f"1일 {count}회") == count


@pytest.mark.parametrize("value", [0, -1, 11, "1일 0회", "1일 11회", "하루 2.5회"])
def test_frequency_rejects_explicit_invalid_counts(value: str | int) -> None:
    with pytest.raises(ValueError, match="dose_frequency_per_day"):
        normalize_dose_frequency(value)


@pytest.mark.parametrize("value", ["1일-3회", "1일 - 3회", "하루 +2회", "하루 -1번", "1일 +3회"])
def test_frequency_does_not_read_signs(value: str) -> None:
    # +, -는 OCR 구분자일 수 있으므로 부호로 해석하거나 ValueError로 만들지 않는다.
    assert normalize_dose_frequency(value) is None


@pytest.mark.parametrize(
    "value",
    [
        None,
        "",
        "3",
        "격일",
        "식후 30분",
        "1회 2정",
        "1일 2~3회",
        "1일 2회~3회",
        "1일 2-3회",
        "1일 1/2회",
        "하루 최대 3회",
        "최대 1일 3회",
        "하루 3회 이하",
        "1일 3회 이상",
        "필요시 1일 3회",
        "1일 3회, 필요시 추가 1회",
        "격일, 1일 3회",
        "주 3회",
        "주3회",
        "매주 3회",
        "하루 3회, 매주 월요일",
        "주 3회, 1일 2회",
        "1주일에 2회, 1일 1회",
        "1일 3회 또는 2회",
        "1일 2회 또는 3회",
        "1일 2회 혹은 3회",
        "1일 2회, 증상에 따라 3회",
        "하루 세 번 또는 네 번",
        "하루 걸러 한 번",
        "1일 3회, 하루 2회",
        "1일 3회, 하루 2~3회",
        "11일 3회",
    ],
)
def test_frequency_does_not_guess(value: str | None) -> None:
    assert normalize_dose_frequency(value) is None


@pytest.mark.parametrize("value", ["매일 3회", "하루 3번씩"])
def test_frequency_unsupported_expressions_stay_none(value: str) -> None:
    # 지원 범위 확대는 실제 OCR 데이터 확보 후 결정한다.
    assert normalize_dose_frequency(value) is None


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("하루 2회", 2),
        ("하루 세 번", 3),
        ("하루에 한 번", 1),
        ("하루 열 번", 10),
        ("1일3회", 3),
        ("하루\t두\n번", 2),
        ("1일​3회", 3),
        ("1일 3회, 하루 세 번", 3),
        ("1일 3회 복용해 주세요", 3),
        ("1일 3회, 식후 30분 이내", 3),
        ("1일 3회, 1회 최대 2정", 3),
        ("65세 이상 1일 1회", 1),
        ("1회 2정, 1일 3회, 식후 30분", 3),
        ("2주간 1일 3회", 3),
        ("1일 3회 7일분", 3),
    ],
)
def test_frequency_equivalent_daily_expressions(value: str, expected: int) -> None:
    result = normalize_dose_frequency(value)
    assert result == expected
    assert normalize_dose_frequency(result) == result


@pytest.mark.parametrize("value", [None, 0, 1, 0.0, 1.0, 0.96])
def test_confidence_accepts_boundaries_and_unknown(value: int | float | None) -> None:
    result = validate_confidence(value)
    assert result == value
    assert validate_confidence(result) == result


@pytest.mark.parametrize("value", [True, False, "0.96", "96%", [], {}])
def test_confidence_rejects_invalid_types(value: object) -> None:
    with pytest.raises(TypeError, match="confidence"):
        validate_confidence(value)


@pytest.mark.parametrize("value", [-0.01, 1.01, 96, float("nan"), float("inf"), -float("inf")])
def test_confidence_rejects_invalid_range(value: int | float) -> None:
    with pytest.raises(ValueError, match="confidence"):
        validate_confidence(value)
