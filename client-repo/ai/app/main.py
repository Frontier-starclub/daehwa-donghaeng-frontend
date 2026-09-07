from fastapi import FastAPI

from app.config import get_settings
from app.errors import register_error_handlers
from app.routers import chat, drugs, dur, ocr

settings = get_settings()

app = FastAPI(
    title=settings.app_name,
    version="0.1.0",
    description=(
        "대화동행 AI 서비스. 백엔드(:8090)만 이 서비스를 호출하며 앱은 직접 호출하지 않는다. "
        "요청·응답 스키마는 백엔드 providers.py의 dataclass와 1:1로 대응한다."
    ),
)

register_error_handlers(app)


@app.get("/health/live", tags=["health"])
def liveness() -> dict[str, str]:
    return {"status": "ok", "provider_mode": settings.provider_mode}


app.include_router(ocr.router)
app.include_router(dur.router)
app.include_router(chat.router)
app.include_router(drugs.router)
