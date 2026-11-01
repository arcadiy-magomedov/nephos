"""Run production trash/restore/deletion models in an isolated simulator host."""

import argparse
import json
import os
from pathlib import Path
import shutil
import time

from ui_qualification import BUNDLE, IOS, build, command


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--simulator", required=True)
    args = parser.parse_args()
    workspace = IOS / ".qualification" / "trash"
    workspace.mkdir(parents=True, exist_ok=True)
    previous = workspace / "NephosUIQualification.app"
    if previous.exists():
        shutil.rmtree(previous)
    app = build(workspace)
    command("xcrun", "simctl", "install", args.simulator, str(app))
    container = Path(command(
        "xcrun", "simctl", "get_app_container", args.simulator, BUNDLE, "data"
    ).stdout.strip())
    report = container / "Documents" / "ui-report.json"
    report.unlink(missing_ok=True)
    environment = os.environ.copy()
    environment["SIMCTL_CHILD_NEPHOS_UI_SCREEN"] = "trash-native"
    command("xcrun", "simctl", "launch", "--terminate-running-process",
            args.simulator, BUNDLE, env=environment)
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not report.exists():
            time.sleep(0.25)
        if not report.exists():
            raise RuntimeError("Native trash qualification did not produce a report.")
        result = json.loads(report.read_text())
        if not result.get("ready") or result.get("checks") != 14:
            raise RuntimeError(f"Native trash qualification failed: {result}")
        print("Native trash qualification: 14 checks passed.")
    finally:
        command("xcrun", "simctl", "terminate", args.simulator, BUNDLE)


if __name__ == "__main__":
    main()
