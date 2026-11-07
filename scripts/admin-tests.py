#!/usr/bin/env python3
"""Run administration persistence and upgrade tests on a fresh disposable database."""

import os
import secrets
import subprocess
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    name = "nephos-administration-tests-" + secrets.token_hex(6)
    password = secrets.token_hex(32)
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
            "postgres:18-alpine@sha256:898c60cb390d1085bc97bdd6a1ae968757421df394b071848b52b1c09c89d6a5",
            stdout=subprocess.DEVNULL,
        )
        for _ in range(60):
            ready = subprocess.run(
                ["docker", "exec", name, "pg_isready", "-U", "postgres"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if ready.returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError("Administration test PostgreSQL did not become ready.")
        run(
            "docker",
            "exec",
            "-i",
            name,
            "psql",
            "-v",
            "ON_ERROR_STOP=1",
            "-U",
            "postgres",
            input="CREATE ROLE library_app; CREATE DATABASE administration_tests;",
            text=True,
            stdout=subprocess.DEVNULL,
        )
        port = subprocess.check_output(["docker", "port", name, "5432/tcp"], text=True).strip().rsplit(":", 1)[1]
        connection = f"Host=127.0.0.1;Port={port};Database=administration_tests;Username=postgres;Password={password}"
        env = {**os.environ, "MIGRATION_CONNECTION": connection, "OTEL_SDK_DISABLED": "true"}
        run("dotnet", "run", "--project", "src/Nephos.Migrations", "--", "library", env=env)
        env.pop("MIGRATION_CONNECTION")
        env["LIBRARY_TEST_CONNECTION"] = connection
        run(
            "dotnet",
            "test",
            "tests/Nephos.Tests",
            "--filter",
            "FullyQualifiedName~Administration",
            "--nologo",
            "-v:minimal",
            env=env,
        )
    finally:
        removed = subprocess.run(
            ["docker", "rm", "--force", "--volumes", name], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True
        )
        if removed.returncode:
            raise RuntimeError("Administration test container cleanup failed.")


if __name__ == "__main__":
    main()
