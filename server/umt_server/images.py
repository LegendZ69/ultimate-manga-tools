"""Bound and verify image inputs before any provider request."""

import base64
import binascii
import io
import warnings
from dataclasses import dataclass

from PIL import Image, ImageOps, UnidentifiedImageError

from .config import Settings


class InvalidImage(ValueError):
    pass


@dataclass(frozen=True)
class PageImage:
    data: bytes
    mime_type: str
    width: int
    height: int


FORMATS = {"PNG": "image/png", "JPEG": "image/jpeg", "WEBP": "image/webp"}


def decode_base64(value: str, max_bytes: int) -> bytes:
    if len(value) > ((max_bytes + 2) // 3) * 4:
        raise InvalidImage("Image exceeds the supported byte limit.")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise InvalidImage("Image must be valid base64 without a data-URL prefix.") from exc
    if not decoded or len(decoded) > max_bytes:
        raise InvalidImage("Image is empty or exceeds the supported byte limit.")
    return decoded


def inspect_image(data: bytes, settings: Settings, mime_type: str | None = None) -> Image.Image:
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as candidate:
                actual_type = FORMATS.get(candidate.format)
                if actual_type is None or (mime_type is not None and actual_type != mime_type):
                    raise InvalidImage("Image format must match PNG, JPEG, or WebP MIME type.")
                width, height = candidate.size
                if (width < 1 or height < 1 or width * height > settings.max_pixels
                        or max(width, height) > settings.max_dimension):
                    raise InvalidImage("Image dimensions exceed the supported limit.")
                if getattr(candidate, "n_frames", 1) != 1:
                    raise InvalidImage("Animated or multipage images are not supported.")
                candidate.verify()
            with Image.open(io.BytesIO(data)) as candidate:
                candidate.load()
                # Strip EXIF and metadata, and normalize orientation before uploading.
                normalized = ImageOps.exif_transpose(candidate)
                return normalized.convert("RGBA" if "A" in normalized.getbands() else "RGB")
    except InvalidImage:
        raise
    except (UnidentifiedImageError, OSError, ValueError, SyntaxError,
            Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
        raise InvalidImage("Image cannot be decoded safely.") from exc


def encode_png(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    # Construct a fresh image so original metadata is never forwarded.
    clean = Image.new(image.mode, image.size)
    clean.paste(image)
    clean.save(buffer, format="PNG")
    return buffer.getvalue()


def read_page(value: str, mime_type: str, settings: Settings) -> PageImage:
    data = decode_base64(value, settings.max_image_bytes)
    normalized = inspect_image(data, settings, mime_type)
    png = encode_png(normalized)
    if len(png) > settings.max_output_bytes:
        raise InvalidImage("Normalized image exceeds the supported byte limit.")
    return PageImage(png, "image/png", *normalized.size)


def normalize_result(value: str, original: PageImage, settings: Settings) -> tuple[bytes, list[str]]:
    data = decode_base64(value, settings.max_output_bytes)
    image = inspect_image(data, settings)
    notes = ["AI edits may alter lettering or artwork. Review the page before export."]
    original_size = (original.width, original.height)
    if image.size != original_size:
        image = image.resize(original_size, Image.Resampling.LANCZOS)
        notes.append("The provider changed the page size; the result was resized to the original dimensions.")
    png = encode_png(image)
    if len(png) > settings.max_output_bytes:
        raise InvalidImage("Edited image exceeds the supported byte limit.")
    return png, notes
