from pydantic import BaseSettings


class AppSettings(BaseSettings):
    TASK_SCHEDULER_BASE_LINK: str = ""
    ACTIVITIES_SERVICE_URL: str = ""
    SENTRY_DSN: str = ""

    class Config:
        env_file = ".env"

