"""Run deterministic face-service tests with a disposable DB and fixture inference, never model weights."""

import os
from pathlib import Path
import secrets
import subprocess
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


name = "nephos-face-fixtures-" + secrets.token_hex(6)
admin_password = secrets.token_hex(24)
owner_password = secrets.token_hex(24)
app_password = secrets.token_hex(24)
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
        "POSTGRES_PASSWORD=" + admin_password,
        "--env",
        "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256",
        "postgres:18-alpine",
        stdout=subprocess.DEVNULL,
    )
    for _ in range(60):
        ready = subprocess.run(
            ["docker", "exec", name, "pg_isready", "-h", "127.0.0.1", "-U", "postgres"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if ready.returncode == 0:
            break
        time.sleep(1)
    else:
        raise RuntimeError("Disposable face test database did not become ready.")

    def sql(database, statement):
        run(
            "docker",
            "exec",
            "-i",
            "--env",
            "PGPASSWORD=" + admin_password,
            name,
            "psql",
            "-h",
            "127.0.0.1",
            "-v",
            "ON_ERROR_STOP=1",
            "-U",
            "postgres",
            "-d",
            database,
            input=statement,
            text=True,
            stdout=subprocess.DEVNULL,
        )

    sql(
        "postgres",
        f"CREATE ROLE faces_owner LOGIN PASSWORD '{owner_password}';"
        f"CREATE ROLE faces_app LOGIN PASSWORD '{app_password}';",
    )
    sql("postgres", "CREATE DATABASE faces_tests OWNER faces_owner;")
    sql(
        "postgres",
        "REVOKE CONNECT ON DATABASE faces_tests FROM PUBLIC; GRANT CONNECT ON DATABASE faces_tests TO faces_app;",
    )
    sql("faces_tests", "REVOKE ALL ON SCHEMA public FROM PUBLIC; GRANT USAGE ON SCHEMA public TO faces_app;")
    port = subprocess.check_output(["docker", "port", name, "5432/tcp"], text=True).strip().rsplit(":", 1)[1]
    env = dict(os.environ)
    env["MIGRATION_CONNECTION"] = (
        f"Host=127.0.0.1;Port={port};Database=faces_tests;Username=faces_owner;Password={owner_password}"
    )
    run("dotnet", "run", "--project", "src/Nephos.Migrations", "--no-restore", "--", "faces", env=env)
    env.pop("MIGRATION_CONNECTION")
    env["FACES_TEST_CONNECTION"] = (
        f"Host=127.0.0.1;Port={port};Database=faces_tests;Username=faces_app;Password={app_password}"
    )
    env["FACES_PROJECT_ROOT"] = str(Path.cwd())
    env.pop("FACES_REAL_INFERENCE", None)
    env["OTEL_SDK_DISABLED"] = "true"
    run(
        "dotnet",
        "test",
        "tests/Nephos.Faces.Tests",
        "--no-restore",
        "--filter",
        "Category!=RealInference",
        "--nologo",
        "-v:minimal",
        env=env,
    )
finally:
    subprocess.run(["docker", "rm", "--force", "--volumes", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
