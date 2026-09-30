"""Configuration deliberately fails closed when service authentication is absent."""

import os
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Settings:
    service_token: str = field(repr=False)
    api_key: str = field(default="", repr=False)
    transcript_model: str = "gpt-4.1"
    image_model: str = "gpt-image-2"
    request_timeout_seconds: float = 180
    body_timeout_seconds: float = 15
    max_image_bytes: int = 12 * 1024 * 1024
    max_output_bytes: int = 32 * 1024 * 1024
    max_pixels: int = 20_000_000
    max_dimension: int = 12_000
    max_body_bytes: int = 17 * 1024 * 1024

    def __post_init__(self) -> None:
        if (not 32 <= len(self.service_token) <= 512
                or not self.service_token.isascii()
                or any(char.isspace() for char in self.service_token)):
            raise ValueError("UMT_SERVICE_TOKEN must be 32–512 ASCII characters without spaces.")
        if not 1 <= self.request_timeout_seconds <= 300:
            raise ValueError("UMT_REQUEST_TIMEOUT_SECONDS must be between 1 and 300.")
        if not self.transcript_model.strip() or not self.image_model.strip():
            raise ValueError("Model names must not be empty.")

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            service_token=os.environ.get("UMT_SERVICE_TOKEN", ""),
            api_key=os.environ.get("OPENAI_API_KEY", "").strip(),
            transcript_model=os.environ.get("UMT_TRANSCRIPT_MODEL", "gpt-4.1"),
            image_model=os.environ.get("UMT_IMAGE_MODEL", "gpt-image-2"),
            request_timeout_seconds=float(os.environ.get("UMT_REQUEST_TIMEOUT_SECONDS", "180")),
        )
