import asyncio
import base64
import io
from dataclasses import replace

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from umt_server.app import create_app
from umt_server.config import Settings
from umt_server.images import read_page
from umt_server.provider import ProviderFailure, ProviderRefusal, ProviderTimeout


TOKEN = "test-only-service-token-never-a-real-credential"
SETTINGS = Settings(service_token=TOKEN)
HEADERS = {"Authorization": f"Bearer {TOKEN}"}


def fixture_image(size=(16, 24), fmt="PNG", **save_options):
    stream = io.BytesIO()
    Image.new("RGB", size, "white").save(stream, format=fmt, **save_options)
    return base64.b64encode(stream.getvalue()).decode("ascii")


def payload(**changes):
    return {"image_base64": fixture_image(), "mime_type": "image/png", **changes}


class FakeProvider:
    def __init__(self, *, failure=None, image=None):
        self.failure = failure
        self.image = image or fixture_image()
        self.calls = []
        self.closed = False

    async def transcribe(self, page, source, target, glossary):
        self.calls.append(("transcribe", page, source, target, glossary))
        if self.failure:
            raise self.failure
        return "Panel 1, top right: こんにちは → Hello."

    async def inpaint(self, page, source, target, glossary, transcript):
        self.calls.append(("inpaint", page, source, target, glossary, transcript))
        if self.failure:
            raise self.failure
        return self.image

    async def close(self):
        self.closed = True


def client(provider=None, settings=SETTINGS):
    return TestClient(create_app(settings, provider))


def test_missing_token_fails_closed():
    with pytest.raises(ValueError, match="UMT_SERVICE_TOKEN"):
        Settings(service_token="")
    with pytest.raises(ValueError, match="UMT_SERVICE_TOKEN"):
        Settings(service_token="x" * 31)


def test_secrets_not_in_config_repr():
    configured = replace(SETTINGS, api_key="secret-provider-key")
    assert TOKEN not in repr(configured)
    assert "secret-provider-key" not in repr(configured)


def test_health_without_provider_and_ai_disabled():
    with client() as session:
        assert session.get("/health", headers=HEADERS).json() == {"status": "ok", "ai_configured": False}
        assert session.get("/health").status_code == 401
        assert session.get("/health", headers={"Authorization": "Bearer wrong"}).status_code == 401
        assert session.post("/v1/transcribe", json=payload(), headers=HEADERS).status_code == 503
        assert session.get("/docs").status_code == 404


@pytest.mark.parametrize("auth", [None, "Bearer wrong", f"Basic {TOKEN}"])
def test_authorization_precedes_body_processing(auth):
    provider = FakeProvider()
    with client(provider) as session:
        result = session.post("/v1/transcribe", content="not-json",
                              headers={"Authorization": auth} if auth else {})
    assert result.status_code == 401
    assert provider.calls == []


def test_transcribe_calls_once_and_preserves_parameters():
    provider = FakeProvider()
    with client(provider) as session:
        assert session.get("/health", headers=HEADERS).json()["ai_configured"] is True
        response = session.post("/v1/transcribe", headers=HEADERS,
                                json=payload(glossary="太郎 = Taro", source_language="Japanese",
                                             target_language="English"))
    assert response.status_code == 200
    assert "Hello" in response.json()["transcript"]
    assert len(provider.calls) == 1
    assert provider.calls[0][2:] == ("Japanese", "English", "太郎 = Taro")
    assert provider.closed is True


@pytest.mark.parametrize("changes,expected", [
    ({"image_base64": "not base64"}, 400),
    ({"image_base64": base64.b64encode(b"not an image").decode()}, 400),
    ({"mime_type": "image/jpeg"}, 400),
    ({"mime_type": "text/plain"}, 422),
    ({"glossary": "x" * 12_001}, 422),
    ({"source_language": " "}, 422),
    ({"unknown": "private input must not be echoed"}, 422),
])
def test_invalid_inputs_never_call_provider_or_echo_input(changes, expected):
    provider = FakeProvider()
    with client(provider) as session:
        response = session.post("/v1/transcribe", json=payload(**changes), headers=HEADERS)
    assert response.status_code == expected
    assert "private input" not in response.text
    assert len(response.content) < 200
    assert provider.calls == []


def test_decoded_byte_and_pixel_limits():
    provider = FakeProvider()
    with client(provider, replace(SETTINGS, max_image_bytes=10)) as session:
        assert session.post("/v1/transcribe", json=payload(), headers=HEADERS).status_code == 400
    with client(provider, replace(SETTINGS, max_pixels=100)) as session:
        assert session.post("/v1/transcribe", json=payload(), headers=HEADERS).status_code == 400
    assert provider.calls == []


def test_content_length_limit_before_json_parse():
    provider = FakeProvider()
    with client(provider, replace(SETTINGS, max_body_bytes=10)) as session:
        response = session.post("/v1/transcribe", content=b"x" * 11, headers=HEADERS)
    assert response.status_code == 413
    assert provider.calls == []


def test_chunked_request_limit_without_content_length():
    async def execute():
        provider = FakeProvider()
        app = create_app(replace(SETTINGS, max_body_bytes=10), provider)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as session:
            async def chunks():
                yield b"abcdef"
                yield b"ghijkl"
            response = await session.post("/v1/transcribe", content=chunks(), headers=HEADERS)
            assert response.status_code == 413
            assert provider.calls == []
    asyncio.run(execute())


def test_animated_input_is_rejected():
    stream = io.BytesIO()
    Image.new("RGB", (8, 8), "white").save(stream, format="PNG", save_all=True,
                                         append_images=[Image.new("RGB", (8, 8), "black")])
    provider = FakeProvider()
    with client(provider) as session:
        response = session.post("/v1/transcribe", headers=HEADERS,
                                json=payload(image_base64=base64.b64encode(stream.getvalue()).decode()))
    assert response.status_code == 400
    assert provider.calls == []


def test_orientation_is_normalized_and_metadata_removed():
    exif = Image.Exif()
    exif[274] = 6
    exif[315] = "private author"
    page = read_page(fixture_image((16, 24), "JPEG", exif=exif), "image/jpeg", SETTINGS)
    assert (page.width, page.height) == (24, 16)
    assert page.mime_type == "image/png"
    with Image.open(io.BytesIO(page.data)) as image:
        assert not image.getexif()
        assert not image.info


def test_inpaint_normalizes_image_and_reports_resize():
    provider = FakeProvider(image=fixture_image((8, 12), "JPEG"))
    with client(provider) as session:
        response = session.post("/v1/inpaint", json=payload(transcript="Panel 1: Hello."), headers=HEADERS)
    assert response.status_code == 200
    result = response.json()
    assert result["mime_type"] == "image/png"
    assert any("resized" in note for note in result["notes"])
    with Image.open(io.BytesIO(base64.b64decode(result["image_base64"]))) as image:
        assert image.format == "PNG"
        assert image.size == (16, 24)
    assert len(provider.calls) == 1
    assert provider.calls[0][-1] == "Panel 1: Hello."


def test_inpaint_does_not_report_resize_when_dimensions_match():
    with client(FakeProvider()) as session:
        result = session.post("/v1/inpaint", json=payload(transcript="Hello"), headers=HEADERS).json()
    assert not any("resized" in note for note in result["notes"])


def test_oversized_combined_edit_prompt_is_rejected_before_provider():
    provider = FakeProvider()
    with client(provider) as session:
        result = session.post("/v1/inpaint", json=payload(transcript="x" * 25_000,
                                                          glossary="y" * 10_000), headers=HEADERS)
    assert result.status_code == 422
    assert "too long together" in result.json()["detail"]
    assert provider.calls == []


@pytest.mark.parametrize("image", ["bad-provider-result", base64.b64encode(b"bad image").decode()])
def test_provider_invalid_image_is_not_returned(image):
    with client(FakeProvider(image=image)) as session:
        result = session.post("/v1/inpaint", json=payload(transcript="Hello"), headers=HEADERS)
    assert result.status_code == 502
    assert image not in result.text


@pytest.mark.parametrize("failure,status", [
    (ProviderRefusal(), 422), (ProviderFailure(), 502), (ProviderTimeout(), 504),
    (RuntimeError("provider-key-private-secret private-image-data"), 502),
])
def test_provider_failure_no_retries_or_secret_leaks(failure, status):
    provider = FakeProvider(failure=failure)
    with client(provider) as session:
        response = session.post("/v1/transcribe", json=payload(), headers=HEADERS)
    assert response.status_code == status
    assert "private-secret" not in response.text
    assert "private-image" not in response.text
    assert len(provider.calls) == 1


def test_concurrent_paid_operation_is_rejected():
    async def execute():
        started = asyncio.Event()
        release = asyncio.Event()

        class BlockingProvider(FakeProvider):
            async def transcribe(self, *args):
                started.set()
                await release.wait()
                return await super().transcribe(*args)

        provider = BlockingProvider()
        app = create_app(SETTINGS, provider)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as session:
            first = asyncio.create_task(session.post("/v1/transcribe", json=payload(), headers=HEADERS))
            await asyncio.wait_for(started.wait(), 2)
            second = await session.post("/v1/transcribe", json=payload(), headers=HEADERS)
            assert second.status_code == 429
            release.set()
            assert (await first).status_code == 200
            assert len(provider.calls) == 1
    asyncio.run(execute())


def test_total_timeout_releases_operation_lock():
    class SlowProvider(FakeProvider):
        async def transcribe(self, *args):
            await asyncio.sleep(2)

    with client(SlowProvider(), replace(SETTINGS, request_timeout_seconds=1)) as session:
        response = session.post("/v1/transcribe", json=payload(), headers=HEADERS)
    assert response.status_code == 504
    assert "billed" in response.json()["detail"]
