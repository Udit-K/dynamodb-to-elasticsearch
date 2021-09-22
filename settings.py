from pydantic import BaseSettings

class AppSettings(BaseSettings):
    SENTRY_DSN: str = ""

    class Config:
        env_file = ".env"