"""Private, bounded API; incoming image data is kept in memory only."""

import asyncio
import base64
import secrets
from contextlib import asynccontextmanager
from typing import Literal

from fastapi import FastAPI, HTTPException
from fastapi.exceptions import RequestValidationError
from pydantic import BaseModel, ConfigDict, Field
from starlette.responses import JSONResponse

from .config import Settings
from .images import InvalidImage, normalize_result, read_page
from .provider import AIProvider, OpenAIProvider, ProviderFailure, ProviderRefusal, ProviderTimeout, edit_prompt


class InputPage(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    image_base64: str = Field(min_length=4, max_length=16_777_216)
    mime_type: Literal["image/png", "image/jpeg", "image/webp"]
    glossary: str = Field(default="", max_length=12_000)
    source_language: str = Field(default="Japanese", min_length=1, max_length=64)
    target_language: str = Field(default="English", min_length=1, max_length=64)


class InpaintPage(InputPage):
    transcript: str = Field(min_length=1, max_length=40_000)


class TranscriptionResult(BaseModel):
    transcript: str


class InpaintResult(BaseModel):
    image_base64: str
    mime_type: Literal["image/png"] = "image/png"
    notes: list[str]


class PrivateRequestMiddleware:
    """Authenticate before buffering; cap both streamed and Content-Length bodies."""

    def __init__(self, app, settings: Settings):
        self.app = app
        self.settings = settings

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = dict(scope["headers"])
        if scope["path"] == "/health" or scope["path"].startswith("/v1/"):
            value = headers.get(b"authorization", b"")
            scheme, _, token = value.partition(b" ")
            if (scheme.lower() != b"bearer" or not secrets.compare_digest(
                    token, self.settings.service_token.encode("ascii"))):
                return await JSONResponse({"detail": "Invalid service token."}, status_code=401,
                                          headers={"WWW-Authenticate": "Bearer"})(scope, receive, send)
        if scope["method"] in {"POST", "PUT", "PATCH"}:
            try:
                if int(headers.get(b"content-length", b"0")) > self.settings.max_body_bytes:
                    raise OverflowError()
            except (ValueError, OverflowError):
                return await JSONResponse({"detail": "Request body is too large or invalid."},
                                          status_code=413)(scope, receive, send)
            chunks = []
            size = 0
            try:
                async with asyncio.timeout(self.settings.body_timeout_seconds):
                    while True:
                        message = await receive()
                        if message["type"] == "http.disconnect":
                            return
                        chunk = message.get("body", b"")
                        size += len(chunk)
                        if size > self.settings.max_body_bytes:
                            raise OverflowError()
                        chunks.append(chunk)
                        if not message.get("more_body", False):
                            break
            except OverflowError:
                return await JSONResponse({"detail": "Request body is too large."},
                                          status_code=413)(scope, receive, send)
            except TimeoutError:
                return await JSONResponse({"detail": "Request body timed out."},
                                          status_code=408)(scope, receive, send)
            body = b"".join(chunks)
            consumed = False

            async def bounded_receive():
                nonlocal consumed
                if not consumed:
                    consumed = True
                    return {"type": "http.request", "body": body, "more_body": False}
                return await receive()

            return await self.app(scope, bounded_receive, send)
        await self.app(scope, receive, send)


def create_app(settings: Settings | None = None, provider: AIProvider | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    ai = provider or (OpenAIProvider(settings) if settings.api_key else None)
    # One active paid operation per process. Run a single worker to preserve this bound.
    operation_lock = asyncio.Lock()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        yield
        if ai is not None:
            await ai.close()

    app = FastAPI(title="Ultimate Manga Tools private service", version="0.1.0", lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)
    app.add_middleware(PrivateRequestMiddleware, settings=settings)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, exc):
        # FastAPI's default includes rejected input; do not echo private page data.
        return JSONResponse({"detail": "Invalid request fields or unsupported image type."}, status_code=422)

    @app.get("/health")
    async def health():
        return {"status": "ok", "ai_configured": ai is not None}

    async def run_operation(payload: InputPage, inpaint: bool):
        if ai is None:
            raise HTTPException(503, "AI is not configured on this service.")
        if inpaint and len(edit_prompt(payload.source_language, payload.target_language,
                                       payload.glossary, payload.transcript)) > 32_000:
            raise HTTPException(422, "The transcript and glossary are too long together for image editing. Shorten them before retrying.")
        if operation_lock.locked():
            raise HTTPException(429, "Another page is being processed. Try again after it finishes.")
        async with operation_lock:
            try:
                # Bounds are checked before decompression and before any paid call.
                page = read_page(payload.image_base64, payload.mime_type, settings)
            except InvalidImage as exc:
                raise HTTPException(400, str(exc)) from None
            try:
                async with asyncio.timeout(settings.request_timeout_seconds):
                    if inpaint:
                        output = await ai.inpaint(page, payload.source_language, payload.target_language,
                                                  payload.glossary, payload.transcript)
                        png, notes = normalize_result(output, page, settings)
                        return InpaintResult(image_base64=base64.b64encode(png).decode("ascii"), notes=notes)
                    transcript = await ai.transcribe(page, payload.source_language, payload.target_language,
                                                     payload.glossary)
                    if not isinstance(transcript, str) or not transcript.strip() or len(transcript) > 40_000:
                        raise ProviderFailure()
                    return TranscriptionResult(transcript=transcript)
            except ProviderRefusal:
                raise HTTPException(422, "The AI provider declined this page. No automatic retry was made.") from None
            except (ProviderTimeout, TimeoutError):
                raise HTTPException(504, "The AI request timed out. It may have been billed; check before retrying.") from None
            except (ProviderFailure, InvalidImage):
                raise HTTPException(502, "The AI provider could not return a valid result. No automatic retry was made.") from None
            except Exception:
                # Do not send/log upstream exception messages, credentials, or page data.
                raise HTTPException(502, "The AI request failed. No automatic retry was made.") from None

    @app.post("/v1/transcribe", response_model=TranscriptionResult)
    async def transcribe(payload: InputPage):
        return await run_operation(payload, False)

    @app.post("/v1/inpaint", response_model=InpaintResult)
    async def inpaint(payload: InpaintPage):
        return await run_operation(payload, True)

    return app
