"""Real HEIF decoder and YuNet/SFace acceptance, with no fake face inference."""

import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import struct
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

import numpy as np
from PIL import Image

from decoder import ImageRejected, MAX_BYTES, MAX_PIXELS, decode_rgb
from infer import analyze

ROOT = Path(__file__).resolve().parent
FIXTURES = ROOT / "fixtures/heic"


class DecoderRejectionTests(unittest.TestCase):
    def test_payload_limit(self):
        for data in (b"", b"x" * (MAX_BYTES + 1)):
            with self.subTest(length=len(data)), self.assertRaisesRegex(ImageRejected, "^payload_limit$"):
                decode_rgb(data)

    def test_unsupported_format(self):
        image = io.BytesIO()
        Image.new("RGB", (20, 20)).save(image, format="BMP")
        with self.assertRaisesRegex(ImageRejected, "^unsupported_image$"):
            decode_rgb(image.getvalue())

    def test_corrupt_image(self):
        with self.assertRaisesRegex(ImageRejected, "^corrupt_image$"):
            decode_rgb(b"not an image")

    def test_isolated_http_timeout_remains_bounded(self):
        with patch.dict(os.environ, {"INFERENCE_KEY": "k" * 32}), patch("http.server.ThreadingHTTPServer"):
            server = runpy.run_path(str(ROOT / "server.py"))
        handler = object.__new__(server["Handler"])
        handler.connection = Mock()
        handler.path = "/infer"
        handler.headers = {"Content-Length": "4", "X-Nephos-Inference-Key": "k" * 32}
        handler.rfile = io.BytesIO(b"data")
        handler.reply = Mock()
        with patch("subprocess.run", side_effect=subprocess.TimeoutExpired("infer.py", 45)) as child:
            handler.do_POST()
        self.assertEqual(45, child.call_args.kwargs["timeout"])
        self.assertEqual(b"data", child.call_args.kwargs["input"])
        handler.connection.settimeout.assert_called_once_with(15)
        handler.reply.assert_called_once_with(422, b'{"error":"inference_timeout"}')


class PublicCameraFixtureTests(unittest.TestCase):
    @unittest.skipUnless(
        (ROOT / "fixtures/camera/iphone-12-pro-greyhounds.heic").exists(),
        "Run fixtures/download_camera.py for the optional public camera sample",
    )
    def test_exact_public_iphone_camera_sample(self):
        source = json.loads((ROOT / "fixtures/camera-source.json").read_text())
        path = ROOT / "fixtures/camera" / source["filename"]
        data = path.read_bytes()
        self.assertEqual(source["sha256"], hashlib.sha256(data).hexdigest())
        with Image.open(io.BytesIO(data)) as original:
            self.assertEqual("iPhone 12 Pro", original.getexif().get(272))
            self.assertEqual(8, original.info["original_orientation"])
            self.assertEqual(536, len(original.info["icc_profile"]))
            self.assertIn("tiling", original.info)
            expected = np.array(original.convert("RGB"))
        np.testing.assert_array_equal(expected, np.array(decode_rgb(data)))
        result = analyze(data)
        self.assertEqual((3024, 4032), (result["width"], result["height"]))
        self.assertEqual([], result["faces"])
        self.assertEqual(source["sha256"], result["sourceSha256"])
        self.assertEqual(data, path.read_bytes())


@unittest.skipUnless((FIXTURES / "provenance.json").exists(), "Run fixtures/generate_heic.py first")
class HeifDecoderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = (FIXTURES / "obama-2009.heic").read_bytes()

    def test_all_generated_portraits_have_real_faces_and_match_original(self):
        manifest = json.loads((FIXTURES / "provenance.json").read_text())
        sources = json.loads((ROOT / "fixtures/provenance.json").read_text())
        for source in sources:
            with self.subTest(source=source["id"]):
                path = FIXTURES / (source["id"] + ".heic")
                data = path.read_bytes()
                fixture = next(x for x in manifest["fixtures"] if x["id"] == source["id"])
                self.assertEqual(fixture["sha256"], hashlib.sha256(data).hexdigest())
                original = (ROOT / "fixtures/photos" / (source["id"] + ".jpg")).read_bytes()
                a, b = analyze(original), analyze(data)
                self.assertEqual((a["width"], a["height"]), (b["width"], b["height"]))
                self.assertEqual(1, len(a["faces"]))
                self.assertEqual(1, len(b["faces"]))
                va, vb = np.array(a["faces"][0]["embedding"]), np.array(b["faces"][0]["embedding"])
                self.assertEqual((128,), vb.shape)
                self.assertTrue(np.isfinite(vb).all())
                self.assertAlmostEqual(1, np.linalg.norm(vb), places=5)
                self.assertGreater(float(np.dot(va, vb)), 0.95)
                self.assertEqual(hashlib.sha256(data).hexdigest(), b["sourceSha256"])
                self.assertNotEqual(a["sourceSha256"], b["sourceSha256"])
                self.assertEqual(data, path.read_bytes())
                self.assertEqual("exif-normalized", b["coordinateSpace"])
                for field in ("x", "y", "width", "height"):
                    self.assertAlmostEqual(a["faces"][0][field], b["faces"][0][field], delta=0.01)

    def test_all_rotations_and_mirrors_are_applied_exactly_once(self):
        baseline = analyze((FIXTURES / "obama-2009-orientation-1.heic").read_bytes())
        for orientation in range(2, 9):
            with self.subTest(orientation=orientation):
                data = (FIXTURES / f"obama-2009-orientation-{orientation}.heic").read_bytes()
                with Image.open(io.BytesIO(data)) as original:
                    self.assertEqual(orientation, original.info["original_orientation"])
                    self.assertEqual(1, original.getexif().get(274))
                result = analyze(data)
                self.assertEqual((baseline["width"], baseline["height"]), (result["width"], result["height"]))
                self.assertEqual(1, len(result["faces"]))
                self.assertGreater(
                    float(np.dot(baseline["faces"][0]["embedding"], result["faces"][0]["embedding"])), 0.99
                )
                for field in ("x", "y", "width", "height"):
                    self.assertAlmostEqual(baseline["faces"][0][field], result["faces"][0][field], delta=0.01)

    def test_grid_and_10bit_sdr_have_real_embeddings(self):
        baseline = analyze((FIXTURES / "obama-2009-orientation-1.heic").read_bytes())
        for suffix in ("grid", "10bit"):
            with self.subTest(encoding=suffix):
                data = (FIXTURES / f"obama-2009-{suffix}.heic").read_bytes()
                with Image.open(io.BytesIO(data)) as image:
                    self.assertEqual(10 if suffix == "10bit" else 8, image.info["bit_depth"])
                    if suffix == "grid":
                        self.assertIn("tiling", image.info)
                result = analyze(data)
                self.assertEqual(1, len(result["faces"]))
                self.assertGreater(
                    float(np.dot(baseline["faces"][0]["embedding"], result["faces"][0]["embedding"])), 0.95
                )

    def test_heif_generic_major_brand_with_hevc_compatibility(self):
        data = bytearray(self.data)
        data[8:12] = b"mif1"
        image = decode_rgb(bytes(data))
        self.assertEqual((1916, 2608), image.size)
        self.assertEqual("RGB", image.mode)

    def test_no_new_icc_profile_transform(self):
        # v1 intentionally retains profile-encoded RGB values for ALL formats.
        with Image.open(io.BytesIO(self.data)) as image:
            expected = np.array(image.convert("RGB"))
        np.testing.assert_array_equal(expected, np.array(decode_rgb(self.data)))

    def test_multiple_top_level_images_rejected(self):
        with self.assertRaisesRegex(ImageRejected, "^animated_image$"):
            decode_rgb((FIXTURES / "obama-2009-multiple.heic").read_bytes())

    def test_sequence_brands_and_tracks_rejected_before_decode(self):
        for brand in (b"hevc", b"hevx", b"msf1"):
            for position in (8, 16):
                data = bytearray(self.data)
                data[position : position + 4] = brand
                with self.subTest(brand=brand, position=position):
                    with self.assertRaisesRegex(ImageRejected, "^unsupported_sequence$"):
                        decode_rgb(bytes(data))
        for box in (b"moov", b"moof", b"styp"):
            with self.subTest(box=box), self.assertRaisesRegex(ImageRejected, "^unsupported_sequence$"):
                decode_rgb(self.data + struct.pack(">I4s", 8, box))

    def test_unrelated_container_codec_rejected(self):
        for brand in (b"avif", b"heim", b"heis"):
            data = bytearray(self.data)
            data[8:12] = brand
            with self.subTest(brand=brand), self.assertRaisesRegex(ImageRejected, "^unsupported_image$"):
                decode_rgb(bytes(data))

    def test_truncated_and_malformed_heif_are_not_no_faces(self):
        broken_bitstream = bytearray(self.data)
        mdat = broken_bitstream.index(b"mdat")
        length = int.from_bytes(broken_bitstream[mdat - 4 : mdat], "big")
        broken_bitstream[mdat + 4 : mdat - 4 + length] = b"\0" * (length - 8)
        for data in (
            self.data[:12],
            self.data[:100],
            self.data[:-128],
            b"\x00\x00\x00\x07ftyp" + self.data[8:],
            b"\x00\x00\x00\x01ftyp",
            self.data + b"bad",
            bytes(broken_bitstream),
            self.data + self.data[: int.from_bytes(self.data[:4], "big")],
        ):
            with self.subTest(length=len(data)), self.assertRaisesRegex(ImageRejected, "^corrupt_image$"):
                decode_rgb(data)

    def test_header_pixel_limit_precedes_pixel_allocation(self):
        data = bytearray(self.data)
        index = data.index(b"ispe")
        data[index + 8 : index + 16] = struct.pack(">II", 8000, 5000)
        self.assertGreater(8000 * 5000, MAX_PIXELS)
        with patch("pillow_heif.as_plugin.HeifImageFile.load", side_effect=AssertionError("pixels decoded")):
            with self.assertRaisesRegex(ImageRejected, "^pixel_limit$"):
                decode_rgb(bytes(data))

    def test_isolated_process_preserves_hash_and_rejects_bad_data(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "infer.py")],
            input=self.data,
            capture_output=True,
            timeout=45,
            check=True,
        )
        response = json.loads(result.stdout)
        self.assertEqual(hashlib.sha256(self.data).hexdigest(), response["sourceSha256"])
        self.assertEqual(1, len(response["faces"]))
        self.assertEqual(128, len(response["faces"][0]["embedding"]))
        rejected = subprocess.run(
            [sys.executable, str(ROOT / "infer.py")],
            input=self.data[:100],
            capture_output=True,
            timeout=45,
            check=False,
        )
        self.assertNotEqual(0, rejected.returncode)
        self.assertEqual({"error": "corrupt_image"}, json.loads(rejected.stdout))


if __name__ == "__main__":
    unittest.main()
