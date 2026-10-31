"""Separate simulator UI host using production views and a real disposable API account."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import time

IOS = Path(__file__).resolve().parent
BUNDLE = "app.nephos.ui-qualification"


def command(*args, **kwargs):
    try:
        return subprocess.run(args, cwd=IOS, check=True, text=True, capture_output=True, **kwargs)
    except subprocess.CalledProcessError as error:
        output = (error.stdout or "") + (error.stderr or "")
        for key, value in kwargs.get("env", {}).items():
            if "BEARER" in key:
                output = output.replace(value, "[REDACTED]")
        raise RuntimeError(output) from None


def build(workspace):
    app = workspace / "NephosUIQualification.app"
    app.mkdir()
    sdk = command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path").stdout.strip()
    sources = sorted(path for path in (IOS / "Nephos").rglob("*.swift") if path.name != "NephosApp.swift")
    sources.append(IOS / "Qualification/UIQualification.swift")
    entitlement = workspace / "Simulated.xcent"
    entitlement.write_bytes(plistlib.dumps({"application-identifier": "FAKETEAMID." + BUNDLE}))
    command(
        "xcrun",
        "--sdk",
        "iphonesimulator",
        "swiftc",
        "-swift-version",
        "5",
        "-parse-as-library",
        "-D",
        "UI_QUALIFICATION",
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
        str(entitlement),
        "-o",
        str(app / "NephosUIQualification"),
    )
    info = plistlib.loads((IOS / "Nephos/Info-Debug.plist").read_bytes())
    info.update(
        {
            "CFBundleIdentifier": BUNDLE,
            "CFBundleExecutable": "NephosUIQualification",
            "CFBundleName": "Nephos UI Qualification",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "MinimumOSVersion": "17.0",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
            "UIDeviceFamily": [1, 2],
        }
    )
    info.pop("UIApplicationSceneManifest", None)
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    command("codesign", "--force", "--sign", "-", "--identifier", BUNDLE, str(app))
    return app


def capture(simulator, app, environment):
    output = IOS / ".logs/design-ui"
    output.mkdir(exist_ok=True)
    command("xcrun", "simctl", "install", simulator, str(app))
    container = Path(command("xcrun", "simctl", "get_app_container", simulator, BUNDLE, "data").stdout.strip())
    report = container / "Documents/ui-report.json"
    try:
        for screen, theme in [
            ("gallery", "light"),
            ("gallery", "dark"),
            ("people", "light"),
            ("person", "dark"),
            ("history", "light"),
            ("photo", "dark"),
            ("photo-people", "light"),
            ("settings", "light"),
            ("backup", "light"),
            ("sharing", "dark"),
            ("share", "light"),
        ]:
            report.unlink(missing_ok=True)
            env = os.environ.copy()
            env.update(
                {"SIMCTL_CHILD_" + key: value for key, value in environment.items() if key.startswith("NEPHOS_")}
            )
            env["SIMCTL_CHILD_NEPHOS_UI_SCREEN"] = screen
            env["SIMCTL_CHILD_NEPHOS_UI_THEME"] = theme
            command("xcrun", "simctl", "launch", "--terminate-running-process", simulator, BUNDLE, env=env)
            deadline = time.monotonic() + 40
            while not report.exists() and time.monotonic() < deadline:
                time.sleep(0.25)
            if not report.exists():
                raise RuntimeError("UI qualification timed out before loading the real fixture.")
            result = json.loads(report.read_text())
            if not result["ready"]:
                raise RuntimeError(result["error"])
            time.sleep(3)
            command("xcrun", "simctl", "io", simulator, "screenshot", str(output / f"{screen}-{theme}.png"))
        print("Captured eleven native screens using production views and a real disposable account.")
    finally:
        command("xcrun", "simctl", "terminate", simulator, BUNDLE)
        command("xcrun", "simctl", "uninstall", simulator, BUNDLE)
