# Development and validation

Use Python 3.12+, the .NET SDK pinned in `global.json`, JDK 21/Maven,
Node.js 24 and Xcode for native builds.

## Coding checks

Checks use established presets: recommended .NET SDK analyzers;
Ruff E/F/I/UP/B/SIM/C4/RUF; SwiftLint defaults plus swift-format;
ESLint recommended; Stylelint standard; SpotBugs; yamllint; actionlint and
ShellCheck. Compiler warnings fail builds and lint warnings fail CI.
Narrow exceptions document protocol names, platform APIs, test naming or
formatter ownership. There is no grandfathered warning baseline.

```sh
python3.12 -m venv .venv
. .venv/bin/activate
python -m pip install -r scripts/quality-requirements.txt -r scripts/admin-requirements.txt
ruff check .
ruff format --check .
yamllint -s .github compose*.yaml deploy tests/alert-rules.test.yaml .yamllint.yaml
actionlint
shellcheck .githooks/pre-commit .githooks/pre-push
dotnet restore Nephos.slnx --locked-mode
dotnet format Nephos.slnx --verify-no-changes --no-restore
npm ci --prefix scripts/admin-static
npm run lint --prefix scripts/admin-static
mvn -B -q -f deploy/keycloak/pin-provider/pom.xml clean verify
swift format lint --strict --recursive ios/Nephos ios/Tests ios/Qualification ios/Package.swift
swiftlint lint --strict --config .swiftlint.yml
python scripts/secret_scan.py --history
```

Scanner versions are pinned in CI: Gitleaks 8.30.1, actionlint 1.7.12 and
SwiftLint 0.65.1. Install these and ShellCheck locally.
Use `ruff format .`, `swift format format --in-place --recursive <paths>` and
`npm run format --prefix scripts/admin-static` for formatting.

Enable repository hooks with `git config core.hooksPath .githooks`, integrating
manually if other hooks are installed. Pre-commit scans index bytes; pre-push also
scans history. Scanner failure blocks publication. Never stage secrets, private
keys, personal media, model downloads, simulator data or backups.

## Tests

```sh
dotnet build Nephos.slnx -c Release --no-restore
OTEL_SDK_DISABLED=true dotnet test Nephos.slnx -c Release --no-build
python tests/run_backend_integration.py
python -m unittest discover -s scripts -p 'test_*.py'
python -m unittest discover -s ios -p 'test_*.py'
PYTHONPATH=face-inference python -m unittest test_worker_pool test_api_versions
swift test --package-path ios
swift test --package-path ios -c release --scratch-path ios/.build-release
```

The backend integration runner creates and migrates three fresh databases,
runs the complete suites and removes its own disposable resources.
Normal CI uses deterministic inference fixtures, not heavyweight model downloads.
Real-model evaluation is explicit opt-in; see [face analysis](face-analysis.md).
The iOS guide covers [simulator and native qualification](ios-client.md#run-and-check).

Append SQL migrations instead of changing applied migrations. Runtime APIs use
repositories; owner credentials belong only to migration/administration processes.

## End-to-end qualification

Run smoke scripts only in a disposable local stack. They create/remove test
accounts and media and can interrupt services. They are not production probes.

The CI workflow contains the canonical commands for upload/recovery, sharing,
private administration, browser passkeys, identity, low-storage, backup/restore
and observability checks. See [administrator console](admin-console.md#qualification-and-release-gates),
[private administration](administration.md#verification) and
[native QR CI](native-qr-ci.md) for specialized fixtures.

Every required job must pass on the exact release commit. Simulator checks do
not qualify physical-camera scanning, Secure Enclave, Photos deletion, guaranteed
background scheduling or a live HTTPS deployment. Production signing and physical
device acceptance remain release gates.
