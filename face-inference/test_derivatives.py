import base64
import hashlib
import io
from pathlib import Path
import unittest
import os
import runpy
from unittest.mock import Mock, patch

from PIL import Image, ImageCms
import numpy as np

from decoder import ANALYSIS_MAX_SIDE, ImageRejected, decode_working_rgb
from derivatives import SIZES, render
from infer import analyze

ROOT = Path(__file__).resolve().parent
LARGE = ROOT / "fixtures/heic/obama-2009-48mp.heic"


class DerivativeTests(unittest.TestCase):
    def test_display_profiles_are_converted_and_corrupt_profiles_rejected(self):
        profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
        for icc, valid in ((profile, True), (b"not a color profile", False)):
            output = io.BytesIO()
            Image.new("RGB", (40, 40), (200, 120, 40)).save(output, format="PNG", icc_profile=icc)
            if valid:
                response = render(output.getvalue())
                with Image.open(io.BytesIO(base64.b64decode(response["variants"]["512"]))) as preview:
                    for actual, expected in zip(preview.getpixel((20, 20)), (200, 120, 40)):
                        self.assertAlmostEqual(actual, expected, delta=3)
            else:
                with self.assertRaisesRegex(ImageRejected, "^unsupported_color_profile$"):
                    render(output.getvalue())

    def test_renderer_rejects_unauthorized_and_unbounded_input_before_child(self):
        with patch.dict(os.environ, {"DERIVATIVE_KEY": "k" * 32}), patch("http.server.ThreadingHTTPServer"):
            server = runpy.run_path(str(ROOT / "derivative_server.py"))
        for headers, expected in (
            ({"Content-Length": "4"}, 403),
            ({"X-Nephos-Service-Key": "k" * 32, "Content-Length": "999999999"}, 413),
            ({"X-Nephos-Service-Key": "k" * 32, "Content-Length": "4", "Transfer-Encoding": "chunked"}, 413),
        ):
            handler = object.__new__(server["Handler"])
            handler.connection = Mock()
            handler.path = "/render"
            handler.headers = headers
            handler.reply = Mock()
            with patch("subprocess.run") as child:
                handler.do_POST()
                child.assert_not_called()
            handler.reply.assert_called_once_with(expected, b"{}")

    def test_sizes_no_upscale_and_metadata_removed(self):
        encoded = io.BytesIO()
        image = Image.new("RGB", (800, 600), "red")
        exif = Image.Exif()
        exif[270] = "private metadata must not reach previews"
        image.save(encoded, format="JPEG", exif=exif)
        data = encoded.getvalue()
        result = render(data)
        self.assertEqual(hashlib.sha256(data).hexdigest(), result["sourceSha256"])
        self.assertEqual(set(map(str, SIZES)), set(result["variants"]))
        for size in SIZES:
            with Image.open(io.BytesIO(base64.b64decode(result["variants"][str(size)]))) as preview:
                self.assertEqual("JPEG", preview.format)
                self.assertLessEqual(max(preview.size), min(size, 800))
                self.assertNotIn(270, preview.getexif())

    @unittest.skipUnless(LARGE.exists(), "Generate 48MP HEIC fixture first")
    def test_large_original_uses_bounded_working_image_and_normalized_original_coordinates(self):
        data = LARGE.read_bytes()
        working, original = decode_working_rgb(data)
        self.assertEqual((6048, 8064), original)
        self.assertLessEqual(max(working.size), ANALYSIS_MAX_SIDE)
        working.close()
        result = analyze(data)
        baseline = analyze((ROOT / "fixtures/photos/obama-2009.jpg").read_bytes())
        self.assertEqual(original, (result["width"], result["height"]))
        self.assertEqual(1, len(result["faces"]))
        face = result["faces"][0]
        self.assertGreater(float(np.dot(face["embedding"], baseline["faces"][0]["embedding"])), 0.95)
        for field in ("x", "y", "width", "height"):
            self.assertAlmostEqual(face[field], baseline["faces"][0][field], delta=0.03)
        self.assertTrue(0 <= face["x"] * original[0] < original[0])
        self.assertTrue(0 <= face["y"] * original[1] < original[1])
        self.assertEqual(hashlib.sha256(data).hexdigest(), result["sourceSha256"])
        self.assertEqual(data, LARGE.read_bytes())
        previews = render(data)
        self.assertEqual(original, (previews["width"], previews["height"]))
        for size in SIZES:
            with Image.open(io.BytesIO(base64.b64decode(previews["variants"][str(size)]))) as image:
                self.assertEqual(size, max(image.size))
                self.assertLess(len(base64.b64decode(previews["variants"][str(size)])), len(data))


if __name__ == "__main__":
    unittest.main()
