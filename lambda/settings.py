from pydantic import BaseSettings

class AppSettings(BaseSettings):
    SENTRY_DSN: str = ""