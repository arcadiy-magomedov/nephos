#!/usr/bin/env python3
"""Run native QR qualification against disposable, real loopback services (macOS only)."""

import argparse
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
KEYCLOAK_VERSION = "26.8.1"


class FixtureError(RuntimeError):
    pass


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Fixture:
    def __init__(self, args):
        self.args = args
        self.work = ROOT / "artifacts/native-qr-ci" / uuid.uuid4().hex
        self.children = []
        self.stage = "preflight"
        self.env = {
            **os.environ,
            "DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER": "1",
            "DOTNET_CLI_TELEMETRY_OPTOUT": "1",
        }
        self.pg_port, self.kc_port, self.api_port, self.edge_port = [free_port() for _ in range(4)]
        self.origin = f"https://127.0.0.1:{self.edge_port}"
        self.identity = f"http://127.0.0.1:{self.kc_port}"
        self.password = secrets.token_hex(32)
        self.service_key = secrets.token_hex(32)
        self.introspection_secret = secrets.token_hex(32)

    def command(self, args, *, env=None, data=None, timeout=300):
        # Service output can contain tokens, so even failed child output is never echoed.
        result = subprocess.run(
            [str(arg) for arg in args],
            cwd=ROOT,
            env=env or self.env,
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        if result.returncode:
            raise FixtureError(f"{self.stage}: {Path(str(args[0])).name} exited {result.returncode}")
        return result.stdout

    def start(self, args, env=None):
        log = (self.work / f"process-{len(self.children)}.log").open("wb")
        try:
            child = subprocess.Popen(
                [str(arg) for arg in args],
                cwd=ROOT,
                env=env or self.env,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=log,
                start_new_session=True,
            )
        finally:
            log.close()
        self.children.append(child)

    def wait(self, description, probe, timeout=180):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for child in self.children:
                if child.poll() is not None:
                    raise FixtureError(f"{description}: service exited {child.returncode}")
            try:
                if probe():
                    return
            except (OSError, urllib.error.URLError, json.JSONDecodeError, FixtureError):
                pass
            time.sleep(0.5)
        raise FixtureError(f"Timed out waiting for {description}")

    def request(self, url, body=None, *, method=None, headers=None, expected=200, form=False):
        headers = dict(headers or {})
        if body is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
            body = (urllib.parse.urlencode(body) if form else json.dumps(body)).encode()
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        context = ssl.create_default_context(cafile=str(self.work / "ca.pem")) if url.startswith("https:") else None
        try:
            response = urllib.request.urlopen(request, context=context, timeout=10)
        except urllib.error.HTTPError as error:
            raise FixtureError(f"{self.stage}: HTTP {error.code}; expected {expected}") from None
        with response:
            if response.status != expected:
                raise FixtureError(f"{self.stage}: HTTP {response.status}; expected {expected}")
            data = response.read()
            return json.loads(data) if data else None

    def preflight(self):
        if sys.platform != "darwin":
            raise FixtureError("This fixture requires macOS and an iOS Simulator.")
        for name in ("dotnet", "java", "initdb", "postgres", "psql", "openssl", "caddy", "xcrun"):
            if not shutil.which(name, path=self.env.get("PATH")):
                raise FixtureError(f"Missing {name}; see deploy/native-qr-ci.md.")
        try:
            import qrcode  # noqa: F401
            import PIL.Image  # noqa: F401
        except ImportError:
            raise FixtureError("Missing qrcode[pil]==8.2; install the fixture requirements.") from None
        java = self.command(["java", "-version"]).decode()
        if not any(f'version "{version}.' in java for version in (21, 25)):
            raise FixtureError("Keycloak requires a supported JDK (21 or 25), not the default macOS JVM.")
        distribution = self.args.keycloak_dist.resolve()
        if not (distribution / "bin/kc.sh").is_file():
            raise FixtureError("--keycloak-dist must contain bin/kc.sh.")
        version = self.command([distribution / "bin/kc.sh", "--version"]).decode()
        if f"Keycloak {KEYCLOAK_VERSION}" not in version:
            raise FixtureError(f"Only Keycloak {KEYCLOAK_VERSION} is qualified.")
        try:
            with zipfile.ZipFile(self.args.provider_jar) as jar:
                required = ["app/nephos/keycloak/QrGrant.class", "app/nephos/keycloak/EnrollmentResource.class"]
                if not all(name in jar.namelist() for name in required):
                    raise FixtureError("Provider artifact does not include the actual QR implementation.")
        except (OSError, zipfile.BadZipFile):
            raise FixtureError("Invalid --provider-jar.") from None
        devices = json.loads(self.command(["xcrun", "simctl", "list", "devices", "--json"]))
        if not any(
            item["udid"] == self.args.simulator and item.get("isAvailable")
            for group in devices["devices"].values()
            for item in group
        ):
            raise FixtureError("The selected simulator does not exist or is unavailable.")

    def sql(self, sql, database="postgres", user="fixture"):
        return self.command(
            ["psql", "-X", "-v", "ON_ERROR_STOP=1", "-h", "127.0.0.1", "-p", self.pg_port, "-U", user, "-d", database],
            env={**self.env, "PGPASSWORD": self.password},
            data=sql.encode(),
        )

    def database(self):
        self.stage = "PostgreSQL initialization"
        (self.work / "pg-password").write_text(self.password)
        self.command(
            [
                "initdb",
                "-D",
                self.work / "pg",
                "--username=fixture",
                "--auth-local=scram-sha-256",
                "--auth-host=scram-sha-256",
                "--pwfile",
                self.work / "pg-password",
                "--encoding=UTF8",
                "--no-locale",
            ]
        )
        # macOS sockaddr_un paths cannot fit a deep checkout; disable Unix sockets.
        self.start(["postgres", "-D", self.work / "pg", "-k", "", "-h", "127.0.0.1", "-p", self.pg_port])
        self.wait("PostgreSQL", lambda: self.sql("SELECT 1;"))
        # Use the production role/database bootstrap, but only inside this fresh cluster.
        self.command(
            [
                "psql",
                "-X",
                "-v",
                "ON_ERROR_STOP=1",
                "-h",
                "127.0.0.1",
                "-p",
                self.pg_port,
                "-U",
                "fixture",
                "-d",
                "postgres",
                "-f",
                ROOT / "deploy/postgres/init.sql",
            ],
            env={
                **self.env,
                **{
                    name: self.password
                    for name in (
                        "PGPASSWORD",
                        "LIBRARY_OWNER_PASSWORD",
                        "LIBRARY_APP_PASSWORD",
                        "STORAGE_OWNER_PASSWORD",
                        "STORAGE_APP_PASSWORD",
                        "KEYCLOAK_DB_PASSWORD",
                    )
                },
            },
        )
        for project in ("Nephos.Migrations", "Nephos.Library.Api"):
            self.stage = f"building {project}"
            path = ROOT / "src" / project / f"{project}.csproj"
            self.command(["dotnet", "restore", path, "--locked-mode", "--disable-build-servers"], timeout=600)
            self.command(
                [
                    "dotnet",
                    "build",
                    path,
                    "-c",
                    "Release",
                    "--no-restore",
                    "--nologo",
                    "-v:q",
                    "--disable-build-servers",
                    "-p:UseSharedCompilation=false",
                ],
                timeout=600,
            )
        self.stage = "actual Library migrations"
        self.command(
            ["dotnet", ROOT / "src/Nephos.Migrations/bin/Release/net10.0/Nephos.Migrations.dll", "library"],
            env={**self.env, "MIGRATION_CONNECTION": self.connection("library_owner")},
        )

    def connection(self, user):
        return f"Host=127.0.0.1;Port={self.pg_port};Database=library;Username={user};Password={self.password}"

    def certificates(self):
        self.stage = "loopback CA and simulator trust"
        self.command(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "2",
                "-keyout",
                self.work / "ca.key",
                "-out",
                self.work / "ca.pem",
                "-subj",
                "/CN=Nephos disposable native qualification CA",
                "-addext",
                "basicConstraints=critical,CA:TRUE",
                "-addext",
                "keyUsage=critical,keyCertSign,cRLSign",
            ]
        )
        self.command(
            [
                "openssl",
                "req",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                self.work / "edge.key",
                "-out",
                self.work / "edge.csr",
                "-subj",
                "/CN=localhost",
            ]
        )
        (self.work / "edge.ext").write_text(
            "subjectAltName=DNS:localhost,IP:127.0.0.1\n"
            "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\n"
        )
        self.command(
            [
                "openssl",
                "x509",
                "-req",
                "-in",
                self.work / "edge.csr",
                "-CA",
                self.work / "ca.pem",
                "-CAkey",
                self.work / "ca.key",
                "-CAcreateserial",
                "-days",
                "2",
                "-extfile",
                self.work / "edge.ext",
                "-out",
                self.work / "edge.pem",
            ]
        )
        # Do not touch any host keychain or disable TLS validation.
        devices = json.loads(self.command(["xcrun", "simctl", "list", "devices", "--json"]))
        selected = next(
            item for group in devices["devices"].values() for item in group if item["udid"] == self.args.simulator
        )
        if selected["state"] != "Booted":
            self.command(["xcrun", "simctl", "boot", self.args.simulator])
        self.command(["xcrun", "simctl", "bootstatus", self.args.simulator, "-b"], timeout=300)
        self.command(["xcrun", "simctl", "keychain", self.args.simulator, "add-root-cert", self.work / "ca.pem"])

    def services(self):
        self.stage = "Keycloak production-mode startup"
        kc = self.work / "keycloak"
        shutil.copytree(self.args.keycloak_dist.resolve(), kc)
        shutil.copy2(self.args.provider_jar, kc / "providers/nephos-keycloak-pin-provider.jar")
        imports = kc / "data/import"
        imports.mkdir(parents=True, exist_ok=True)
        realm = json.loads((ROOT / "deploy/keycloak/nephos-realm.json").read_text())
        realm["clients"].append(
            {
                "clientId": "nephos-api-introspection",
                "enabled": True,
                "protocol": "openid-connect",
                "publicClient": False,
                "secret": self.introspection_secret,
                "standardFlowEnabled": False,
                "directAccessGrantsEnabled": False,
                "implicitFlowEnabled": False,
                "serviceAccountsEnabled": False,
            }
        )
        (imports / "nephos-realm.json").write_text(json.dumps(realm))
        kc_env = {
            **self.env,
            "KC_DB": "postgres",
            "KC_DB_URL": f"jdbc:postgresql://127.0.0.1:{self.pg_port}/keycloak",
            "KC_DB_USERNAME": "keycloak",
            "KC_DB_PASSWORD": self.password,
            "KC_BOOTSTRAP_ADMIN_USERNAME": "fixture",
            "KC_BOOTSTRAP_ADMIN_PASSWORD": self.password,
            "KC_HTTP_ENABLED": "true",
            "KC_HTTP_HOST": "127.0.0.1",
            "KC_HTTP_PORT": str(self.kc_port),
            "KC_HOSTNAME": self.origin,
            "KC_HOSTNAME_BACKCHANNEL_DYNAMIC": "true",
            "KC_PROXY_HEADERS": "xforwarded",
            "IDENTITY_ADMIN_SERVICE_KEY": self.service_key,
            "NEPHOS_PIN_PEPPER": secrets.token_hex(32),
            "NEPHOS_PUBLIC_ORIGIN": self.origin,
            "NEPHOS_QR_DELIVERY_KEY": base64.b64encode(secrets.token_bytes(32)).decode(),
            "JAVA_OPTS_KC_HEAP": "-Xms128m -Xmx768m",
        }
        self.command([kc / "bin/kc.sh", "build", "--db=postgres"], env=kc_env, timeout=300)
        self.start([kc / "bin/kc.sh", "start", "--optimized", "--import-realm"], env=kc_env)
        discovery_url = self.identity + "/realms/nephos/.well-known/openid-configuration"
        self.wait("real Keycloak imported realm", lambda: self.request(discovery_url), timeout=240)
        discovery = self.request(discovery_url)
        if discovery["issuer"] != self.origin + "/realms/nephos":
            raise FixtureError("Keycloak does not advertise the canonical HTTPS issuer.")
        # Production compose uses private HTTP backchannel metadata and HTTPS token issuer.
        # Dynamic backchannel URLs must stay private: no host trust bypass is permitted.
        if not discovery["jwks_uri"].startswith(self.identity + "/"):
            raise FixtureError("Keycloak private backchannel JWKS is not local HTTP.")
        self.stage = "actual Library API startup"
        self.start(
            ["dotnet", ROOT / "src/Nephos.Library.Api/bin/Release/net10.0/Nephos.Library.Api.dll"],
            env={
                **self.env,
                "ASPNETCORE_ENVIRONMENT": "Development",
                "ASPNETCORE_URLS": f"http://127.0.0.1:{self.api_port}",
                "ConnectionStrings__Library": self.connection("library_app"),
                "Authentication__Authority": self.origin + "/realms/nephos",
                "Authentication__MetadataAddress": discovery_url,
                "Authentication__Audience": "nephos-api",
                "Authentication__IntrospectionEndpoint": self.identity
                + "/realms/nephos/protocol/openid-connect/token/introspect",
                "Authentication__IntrospectionClientId": "nephos-api-introspection",
                "Authentication__IntrospectionClientSecret": self.introspection_secret,
                "Platform__ServerId": "native-qr-ci",
                "Worker__Enabled": "false",
                "Analysis__Enabled": "false",
                "Administration__Enabled": "false",
                "Logging__LogLevel__Default": "Warning",
                "Telemetry__TraceSampleRatio": "0",
            },
        )

        def library_ready():
            with urllib.request.urlopen(f"http://127.0.0.1:{self.api_port}/health/ready", timeout=5) as response:
                return response.status == 200

        self.wait("actual Library persistence health", library_ready)
        self.stage = "trusted loopback HTTPS edge"
        config = self.work / "Caddyfile"
        config.write_text(
            "{\n admin off\n auto_https disable_redirects\n}\n"
            f"{self.origin} {{\n bind 127.0.0.1\n"
            f" tls {self.work / 'edge.pem'} {self.work / 'edge.key'}\n"
            f" handle /v1/* {{\n reverse_proxy 127.0.0.1:{self.api_port}\n }}\n"
            f" handle /realms/nephos/* {{\n reverse_proxy 127.0.0.1:{self.kc_port}\n }}\n"
            f" handle /resources/* {{\n reverse_proxy 127.0.0.1:{self.kc_port}\n }}\n"
            ' handle {\n respond "Not found" 404\n }\n}\n'
        )
        self.start(
            ["caddy", "run", "--config", config, "--adapter", "caddyfile"],
            env={
                **self.env,
                "XDG_DATA_HOME": str(self.work / "caddy-data"),
                "XDG_CONFIG_HOME": str(self.work / "caddy-config"),
            },
        )
        self.wait("trusted HTTPS Library config", lambda: self.request(self.origin + "/v1/config"))
        config_data = self.request(self.origin + "/v1/config")
        if (
            config_data["issuer"] != self.origin + "/realms/nephos"
            or config_data["clientId"] != "nephos-ios"
            or config_data["chunkSize"] != 4194304
        ):
            raise FixtureError("Real Library configuration violates the native QR contract.")
        public_discovery = self.request(self.origin + "/realms/nephos/.well-known/openid-configuration")
        if not public_discovery["jwks_uri"].startswith(self.origin + "/"):
            raise FixtureError("Public OIDC discovery does not advertise trusted HTTPS.")
        enrollment = self.request(self.origin + "/realms/nephos/nephos-admin/enrollment/config")
        if enrollment["origin"] != self.origin or enrollment["issuer"] != config_data["issuer"]:
            raise FixtureError("Provider enrollment configuration disagrees with the real Library API.")

    def invitation(self):
        self.stage = "real provider user provisioning"
        subject = str(uuid.uuid4())
        library = str(uuid.uuid4())
        base = self.identity + "/realms/nephos/nephos-admin/users/" + subject
        headers = {"X-Nephos-Identity-Service-Key": self.service_key}
        user = self.request(
            base + "/provision",
            {
                "commandId": str(uuid.uuid4()),
                "requestHash": hashlib.sha256(subject.encode()).hexdigest(),
                "login": "native-" + uuid.uuid4().hex,
                "displayName": "Native QR qualification",
            },
            method="PUT",
            headers=headers,
            expected=201,
        )
        self.stage = "real provider user enabling"
        self.request(
            base + "/access",
            {"commandId": str(uuid.uuid4()), "expectedRevision": user["revision"], "enabled": True},
            method="PUT",
            headers=headers,
        )
        self.stage = "real Library membership seeding"
        self.sql(
            f"INSERT INTO principals(subject,enabled) VALUES ('{subject}',true);"
            f"INSERT INTO libraries(id,name) VALUES ('{library}','Native QR library');"
            f"INSERT INTO library_members(subject,library_id) VALUES ('{subject}','{library}');",
            database="library",
            user="library_owner",
        )
        self.stage = "real provider invitation creation"
        invitation = self.request(
            base + "/invitations", {"commandId": str(uuid.uuid4())}, headers=headers, expected=201
        )
        if set(invitation["qr"]) != {"v", "origin", "inviteId", "secret"}:
            raise FixtureError("Provider did not return the canonical real invitation QR.")
        import qrcode

        image = self.work / "invitation.png"
        qrcode.make(json.dumps(invitation["qr"], separators=(",", ":"))).save(image)
        self.invitation_base = base
        return image

    def qualify(self, image):
        self.stage = "native QR, real token exchange and gallery"
        # The native harness prints only build/test diagnostics, never provider credentials.
        child = subprocess.Popen(
            [
                sys.executable,
                str(ROOT / "ios/qr_qualification.py"),
                "--simulator",
                self.args.simulator,
                "--qr-image",
                str(image),
            ],
            cwd=ROOT,
            env=self.env,
            start_new_session=True,
        )
        self.children.append(child)
        code = child.wait(timeout=self.args.native_timeout)
        if code:
            invitations = self.request(
                self.invitation_base + "/invitations",
                headers={"X-Nephos-Identity-Service-Key": self.service_key},
            )
            statuses = sorted({item["status"] for item in invitations["invitations"]})
            print("Real provider invitation status: " + ", ".join(statuses), file=sys.stderr)
            raise FixtureError(f"Native qualification exited {code}.")

    def close(self):
        for child in reversed(self.children):
            if child.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGTERM)
        for child in reversed(self.children):
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=10)
        # This CA belongs only to this dedicated CI simulator. Never reset a shared keychain.
        if self.work.exists():
            shutil.rmtree(self.work)

    def diagnostics(self):
        # Exception classes and our Java source locations are useful without exposing
        # log messages, request bodies, SQL parameters, URLs, tokens, or stack locals.
        names = set()
        for path in self.work.glob("process-*.log"):
            text = path.read_text(errors="replace")
            names.update(re.findall(r"\b([A-Za-z][\w.$]*(?:Exception|Error)):", text))
            names.update(re.findall(r"\bat (app\.nephos\.keycloak\.[\w.$]+\([\w.]+\.java:\d+\))", text))
        if names:
            print("Sanitized service exception locations: " + ", ".join(sorted(names)), file=sys.stderr)

    def run(self):
        self.preflight()
        self.work.mkdir(parents=True, mode=0o700)
        try:
            print("Preparing isolated PostgreSQL and actual Library migrations.", flush=True)
            self.database()
            print("Installing fixture CA in the dedicated simulator.", flush=True)
            self.certificates()
            print("Starting real Keycloak, Library API and trusted loopback HTTPS edge.", flush=True)
            self.services()
            print("Issuing private real invitation and running native qualification.", flush=True)
            self.qualify(self.invitation())
        except BaseException:
            self.diagnostics()
            raise
        finally:
            self.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="Dedicated disposable CI simulator UUID.")
    parser.add_argument("--keycloak-dist", required=True, type=Path, help="Pinned extracted 26.8.1 JVM distribution.")
    parser.add_argument("--provider-jar", required=True, type=Path, help="Provider artifact built from this checkout.")
    parser.add_argument("--native-timeout", type=int, default=1200)
    args = parser.parse_args()
    if args.native_timeout <= 0:
        parser.error("--native-timeout must be positive.")
    os.umask(0o077)

    def interrupted(signum, frame):
        raise FixtureError("Native fixture interrupted; cleaning private services.")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        Fixture(args).run()
    except (FixtureError, OSError, subprocess.TimeoutExpired) as error:
        print(f"Native QR CI failed: {error}", file=sys.stderr)
        return 1
    print("Native real-service QR qualification passed; disposable services and secrets removed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
