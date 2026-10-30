"""Real decoder/detector tests; no fake detector is used."""

import io
from pathlib import Path
import unittest

import numpy as np
from PIL import Image
from infer import analyze


class InferenceTests(unittest.TestCase):
    def test_blank_is_no_faces(self):
        image = Image.new("RGB", (320, 240), "white")
        encoded = io.BytesIO()
        image.save(encoded, format="PNG")
        self.assertEqual([], analyze(encoded.getvalue())["faces"])

    def test_corrupt_and_oversized_payloads_rejected(self):
        with self.assertRaises(Exception):
            analyze(b"not an image")
        with self.assertRaises(ValueError):
            analyze(b"x" * (20 * 1024 * 1024 + 1))

    def test_animation_rejected(self):
        encoded = io.BytesIO()
        Image.new("RGB", (20, 20), "red").save(
            encoded, format="PNG", save_all=True, append_images=[Image.new("RGB", (20, 20), "blue")], duration=100
        )
        with self.assertRaises(ValueError):
            analyze(encoded.getvalue())

    def test_exif_orientation_aligns_coordinates_and_embeddings(self):
        path = Path(__file__).parent / "fixtures/photos/obama-2009.jpg"
        if not path.exists():
            self.skipTest("Download licensed portrait fixtures first")
        with Image.open(path) as source:
            upright = source.convert("RGB")
            upright.thumbnail((640, 640))
            first = io.BytesIO()
            upright.save(first, format="PNG")
            # Stored pixels are rotated counterclockwise; EXIF orientation 6 restores upright display.
            rotated = upright.transpose(Image.Transpose.ROTATE_90)
            exif = Image.Exif()
            exif[274] = 6
            second = io.BytesIO()
            rotated.save(second, format="PNG", exif=exif)
        a, b = analyze(first.getvalue()), analyze(second.getvalue())
        self.assertEqual((a["width"], a["height"]), (b["width"], b["height"]))
        self.assertEqual(1, len(a["faces"]))
        self.assertEqual(1, len(b["faces"]))
        for field in ("x", "y", "width", "height"):
            self.assertAlmostEqual(a["faces"][0][field], b["faces"][0][field], places=6)
        self.assertGreater(float(np.dot(a["faces"][0]["embedding"], b["faces"][0]["embedding"])), 0.999)
        self.assertNotEqual(a["sourceSha256"], b["sourceSha256"])


if __name__ == "__main__":
    unittest.main()
