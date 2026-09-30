import asyncio
import base64
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest
from openai import APIStatusError

from umt_server.config import Settings
from umt_server.images import PageImage
from umt_server.provider import OpenAIProvider, ProviderFailure, ProviderRefusal


SETTINGS = Settings(service_token="test-only-service-token-never-a-real-credential", api_key="test-key")
PAGE = PageImage(b"fixture-only-bytes", "image/png", 16, 24)


def fake_sdk(monkeypatch):
    response = SimpleNamespace(output=[], output_text="A reviewed translation", status="completed")
    sdk = SimpleNamespace(responses=SimpleNamespace(create=AsyncMock(return_value=response)),
                          images=SimpleNamespace(edit=AsyncMock(return_value=SimpleNamespace(
                              data=[SimpleNamespace(b64_json=base64.b64encode(b"fixture").decode())]))),
                          close=AsyncMock())
    init_options = {}

    def factory(**options):
        init_options.update(options)
        return sdk

    monkeypatch.setattr("umt_server.provider.AsyncOpenAI", factory)
    return sdk, init_options


def test_sdk_configuration_disables_retries_and_pins_official_endpoint(monkeypatch):
    sdk, options = fake_sdk(monkeypatch)
    provider = OpenAIProvider(SETTINGS)
    assert options["max_retries"] == 0
    assert options["timeout"] == 180
    assert options["base_url"] == "https://api.openai.com/v1"
    assert asyncio.run(provider.transcribe(PAGE, "Japanese", "English", "name glossary")) == "A reviewed translation"
    args = sdk.responses.create.call_args.kwargs
    assert args["store"] is False
    assert args["model"] == "gpt-4.1"
    assert args["input"][0]["content"][1]["type"] == "input_image"
    assert args["input"][0]["content"][1]["image_url"].startswith("data:image/png;base64,")
    assert "ILLEGIBLE" in args["instructions"]
    assert sdk.responses.create.await_count == 1


def test_edit_uses_image_api_and_only_documented_parameters(monkeypatch):
    sdk, _ = fake_sdk(monkeypatch)
    provider = OpenAIProvider(SETTINGS)
    result = asyncio.run(provider.inpaint(PAGE, "Japanese", "English", "names", "Panel 1: Hello"))
    assert base64.b64decode(result) == b"fixture"
    args = sdk.images.edit.call_args.kwargs
    assert set(args) == {"model", "image", "prompt"}
    assert args["model"] == "gpt-image-2"
    assert args["image"] == ("page.png", PAGE.data, "image/png")
    assert "Panel 1: Hello" in args["prompt"]
    assert sdk.images.edit.await_count == 1


def test_explicit_response_refusal_is_not_returned_as_translation(monkeypatch):
    sdk, _ = fake_sdk(monkeypatch)
    sdk.responses.create.return_value = SimpleNamespace(
        output=[SimpleNamespace(content=[SimpleNamespace(type="refusal")])],
        output_text="", status="completed")
    with pytest.raises(ProviderRefusal):
        asyncio.run(OpenAIProvider(SETTINGS).transcribe(PAGE, "Japanese", "English", ""))
    assert sdk.responses.create.await_count == 1


def test_content_policy_error_stops_without_retry(monkeypatch):
    sdk, _ = fake_sdk(monkeypatch)
    sdk.images.edit.side_effect = APIStatusError("sensitive upstream payload", response=httpx.Response(
        400, request=httpx.Request("POST", "https://api.openai.com/v1/images/edits")),
        body={"error": {"code": "content_policy_violation"}})
    with pytest.raises(ProviderRefusal) as error:
        asyncio.run(OpenAIProvider(SETTINGS).inpaint(PAGE, "Japanese", "English", "", "text"))
    assert "sensitive" not in str(error.value)
    assert sdk.images.edit.await_count == 1


def test_incomplete_transcript_is_not_presented_as_finished(monkeypatch):
    sdk, _ = fake_sdk(monkeypatch)
    sdk.responses.create.return_value.status = "incomplete"
    with pytest.raises(ProviderFailure):
        asyncio.run(OpenAIProvider(SETTINGS).transcribe(PAGE, "Japanese", "English", ""))
