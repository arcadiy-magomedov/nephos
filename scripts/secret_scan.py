#!/usr/bin/env python3
"""Scan publishable files (or exact Git index bytes) and optionally all Git history."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def scan(staged=False, history=False):
    if not shutil.which("gitleaks"):
        raise SystemExit("Install gitleaks 8.30.1 before running secret checks.")
    command = ["git", "ls-files", "--cached", "-z"]
    if not staged:
        command.extend(["--others", "--exclude-standard"])
    paths = sorted(set(subprocess.check_output(command, cwd=ROOT).decode().split("\0")) - {""})
    with tempfile.TemporaryDirectory(prefix="nephos-secret-scan-") as directory:
        target = Path(directory)
        for name in paths:
            relative = Path(name)
            if relative.is_absolute() or ".." in relative.parts:
                raise SystemExit("Refusing unsafe repository path.")
            if (relative.name == ".env" or relative.name.startswith(".env.")) and relative.name != ".env.example":
                raise SystemExit(f"Refusing to publish environment credentials: {name}")
            if relative.suffix.lower() in {".p8", ".p12", ".pfx", ".key"}:
                raise SystemExit(f"Refusing to publish private-key material: {name}")
            source = ROOT / relative
            destination = target / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if staged:
                content = subprocess.check_output(["git", "show", ":" + name], cwd=ROOT)
                destination.write_bytes(content)
            else:
                if source.is_symlink():
                    raise SystemExit(f"Refusing to follow source symlink during publication scan: {name}")
                if source.exists():
                    shutil.copyfile(source, destination)
        report = target / "gitleaks-report.json"
        result = subprocess.run(
            [
                "gitleaks",
                "dir",
                "--redact",
                "--no-banner",
                "--ignore-gitleaks-allow",
                "--report-format",
                "json",
                "--report-path",
                str(report),
                "--config",
                str(ROOT / ".gitleaks.toml"),
                str(target),
            ],
            cwd=ROOT,
            check=False,
        )
        if result.returncode:
            if report.exists():
                for finding in json.loads(report.read_text()):
                    print(f"{finding['RuleID']}: {finding['File']}:{finding['StartLine']}")
            raise SystemExit(result.returncode)
    if history:
        subprocess.run(
            [
                "gitleaks",
                "git",
                "--redact",
                "--no-banner",
                "--ignore-gitleaks-allow",
                "--config",
                str(ROOT / ".gitleaks.toml"),
                "--log-opts=--all",
                ".",
            ],
            cwd=ROOT,
            check=True,
        )
    print(f"Secret scan passed for {len(paths)} publishable files" + (" and Git history." if history else "."))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="Scan exact staged content, not working files.")
    parser.add_argument("--history", action="store_true", help="Also scan every locally available Git ref.")
    args = parser.parse_args()
    scan(args.staged, args.history)
