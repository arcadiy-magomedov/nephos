"""Generate actual HEVC/HEIF fixtures from attributed portraits, never user media."""

import hashlib
import json
from pathlib import Path

from PIL import Image, ImageOps
import numpy as np
import pillow_heif

pillow_heif.register_heif_opener()
ROOT = Path(__file__).resolve().parent
ENCODING = {
    "quality": 90,
    "chroma": 420,
    "enc_params": {"preset": "ultrafast", "x265:pools": "1", "x265:frame-threads": "1"},
}
INVERSE_ORIENTATION = {
    2: Image.Transpose.FLIP_LEFT_RIGHT,
    3: Image.Transpose.ROTATE_180,
    4: Image.Transpose.FLIP_TOP_BOTTOM,
    5: Image.Transpose.TRANSPOSE,
    6: Image.Transpose.ROTATE_90,
    7: Image.Transpose.TRANSVERSE,
    8: Image.Transpose.ROTATE_270,
}


def generate():
    output = ROOT / "heic"
    output.mkdir(exist_ok=True)
    entries = []
    sources = json.loads((ROOT / "provenance.json").read_text())

    def save(image, source, name, transformation, **options):
        path = output / name
        image.save(path, format="HEIF", **ENCODING, **options)
        data = path.read_bytes()
        entries.append(
            {
                "id": path.stem,
                "path": "fixtures/heic/" + name,
                "sourceId": source["id"],
                "sourceSha256": source["sha256"],
                "sourceUrl": source["url"],
                "sourcePage": source["sourcePage"],
                "author": source["author"],
                "label": source["label"],
                "license": source["license"],
                "licenseUrl": source.get("licenseUrl"),
                "sha256": hashlib.sha256(data).hexdigest(),
                "bytes": len(data),
                "transformation": transformation,
                "cameraOriginal": False,
            }
        )

    for source in sources:
        path = ROOT / "photos" / (source["id"] + ".jpg")
        if hashlib.sha256(path.read_bytes()).hexdigest() != source["sha256"]:
            raise RuntimeError("Source fixture checksum mismatch: " + source["id"])
        with Image.open(path) as original:
            upright = ImageOps.exif_transpose(original).convert("RGB")
        save(
            upright,
            source,
            source["id"] + ".heic",
            "Original dimensions, EXIF-normalized RGB, HEVC quality 90 4:2:0; derived codec fixture.",
        )
        if source["id"] == "obama-2009":
            with ImageOps.pad(upright, (6048, 8064), method=Image.Resampling.LANCZOS) as large:
                save(
                    large,
                    source,
                    "obama-2009-48mp.heic",
                    "Upscaled and padded to 6048x8064 (48.77MP); synthetic resolution fixture, NOT a camera capture.",
                )
            upright.thumbnail((640, 640))
            for orientation in range(1, 9):
                stored = upright if orientation == 1 else upright.transpose(INVERSE_ORIENTATION[orientation])
                exif = Image.Exif()
                exif[274] = orientation
                save(
                    stored,
                    source,
                    f"obama-2009-orientation-{orientation}.heic",
                    f"Maximum dimension 640; inverse stored orientation {orientation}; "
                    "EXIF plus HEIF irot/imir transform; derived codec fixture.",
                    exif=exif.tobytes(),
                )
            save(
                upright,
                source,
                "obama-2009-grid.heic",
                "Maximum dimension 640; 512px HEIF grid tiles; derived codec fixture.",
                tile_size=512,
            )
            high_depth = pillow_heif.from_bytes(
                "RGB;16", upright.size, (np.array(upright).astype(np.uint16) * 257).tobytes()
            )
            save(
                high_depth,
                source,
                "obama-2009-10bit.heic",
                "Maximum dimension 640; expanded SDR samples encoded in 10-bit HEVC; NOT camera HDR.",
            )
            save(
                upright,
                source,
                "obama-2009-multiple.heic",
                "Two independent top-level images; negative fixture, must be rejected.",
                save_all=True,
                append_images=[upright.copy()],
            )
    manifest = {
        "purpose": "Generated codec acceptance fixtures, NOT real iPhone captures or an accuracy benchmark.",
        "generator": "face-inference/fixtures/generate_heic.py",
        "pillowHeif": pillow_heif.__version__,
        "libheif": pillow_heif.libheif_info(),
        "encoding": ENCODING,
        "fixtures": entries,
    }
    (output / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Generated {len(entries)} HEIC fixtures in {output}")
    return manifest


if __name__ == "__main__":
    generate()
