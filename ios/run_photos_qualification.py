#!/usr/bin/env python3
"""Build a separate synthetic PhotoKit probe; never changes the Nephos app's identity or tokens."""

import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

IOS = Path(__file__).resolve().parent
BUNDLE = "app.nephos.qualification"


def command(*args, **kwargs):
    return subprocess.run(args, cwd=IOS, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--simulator", required=True, help="An already booted workspace simulator UUID; it will not be erased."
    )
    parser.add_argument(
        "--use-existing-permission",
        action="store_true",
        help="Preserve full Photos permission granted through the simulator UI instead of applying simctl privacy.",
    )
    args = parser.parse_args()
    workspace = IOS / ".test-work" / "photos-qualification"
    app = workspace / "NephosQualification.app"
    app.mkdir(parents=True, exist_ok=True)
    sdk = command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path", capture_output=True).stdout.strip()
    sources = sorted((IOS / "Nephos" / "Core").glob("*.swift"))
    sources += [IOS / "Nephos" / "Platform" / name for name in ("PhotosLibrary.swift", "Media.swift", "Restore.swift")]
    sources.append(IOS / "Qualification" / "PhotosQualification.swift")
    # Match Xcode's simulator-only __TEXT entitlement, not restricted host signature
    # entitlements. Missing this identity breaks simulated TCC and Keychain services.
    simulated = workspace / "Simulated.xcent"
    simulated.write_bytes(plistlib.dumps({"application-identifier": "FAKETEAMID." + BUNDLE}))
    command(
        "xcrun",
        "--sdk",
        "iphonesimulator",
        "swiftc",
        "-swift-version",
        "5",
        "-parse-as-library",
        "-sdk",
        sdk,
        "-target",
        "arm64-apple-ios17.0-simulator",
        *map(str, sources),
        "-Xlinker",
        "-sectcreate",
        "-Xlinker",
        "__TEXT",
        "-Xlinker",
        "__entitlements",
        "-Xlinker",
        str(simulated),
        "-o",
        str(app / "NephosQualification"),
    )
    info = {
        "CFBundleIdentifier": BUNDLE,
        "CFBundleExecutable": "NephosQualification",
        "CFBundleName": "Nephos Qualification",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "17.0",
        "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        "UIDeviceFamily": [1, 2],
        "LSRequiresIPhoneOS": True,
        "UILaunchScreen": {},
        "NSPhotoLibraryUsageDescription": "Inspect only synthetic Nephos qualification resources after restoring them.",
        "NSPhotoLibraryAddUsageDescription": "Create synthetic JPEG, video and Live Photo round-trip fixtures.",
    }
    with (app / "Info.plist").open("wb") as file:
        plistlib.dump(info, file)
    command("codesign", "--force", "--sign", "-", "--identifier", BUNDLE, str(app), stdout=subprocess.DEVNULL)
    command("xcrun", "simctl", "install", args.simulator, str(app))
    if not args.use_existing_permission:
        command("xcrun", "simctl", "privacy", args.simulator, "grant", "photos", BUNDLE)
    container = Path(
        command(
            "xcrun", "simctl", "get_app_container", args.simulator, BUNDLE, "data", capture_output=True
        ).stdout.strip()
    )
    report_file = container / "Documents" / "report.json"
    # App container reads are necessary to retrieve this simulator-only process's result.
    previous_mtime = report_file.stat().st_mtime if report_file.exists() else 0
    print("If Photos consent appears in Simulator, allow full access to the qualification app.", flush=True)
    command("xcrun", "simctl", "launch", "--terminate-running-process", args.simulator, BUNDLE)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        container = Path(
            command(
                "xcrun", "simctl", "get_app_container", args.simulator, BUNDLE, "data", capture_output=True
            ).stdout.strip()
        )
        report_file = container / "Documents" / "report.json"
        if report_file.exists() and report_file.stat().st_mtime > previous_mtime:
            report = json.loads(report_file.read_text())
            print("\n".join(report))
            (IOS / ".logs").mkdir(exist_ok=True)
            (IOS / ".logs" / "photos-qualification.json").write_text(json.dumps(report, indent=2) + "\n")
            command("xcrun", "simctl", "terminate", args.simulator, BUNDLE)
            failed = any(line.startswith("FAIL") for line in report)
            if not failed:
                command("xcrun", "simctl", "uninstall", args.simulator, BUNDLE)
            shutil.rmtree(workspace)
            return 1 if failed else 0
        time.sleep(1)
    command("xcrun", "simctl", "terminate", args.simulator, BUNDLE)
    shutil.rmtree(workspace)
    raise SystemExit("Qualification timed out; no pass claimed. The simulator and its Photos library were not erased.")


if __name__ == "__main__":
    raise SystemExit(main())
