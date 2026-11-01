"""Validate cleanup against an isolated disposable PostgreSQL container."""

import os
import secrets
import subprocess
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


name = "nephos-cleanup-tests-" + secrets.token_hex(6)
password = secrets.token_hex(24)
try:
    run(
        "docker", "run", "--detach", "--name", name,
        "--publish", "127.0.0.1::5432",
        "--env", "POSTGRES_PASSWORD=" + password,
        "postgres:18-alpine",
        stdout=subprocess.DEVNULL,
    )
    for attempt in range(60):
        ready = subprocess.run(
            ["docker", "exec", name, "pg_isready", "-U", "postgres"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if ready.returncode == 0:
            break
        time.sleep(1)
    else:
        raise RuntimeError("Disposable PostgreSQL did not become ready")
    run(
        "docker", "exec", "-i", name, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres",
        input="CREATE ROLE storage_app LOGIN; CREATE DATABASE storage_cleanup_tests;",
        text=True, stdout=subprocess.DEVNULL,
    )
    port = subprocess.check_output(["docker", "port", name, "5432/tcp"], text=True).strip().rsplit(":", 1)[1]
    env = dict(os.environ)
    connection = f"Host=127.0.0.1;Port={port};Database=storage_cleanup_tests;Username=postgres;Password={password}"
    env["MIGRATION_CONNECTION"] = connection
    run("dotnet", "run", "--project", "src/Nephos.Migrations", "--", "storage", env=env)
    # Test using app-role grants, not the owner, after migration.
    run(
        "docker", "exec", "-i", name, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres",
        "-d", "storage_cleanup_tests", text=True, stdout=subprocess.DEVNULL,
        input=f"ALTER ROLE storage_app PASSWORD '{password}'; GRANT USAGE ON SCHEMA public TO storage_app;",
    )
    env.pop("MIGRATION_CONNECTION")
    env["STORAGE_CLEANUP_TEST_ADMIN_CONNECTION"] = connection
    env["STORAGE_CLEANUP_TEST_CONNECTION"] = connection.replace("Username=postgres", "Username=storage_app")
    run("dotnet", "test", "tests/Nephos.Tests", "--filter", "FullyQualifiedName~Cleanup", "--nologo", "-v:minimal", env=env)
finally:
    subprocess.run(["docker", "rm", "--force", "--volumes", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
