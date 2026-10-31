"""Disposable, bounded rendering process. Never writes or replaces an original."""

import base64
import hashlib
import io
import json
import sys

from PIL import Image

from decoder import ImageRejected, MAX_BYTES, decode_working_rgb

SIZES = (512, 1280, 2560)


def render(data):
    image, dimensions = decode_working_rgb(data, preview_side=max(SIZES))
    try:
        variants = {}
        for size in SIZES:
            with image.copy() as preview:
                preview.thumbnail((size, size), Image.Resampling.LANCZOS, reducing_gap=3.0)
                output = io.BytesIO()
                preview.save(output, format="JPEG", quality=85, optimize=True)
                variants[str(size)] = base64.b64encode(output.getvalue()).decode("ascii")
        return {
            "sourceSha256": hashlib.sha256(data).hexdigest(),
            "width": dimensions[0],
            "height": dimensions[1],
            "variants": variants,
        }
    finally:
        image.close()


if __name__ == "__main__":
    try:
        if sys.platform == "linux":
            import resource

            resource.setrlimit(resource.RLIMIT_CPU, (40, 40))
            resource.setrlimit(resource.RLIMIT_AS, (2 * 1024**3, 2 * 1024**3))
        print(json.dumps(render(sys.stdin.buffer.read(MAX_BYTES + 1)), allow_nan=False))
    except ImageRejected as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
    except Exception:
        print('{"error":"render_rejected"}')
        sys.exit(1)
