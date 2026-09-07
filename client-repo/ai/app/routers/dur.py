"""DUR 상호작용 조회 — 식약처 공개 API로 병용금기·노인주의·효능군중복을 확인한다.

Flowchart FC-02에 대응한다. 진단이나 처방이 아니며, 결과 화면에는 백엔드가 내려주는
disclaimer("의사·약사 상담을 권고합니다")가 항상 함께 노출된다.

담당: 정진수 / Phase2-A (9/8~9/12)
선행: Blocker B — DUR API가 요구하는 식별자 실측 (9/8 스파이크)
"""

from fastapi import APIRouter

from app.config import get_settings
from app.errors import AiServiceError
from app.schemas import DurCheckIn, DurCheckOut, DurWarning

router = APIRouter(prefix="/v1/dur", tags=["dur"])


@router.post("/check", response_model=DurCheckOut)
def check_interactions(payload: DurCheckIn) -> DurCheckOut:
    if get_settings().is_mock:
        # 백엔드 MockDURProvider와 동일한 규칙: 약이 2개 이상이면 시연용 경고 1건.
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

    # TODO(Phase2-A): 식약처 DUR 품목정보 API 연동으로 교체.
    #   - app/clients/mfds.py 의 조회 함수 사용
    #   - item_seq 가 없는 약은 /v1/drugs/resolve 로 먼저 매핑 (Blocker B)
    #   - 조회 실패는 UpstreamError("DUR_UPSTREAM_ERROR", ...) 로 올린다
    raise AiServiceError(
        501, "NOT_IMPLEMENTED", "DUR provider가 아직 구현되지 않았습니다."
    )
