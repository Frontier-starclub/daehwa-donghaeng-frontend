from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "대화동행 AI 서비스"
    app_env: str = "development"

    # "mock"이면 외부 API를 호출하지 않고 고정 응답을 돌려준다.
    # 백엔드의 PROVIDER_MODE와는 별개 값이다 — 이쪽은 이 서비스 내부의 외부 호출 여부.
    provider_mode: str = "mock"

    anthropic_api_key: str | None = None
    ocr_model: str = "claude-opus-5"

    data_go_kr_service_key: str | None = None
    mfds_base_url: str = "http://apis.data.go.kr/1471000"

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    @property
    def is_mock(self) -> bool:
        return self.provider_mode == "mock"


@lru_cache
def get_settings() -> Settings:
    return Settings()
