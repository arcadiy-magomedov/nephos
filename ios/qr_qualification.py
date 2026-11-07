#!/usr/bin/env python3
"""Native QR/Keychain checks and optional real-service image enrollment (never injected tokens)."""

import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

from onboarding_qualification import BUNDLE, IOS, project


def failure_summary(result_bundle):
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result_bundle), "--compact"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        print("QR qualification diagnostics unavailable.", flush=True)
        return

    def visit(node):
        if node.get("nodeType") == "Failure Message":
            message = node.get("name", "")
            location = re.search(r"QREnrollmentUITests\.swift:\d+", message)
            stage = re.search(r"QR_STAGE=[a-z-]+", message)
            error = re.search(r"QR_ERROR=[a-zA-Z0-9_.:-]+", message)
            print(
                "QR qualification failure: " + " ".join(match.group(0) for match in [location, stage, error] if match),
                flush=True,
            )
        for child in node.get("children", []):
            visit(child)

    try:
        for node in json.loads(result.stdout).get("testNodes", []):
            visit(node)
    except (ValueError, TypeError):
        print("QR qualification diagnostics could not be decoded.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument(
        "--qr-image", type=Path, help="Fresh real invitation PNG from the isolated HTTPS service fixture."
    )
    args = parser.parse_args()
    if args.qr_image and not args.qr_image.is_file():
        parser.error("--qr-image must be an existing image file.")
    scratch = IOS / ".test-work"
    scratch.mkdir(exist_ok=True)
    logs = IOS / ".logs"
    logs.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="qr-native-", dir=scratch) as directory:
        workspace = Path(directory)
        destination = project(workspace, test_sources=[IOS / "Qualification/QREnrollmentUITests.swift"])
        result_bundle = logs / (workspace.name + ".xcresult")
        common = [
            "xcodebuild",
            "-quiet",
            "-project",
            str(destination),
            "-scheme",
            "Onboarding",
            "-sdk",
            "iphonesimulator",
            "-destination",
            "id=" + args.simulator,
            "-derivedDataPath",
            str(workspace / "DerivedData"),
        ]
        try:
            subprocess.run(common + ["build-for-testing"], check=True)
            subprocess.run(
                [
                    "codesign",
                    "--force",
                    "--sign",
                    "-",
                    "--identifier",
                    BUNDLE,
                    str(workspace / "DerivedData/Build/Products/Debug-iphonesimulator/NephosUIQualification.app"),
                ],
                check=True,
            )
            runfile = next((workspace / "DerivedData/Build/Products").glob("*.xctestrun"))
            run = plistlib.loads(runfile.read_bytes())
            targets = (
                [target for configuration in run["TestConfigurations"] for target in configuration["TestTargets"]]
                if "TestConfigurations" in run
                else [target for target in run.values() if isinstance(target, dict) and "TestBundlePath" in target]
            )
            for target in targets:
                target.setdefault("EnvironmentVariables", {})["NEPHOS_QR_IMAGE"] = (
                    str(args.qr_image.resolve()) if args.qr_image else ""
                )
            runfile.write_bytes(plistlib.dumps(run))
            subprocess.run(
                [
                    "xcodebuild",
                    "-quiet",
                    "test-without-building",
                    "-xctestrun",
                    str(runfile),
                    "-destination",
                    "id=" + args.simulator,
                    "-parallel-testing-enabled",
                    "NO",
                    "-resultBundlePath",
                    str(result_bundle),
                ],
                check=True,
            )
        finally:
            if args.qr_image and result_bundle.exists():
                failure_summary(result_bundle)
                shutil.rmtree(result_bundle)
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, BUNDLE], check=False)
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, BUNDLE + ".uitests.xctrunner"], check=False)


if __name__ == "__main__":
    main()
