"""서비스 공통 예외와 핸들러.

백엔드는 이 서비스의 5xx를 `OCR_PROVIDER_ERROR` / `DUR_PROVIDER_ERROR`로 매핑한다.
따라서 실패는 반드시 5xx + {code, message} 형태로 나가야 한다.
"""

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse


class AiServiceError(Exception):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        self.status_code = status_code
        self.code = code
        self.message = message
        super().__init__(message)


class UpstreamError(AiServiceError):
    """외부 API(Claude, 식약처) 호출 실패."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(502, code, message)


def register_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(AiServiceError)
    async def handle_service_error(
        _request: Request, exc: AiServiceError
    ) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={"code": exc.code, "message": exc.message},
        )
