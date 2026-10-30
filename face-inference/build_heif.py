"""Build pinned, dynamically linked LGPL HEVC decoding libraries, without encoders."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

root = Path(__file__).resolve().parent
sources = root / "native-sources"
sources.mkdir(exist_ok=True)
prefix = root / "native"
licenses = prefix / "share/licenses"
licenses.mkdir(parents=True, exist_ok=True)
manifest = json.loads((root / "heif-native.json").read_text())

for source in manifest["sources"]:
    archive = sources / source["file"]
    with urllib.request.urlopen(source["url"], timeout=120) as response:
        data = response.read(source["bytes"] + 1)
    if len(data) != source["bytes"] or hashlib.sha256(data).hexdigest() != source["sha256"]:
        raise RuntimeError("Native source integrity failure: " + source["name"])
    archive.write_bytes(data)
    with tarfile.open(archive) as tar:
        tar.extractall(sources, filter="data")
    directory = sources / f"{source['name']}-{source['version']}"
    notice = directory / ("LICENSE.txt" if source["name"] == "pillow_heif" else "COPYING")
    shutil.copyfile(notice, licenses / f"{source['name']}-LICENSE")
    if source["name"] == "pillow_heif":
        subprocess.run(
            [
                "python",
                "-m",
                "pip",
                "wheel",
                "--no-deps",
                "--no-build-isolation",
                "--wheel-dir",
                str(root / "wheels"),
                str(directory),
            ],
            check=True,
        )
        continue
    flags = [
        "-DCMAKE_BUILD_TYPE=Release",
        f"-DCMAKE_INSTALL_PREFIX={prefix}",
        "-DCMAKE_INSTALL_LIBDIR=lib",
        "-DBUILD_SHARED_LIBS=ON",
    ]
    if source["name"] == "libde265":
        flags += ["-DENABLE_DECODER=OFF", "-DENABLE_ENCODER=OFF", "-DENABLE_SDL=OFF"]
    else:
        flags += [
            f"-DCMAKE_PREFIX_PATH={prefix}",
            "-DENABLE_PLUGIN_LOADING=OFF",
            "-DWITH_LIBDE265=ON",
            "-DWITH_LIBDE265_PLUGIN=OFF",
            "-DWITH_EXAMPLES=OFF",
            "-DWITH_GDK_PIXBUF=OFF",
            "-DBUILD_TESTING=OFF",
            "-DBUILD_DOCUMENTATION=OFF",
            "-DENABLE_PARALLEL_TILE_DECODING=OFF",
        ]
        flags += [
            f"-DWITH_{name}=OFF"
            for name in (
                "X265",
                "KVAZAAR",
                "UVG266",
                "VVDEC",
                "VVENC",
                "X264",
                "OpenH264_DECODER",
                "DAV1D",
                "AOM_DECODER",
                "AOM_ENCODER",
                "SvtEnc",
                "RAV1E",
                "JPEG_DECODER",
                "JPEG_ENCODER",
                "OpenJPEG_ENCODER",
                "OpenJPEG_DECODER",
                "FFMPEG_DECODER",
                "OPENJPH_ENCODER",
                "UNCOMPRESSED_CODEC",
                "WEBCODECS",
                "LIBSHARPYUV",
            )
        ]
    build = directory / "build"
    subprocess.run(["cmake", "-S", str(directory), "-B", str(build), *flags], check=True)
    subprocess.run(["cmake", "--build", str(build), "--parallel", "2"], check=True)
    subprocess.run(["cmake", "--install", str(build)], check=True)
    os.environ["PKG_CONFIG_PATH"] = str(prefix / "lib/pkgconfig")
    os.environ["LD_LIBRARY_PATH"] = str(prefix / "lib")
    os.environ["LIBHEIF_ROOT"] = str(prefix)

# Corresponding unmodified source archives accompany distributed native binaries.
for archive in sources.glob("*.tar.gz"):
    destination = prefix / "share/sources"
    destination.mkdir(exist_ok=True)
    shutil.copyfile(archive, destination / archive.name)
