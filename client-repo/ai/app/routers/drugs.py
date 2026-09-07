"""약 이름 → 품목기준코드 매핑 (Blocker B).

OCR은 약 이름만 읽어내지만 DUR API는 품목기준코드(item_seq) 등 식별자를 요구한다.
그 사이를 메우는 것이 이 엔드포인트다. MVP에서 모델링 여지가 있는 유일한 지점이다.

출처 후보:
  - 의약품 낱알식별 정보  https://www.data.go.kr/data/15057639/openapi.do
  - 의약품개요정보(e약은요) https://www.data.go.kr/data/15075057/openapi.do

접근 순서: ① 정규화 후 완전일치 → ② 부분일치 → ③ 유사도 매칭.
①②로 충분한지를 먼저 측정하고, 부족할 때만 ③으로 넘어간다.

담당: 정진수 / Phase2-A (9/9)
"""

from fastapi import APIRouter

from app.config import get_settings
from app.errors import AiServiceError
from app.schemas import DrugMatch, DrugResolveIn, DrugResolveOut

router = APIRouter(prefix="/v1/drugs", tags=["drugs"])


@router.post("/resolve", response_model=DrugResolveOut)
def resolve_drug_names(payload: DrugResolveIn) -> DrugResolveOut:
    if get_settings().is_mock:
        return DrugResolveOut(
            matches=[
                DrugMatch(name=name, item_seq=None, ingredient_code=None, confidence=0.0)
                for name in payload.names
            ]
        )

    # TODO(Phase2-A): 매핑 구현.
    #   - 매칭 실패는 오류가 아니다. confidence=0.0 + item_seq=None 으로 돌려주고
    #     DUR 단계에서 "확인 불가"로 처리한다 (잘못된 매핑보다 안전하다).
    raise AiServiceError(
        501, "NOT_IMPLEMENTED", "약 이름 매핑이 아직 구현되지 않았습니다."
    )
