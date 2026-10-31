"""Bounded still-image decoding; originals never leave memory or change."""

import io
import warnings

from PIL import Image, ImageCms, ImageOps, UnidentifiedImageError
from pillow_heif import register_heif_opener

MAX_BYTES = 20 * 1024 * 1024
MAX_PIXELS = 64_000_000
LEGACY_PIXELS = 32_000_000
ANALYSIS_MAX_SIDE = 4096
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
    image, _ = decode_working_rgb(data)
    return image


def decode_working_rgb(data, preview_side=None):
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
            ImageOps.exif_transpose(original, in_place=True)
            dimensions = original.size
            if original.width * original.height > MAX_PIXELS:
                raise ImageRejected("pixel_limit")
            # Preserve existing embeddings for previously supported inputs. Larger
            # originals get a bounded alignment canvas before any NumPy/OpenCV copy.
            side = preview_side or (ANALYSIS_MAX_SIDE if original.width * original.height > LEGACY_PIXELS else None)
            if side is not None:
                original.thumbnail((side, side), Image.Resampling.LANCZOS, reducing_gap=3.0)
            if preview_side is not None and original.info.get("icc_profile"):
                try:
                    profile = ImageCms.ImageCmsProfile(io.BytesIO(original.info["icc_profile"]))
                    display = ImageCms.profileToProfile(
                        original, profile, ImageCms.createProfile("sRGB"), outputMode="RGB"
                    )
                except (ImageCms.PyCMSError, OSError, ValueError):
                    raise ImageRejected("unsupported_color_profile") from None
                return display, dimensions
            return original.convert("RGB"), dimensions
    except ImageRejected:
        raise
    except (Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise ImageRejected("pixel_limit") from None
    except UnidentifiedImageError:
        raise ImageRejected("corrupt_image") from None
    except (OSError, ValueError, SyntaxError, RuntimeError, EOFError):
        raise ImageRejected("corrupt_image") from None
