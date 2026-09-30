# Private AI service

This optional Python service provides page transcription/translation and image editing to the Flutter app. The OpenAI credential stays in the service environment. The app receives only a separate service token and sends a page when the user explicitly requests an AI action. Local imports, manual edits, review, and CBZ export do not require this service.

## Run locally

Python 3.11 or newer is required. From the repository root:

```sh
python -m venv .venv
source .venv/bin/activate
python -m pip install -e './server[test]'
```

Supply these environment variables through your shell or secret manager before starting:

| Variable | Purpose |
| --- | --- |
| `UMT_SERVICE_TOKEN` | Required, unique random secret of 32–512 ASCII characters with no whitespace. Configure the same value in the app's service settings. |
| `OPENAI_API_KEY` | Optional server-only OpenAI credential. Without it, health checks work but AI operations return 503. |
| `UMT_TRANSCRIPT_MODEL` | Defaults to `gpt-4.1`; must support Responses image input. |
| `UMT_IMAGE_MODEL` | Defaults to `gpt-image-2`; must support Images edits. |
| `UMT_REQUEST_TIMEOUT_SECONDS` | Provider deadline, 1–300 seconds; defaults to 180. |

`.env.example` documents the variables; the service does not automatically load `.env` files. Never commit real credentials or put the provider key into the app.

```sh
umt-server
```

The listener binds to `http://127.0.0.1:8787`, with one worker and no access logging. Missing or weak service-token configuration prevents startup. When using the app on a different device, provide a private HTTPS reverse proxy or tunnel to this listener. Keep the backend private, restrict who can reach it, enforce upload/request limits at the proxy, and use a secret manager. Plain HTTP is only appropriate for loopback development. Do not expose Uvicorn directly to the public internet. The app's connection URL must be reachable from the device; the phone's localhost is not your computer.

## API

`GET /health` returns `{"status":"ok","ai_configured":true}`. This and all `/v1/*` requests require `Authorization: Bearer <service-token>`; testing the connection also verifies the app's token.

`POST /v1/transcribe` accepts JSON with:

| Field | Type / limit |
| --- | --- |
| `image_base64` | Raw base64, no data-URL prefix; maximum decoded input 12 MiB. |
| `mime_type` | `image/png`, `image/jpeg`, or `image/webp`; must match the decoded image. |
| `source_language` | String, default `Japanese`, 64 characters maximum. |
| `target_language` | String, default `English`, 64 characters maximum. |
| `glossary` | Optional string, 12,000 characters maximum. |

It returns `{"transcript":"..."}`. The user should inspect and correct this text before requesting an edit.

`POST /v1/inpaint` accepts those same fields plus `transcript` (nonempty, at most 40,000 characters), and returns `{"image_base64":"...","mime_type":"image/png","notes":["..."]}`. The assembled edit prompt must fit the provider's 32,000-character limit; an overlong transcript/glossary combination is rejected before any paid request. Output is a validated PNG at the original, orientation-corrected page dimensions. A note reports any resizing of the provider output. AI editing may alter artwork or miss text; user review is still required before export. It does not offer pixel-perfect or deterministic inpainting.

Errors return `{"detail":"..."}` with status 400 (image validation), 401 (authentication), 408/413 (upload timeout/size), 422 (request validation or provider refusal), 429 (another operation is active), 502 (provider failure or invalid output), 503 (no provider configured), or 504 (provider timeout). A timeout may still be billed by the provider. The service never retries automatically and never switches providers or models to evade a refusal.

## Bounds and data handling

- One active AI operation per process; run only one worker to keep that bound. Each successful endpoint invocation makes at most one provider request.
- The service checks streamed body size (17 MiB), input bytes, actual image format, frame count, maximum edge (12,000 pixels), and total pixels (20 million) before provider calls. Animated images are rejected. Provider image output is also decoded and bounded.
- EXIF and other image metadata are stripped before upload. Images and transcripts stay in service memory and are not saved to disk or deliberately logged. OpenAI processes the submitted content under its API data policies; this is not an offline translator. Responses requests use `store=False`.
- Errors do not echo credentials, request bodies, or provider error payloads. API docs are disabled and no permissive CORS policy is installed.
- Translation prompts identify dialogue, labels, and sound effects, retain glossary names, mark uncertainty, and request narrow omissions where permitted. Provider safety refusals are surfaced to the user.

## Tests

```sh
python -m pytest server/tests -q
```

The tests use generated geometric fixtures and mocked providers. They do not submit any image to OpenAI or exercise paid AI output quality. End-to-end quality and account/model access still require a separately configured real service and an explicit user-requested operation.

The implementation follows the official [Responses image-input guide](https://developers.openai.com/api/docs/guides/images-vision), [image-editing guide](https://developers.openai.com/api/docs/guides/image-generation), [GPT-4.1 model reference](https://developers.openai.com/api/docs/models/gpt-4.1), and [GPT Image 2 model reference](https://developers.openai.com/api/docs/models/gpt-image-2). Model availability and API billing depend on the service operator's account.
