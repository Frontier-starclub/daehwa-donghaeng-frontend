"""OCR 문자열을 정리하는 독립 순수 함수. 외부 API나 응답 스키마에 의존하지 않는다.

잘못된 입력 타입은 TypeError, 명확한 값의 계약 위반은 ValueError로 알린다.
알 수 없거나 모호한 복용 표현은 None이다. HTTP 오류 변환과 provider 연결은 호출자 몫이다.
약명에 들어 있는 함량·제형을 보존하며, 약명 교정이나 성분·식별자 추론은 하지 않는다.
"""

import re
import unicodedata

# 전체 NFKC 변환은 하지 않는다. 예: 함량의 위첨자 ²나 ㎎ 같은 호환 문자를 바꾸지 않는다.
_FULLWIDTH_ASCII = str.maketrans({code: code - 0xFEE0 for code in range(0xFF01, 0xFF5F)})
_KOREAN_COUNTS = {
    "한": 1,
    "두": 2,
    "세": 3,
    "네": 4,
    "다섯": 5,
    "여섯": 6,
    "일곱": 7,
    "여덟": 8,
    "아홉": 9,
    "열": 10,
}
_COUNT_WORD = "|".join(_KOREAN_COUNTS)
_DAILY_PREFIX = r"(?<![\w.+-])(?:1\s*일|하루(?:에)?)"
_DAILY_MARKER = re.compile(_DAILY_PREFIX)
# +, -는 OCR 구분자일 수 있으므로 숫자의 부호로 읽지 않는다.
_DAILY_COUNT = re.compile(
    _DAILY_PREFIX + rf"\s*(?P<count>[0-9]+(?:\.[0-9]+)?|{_COUNT_WORD})\s*(?:회|번)(?!\w)"
)
# 문장 안의 모든 'N회/N번'. 일일 표현이나 1회 투여량에 속하지 않으면 모호한 횟수로 본다.
_COUNT_TOKEN = re.compile(rf"(?:(?<![0-9.])[0-9]+|{_COUNT_WORD})\s*(?:회|번)")
# '1회 2정', '1회 최대 2정'처럼 1회 투여량을 뜻하는 '1회'.
_PER_DOSE = re.compile(
    rf"(?<![0-9.])1\s*회\s*(?:최대\s*)?(?:[0-9]+(?:[./][0-9]+)?|반|{_COUNT_WORD})\s*"
    r"(?:정|캡슐|알|포|mL|ml|방울)"
)
_VARIABLE_SCHEDULE = re.compile(
    r"필요\s*시|격\s*일|(?<!\w)매\s*주|[0-9]+\s*일\s*(?:마다|간격)"
    rf"|(?<!\w)(?:매\s*|[0-9]+\s*)?주(?:일)?(?:에|마다)?\s*(?:[0-9]+|{_COUNT_WORD})\s*(?:회|번|일)"
)
# 일일 횟수 바로 앞뒤에 붙어 횟수를 범위나 한도로 만드는 표현.
_COUNT_QUALIFIER_AFTER = re.compile(r"\s*(?:[~∼〜/–—-]|이하|이상|이내|미만|초과|까지)")
_COUNT_QUALIFIER_BEFORE = re.compile(r"(?:최대|최소)\s*$")


def _normalize_text(value: str) -> str:
    """보이지 않는 format 문자(Cf)를 지우고 NFC·전각 ASCII·공백을 통일한다."""
    visible = "".join(char for char in value if unicodedata.category(char) != "Cf")
    return " ".join(unicodedata.normalize("NFC", visible).translate(_FULLWIDTH_ASCII).split())


def normalize_medication_name(value: str) -> str:
    """표기를 정리한 1~100자 약명을 반환한다. 내부 공백·함량·제형은 삭제하지 않는다.

    '약품명:' 같은 라벨, bullet, ㎎ 같은 호환 단위는 제거하거나 변환하지 않는다.
    """
    if not isinstance(value, str):
        raise TypeError("name must be a string")
    name = _normalize_text(value)
    if not 1 <= len(name) <= 100:
        raise ValueError("name must contain 1 to 100 characters after normalization")
    return name


def _validate_daily_count(value: int) -> int:
    if not 1 <= value <= 10:
        raise ValueError("dose_frequency_per_day must be between 1 and 10")
    return value


def _is_covered(position: int, spans: list[tuple[int, int]]) -> bool:
    return any(start <= position < end for start, end in spans)


def normalize_dose_frequency(value: str | int | None) -> int | None:
    """명확한 '1일 N회/번', '하루 N회/번'만 1~10의 정수로 변환한다.

    N은 부호 없는 숫자 또는 한~열이다. 이미 정규화된 int도 허용하되 bool·float는 거부한다.
    +, -는 부호로 인정하지 않으므로 '1일-3회', '하루 +2회'는 None이다.
    다음은 틀린 값을 확정하지 않도록 None이다: 단독 숫자, 범위·한도('2~3회', '3회 이하'),
    필요시·격일·주 단위 일정, 서로 다른 일일 횟수, 일일 표현이나 '1회 N정' 밖에 남는
    별도의 N회/N번('1일 2회 혹은 3회').
    '1일 0회', '1일 11회', '하루 2.5회'처럼 명확히 적힌 잘못된 횟수는 ValueError다.
    이 함수는 일반 용법 문장 전체를 해석하는 자연어 파서가 아니다.
    """
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise TypeError("dose_frequency_per_day must be a string, an integer, or None")
    if isinstance(value, int):
        return _validate_daily_count(value)

    text = _normalize_text(value)
    if _VARIABLE_SCHEDULE.search(text):
        return None
    matches = list(_DAILY_COUNT.finditer(text))
    if not matches or len(matches) != len(_DAILY_MARKER.findall(text)):
        return None
    for match in matches:
        if _COUNT_QUALIFIER_AFTER.match(text, match.end()) or _COUNT_QUALIFIER_BEFORE.search(
            text, 0, match.start()
        ):
            return None

    covered = [match.span() for match in matches]
    covered += [dose.span() for dose in _PER_DOSE.finditer(text)]
    if any(not _is_covered(token.start(), covered) for token in _COUNT_TOKEN.finditer(text)):
        return None

    counts = set()
    for match in matches:
        token = match["count"]
        if "." in token:
            raise ValueError("dose_frequency_per_day must be a whole number")
        count = _KOREAN_COUNTS[token] if token in _KOREAN_COUNTS else int(token)
        counts.add(_validate_daily_count(count))
    return counts.pop() if len(counts) == 1 else None


def validate_confidence(value: int | float | None) -> float | None:
    """None 또는 유한한 0~1 값을 반환한다. bool·문자열·백분율을 추정 변환하지 않는다."""
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise TypeError("confidence must be a number or None")
    # NaN은 비교가 거짓이고 Infinity도 범위 밖이므로 둘 다 거부된다.
    if not 0 <= value <= 1:
        raise ValueError("confidence must be finite and between 0 and 1")
    return float(value)
