"""Bounded still-image decoding; originals never leave memory or change."""

import io
import warnings

from PIL import Image, ImageOps, UnidentifiedImageError
from pillow_heif import register_heif_opener

MAX_BYTES = 20 * 1024 * 1024
MAX_PIXELS = 32_000_000
Image.MAX_IMAGE_PIXELS = MAX_PIXELS
register_heif_opener(decode_threads=1, thumbnails=False, depth_images=False, aux_images=False)


class ImageRejected(ValueError):
    """A stable, media-independent rejection reason safe to return to the caller."""


def _check_heif_container(data):
    # libheif exposes image items, not timed tracks. Do not silently use a still
    # preview from a sequence, even if its primary image looks decodable.
    offset = 0
    while offset < len(data):
        if len(data) - offset < 8:
            raise ImageRejected("corrupt_image")
        length = int.from_bytes(data[offset : offset + 4], "big")
        kind = data[offset + 4 : offset + 8]
        header = 8
        if length == 1:
            if len(data) - offset < 16:
                raise ImageRejected("corrupt_image")
            length = int.from_bytes(data[offset + 8 : offset + 16], "big")
            header = 16
        elif length == 0:
            length = len(data) - offset
        if length < header or length > len(data) - offset:
            raise ImageRejected("corrupt_image")
        if offset == 0:
            brands = data[header : offset + length]
            if kind != b"ftyp" or len(brands) < 8 or len(brands) % 4:
                raise ImageRejected("corrupt_image")
            brands = {brands[:4], *(brands[i : i + 4] for i in range(8, len(brands), 4))}
            if brands & {b"msf1", b"hevc", b"hevx", b"hevm", b"hevs", b"avis"}:
                raise ImageRejected("unsupported_sequence")
            if brands & {b"heim", b"heis", b"avif"} or not brands & {b"heic", b"heix"}:
                raise ImageRejected("unsupported_image")
        if offset and kind == b"ftyp":
            raise ImageRejected("corrupt_image")
        if kind in (b"moov", b"moof", b"styp"):
            raise ImageRejected("unsupported_sequence")
        offset += length


def decode_rgb(data):
    if not data or len(data) > MAX_BYTES:
        raise ImageRejected("payload_limit")
    if data[4:8] == b"ftyp":
        _check_heif_container(data)
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            original = Image.open(io.BytesIO(data))
        with original:
            if original.format not in ("JPEG", "PNG", "WEBP", "HEIF"):
                raise ImageRejected("unsupported_image")
            if original.width * original.height > MAX_PIXELS:
                raise ImageRejected("pixel_limit")
            if getattr(original, "n_frames", 1) != 1:
                raise ImageRejected("animated_image")
            # libheif applies HEIF irot/imir; the plugin clears descriptive EXIF
            # orientation so this cannot rotate HEIF twice. Other formats retain
            # their existing EXIF/RGB path, including no ICC-to-sRGB transform.
            image = ImageOps.exif_transpose(original).convert("RGB")
            if image.width * image.height > MAX_PIXELS:
                raise ImageRejected("pixel_limit")
            return image
    except ImageRejected:
        raise
    except (Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise ImageRejected("pixel_limit") from None
    except UnidentifiedImageError:
        raise ImageRejected("corrupt_image") from None
    except (OSError, ValueError, SyntaxError, RuntimeError, EOFError):
        raise ImageRejected("corrupt_image") from None
