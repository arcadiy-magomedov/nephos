"""Run repository/API tests against only the optional face database, without exposing credentials."""

from pathlib import Path
import os
import subprocess

values = dict(line.split("=", 1) for line in Path(".env.faces").read_text().splitlines() if "=" in line)
env = dict(os.environ)
compose = [
    "docker",
    "compose",
    "--env-file",
    ".env",
    "--env-file",
    ".env.faces",
    "-f",
    "compose.yaml",
    "-f",
    "compose.faces.yaml",
]
exists = subprocess.check_output(
    compose
    + [
        "exec",
        "-T",
        "faces-postgres",
        "psql",
        "-U",
        "postgres",
        "-tAc",
        "SELECT 1 FROM pg_database WHERE datname='faces_tests'",
    ],
    text=True,
).strip()
if exists != "1":
    subprocess.check_call(
        compose
        + [
            "exec",
            "-T",
            "faces-postgres",
            "psql",
            "-U",
            "postgres",
            "-c",
            "CREATE DATABASE faces_tests OWNER faces_owner",
        ]
    )
    subprocess.check_call(
        compose
        + [
            "exec",
            "-T",
            "faces-postgres",
            "psql",
            "-U",
            "postgres",
            "-c",
            "REVOKE CONNECT ON DATABASE faces_tests FROM PUBLIC; GRANT CONNECT ON DATABASE faces_tests TO faces_app",
        ]
    )
    subprocess.check_call(
        compose
        + [
            "exec",
            "-T",
            "faces-postgres",
            "psql",
            "-U",
            "postgres",
            "-d",
            "faces_tests",
            "-c",
            "REVOKE ALL ON SCHEMA public FROM PUBLIC; GRANT USAGE ON SCHEMA public TO faces_app",
        ]
    )
env["MIGRATION_CONNECTION"] = (
    f"Host=127.0.0.1;Port=18086;Database=faces_tests;Username=faces_owner;Password={values['FACES_OWNER_PASSWORD']}"
)
subprocess.check_call(["dotnet", "run", "--project", "src/Nephos.Migrations", "--", "faces"], env=env)
env.pop("MIGRATION_CONNECTION")
env["FACES_TEST_CONNECTION"] = (
    f"Host=127.0.0.1;Port=18086;Database=faces_tests;Username=faces_app;Password={values['FACES_APP_PASSWORD']}"
)
env["FACES_PROJECT_ROOT"] = str(Path.cwd())
raise SystemExit(subprocess.call(["dotnet", "test", "tests/Nephos.Faces.Tests", "--nologo", "-v:minimal"], env=env))
