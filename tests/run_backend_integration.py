#!/usr/bin/env python3
"""Run every .NET test against fresh library, storage and faces databases.

From the repository root: python3.12 tests/run_backend_integration.py
Requires Docker and the .NET 10 SDK. No development credentials are read.
The deliberately paused real-inference qualification remains opted out.
"""

import argparse
import os
import secrets
import shutil
import subprocess
import time
from pathlib import Path

DOMAINS = ("library", "storage", "faces")


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    if not Path("Nephos.slnx").is_file():
        parser.error("Run this command from the repository root.")

    run("dotnet", "restore", "--locked-mode", "--nologo")
    run("dotnet", "format", "Nephos.slnx", "--no-restore", "--verify-no-changes", "--verbosity", "quiet")
    run("dotnet", "build", "--no-restore", "--nologo", "-v:minimal")

    name = "nephos-backend-audit-" + secrets.token_hex(6)
    password = secrets.token_hex(24)
    work = Path("artifacts", name)
    work.mkdir(parents=True, exist_ok=False)
    started = False
    try:
        run(
            "docker",
            "run",
            "--detach",
            "--name",
            name,
            "--publish",
            "127.0.0.1::5432",
            "--env",
            "POSTGRES_PASSWORD=" + password,
            "postgres:18-alpine",
            stdout=subprocess.DEVNULL,
        )
        started = True
        for _attempt in range(60):
            ready = subprocess.run(
                ["docker", "exec", name, "pg_isready", "-h", "127.0.0.1", "-U", "postgres"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if ready.returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError("Audit PostgreSQL did not become ready.")

        sql = "".join(
            f"CREATE ROLE {domain}_app LOGIN PASSWORD '{password}'; CREATE DATABASE {domain}_audit;"
            for domain in DOMAINS
        )
        run(
            "docker",
            "exec",
            "-i",
            name,
            "psql",
            "-h",
            "127.0.0.1",
            "-v",
            "ON_ERROR_STOP=1",
            "-U",
            "postgres",
            input=sql,
            text=True,
            stdout=subprocess.DEVNULL,
        )
        port = subprocess.check_output(["docker", "port", name, "5432/tcp"], text=True).strip().rsplit(":", 1)[1]
        env = {**os.environ, "TMPDIR": str(work.resolve()), "OTEL_SDK_DISABLED": "true"}
        connections = {}
        for domain in DOMAINS:
            connection = f"Host=127.0.0.1;Port={port};Database={domain}_audit;Username=postgres;Password={password}"
            connections[domain] = connection
            migration_env = {**env, "MIGRATION_CONNECTION": connection}
            for _application in range(2):
                run(
                    "dotnet", "run", "--no-build", "--project", "src/Nephos.Migrations", "--", domain, env=migration_env
                )

        env["LIBRARY_TEST_CONNECTION"] = connections["library"]
        env["STORAGE_CLEANUP_TEST_ADMIN_CONNECTION"] = connections["storage"]
        env["STORAGE_CLEANUP_TEST_CONNECTION"] = connections["storage"].replace(
            "Username=postgres", "Username=storage_app"
        )
        env["FACES_TEST_CONNECTION"] = connections["faces"].replace("Username=postgres", "Username=faces_app")
        env["FACES_PROJECT_ROOT"] = str(Path.cwd())
        env.pop("FACES_REAL_INFERENCE", None)
        run("dotnet", "test", "--no-build", "--nologo", "-v:minimal", env=env)
    finally:
        try:
            if started:
                run("docker", "rm", "--force", "--volumes", name, stdout=subprocess.DEVNULL)
        finally:
            shutil.rmtree(work)


if __name__ == "__main__":
    main()
