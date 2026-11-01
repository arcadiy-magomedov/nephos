# Deleted resource cleanup

`Nephos.Cleanup` is a separate scheduled job. It has no database credentials or
media mount and talks only to internal service APIs. Compose runs it immediately
and then every 24 hours (configurable `Cleanup__IntervalHours`, minimum 1).
Failures retry on the next schedule; one failed asset does not stop other claims.
Restarting is safe. The Faces compose
overlay supplies `Services__Faces`; keep this configured whenever Faces data
exists, even if new analysis is disabled.

For a host scheduler, disable the Compose daemon and run once daily:

```sh
docker compose stop cleanup
docker compose run --rm --no-deps cleanup Nephos.Cleanup.dll --once
```

`--once` exits nonzero on failure. An external daily cron can invoke that command.
Do not run a daemon and cron concurrently unnecessarily. No Helm deployment
exists here; deployments can schedule the same `--once` executable.

Required configuration: `Services__Library`, `Services__Storage`,
`Services__Key` (existing internal key, at least 32 characters). Optional
`Services__Faces` is required for installations with Faces data.
`Cleanup__MaxClaims` bounds work per invocation (default 10000).
Internal service URLs are not public ingress routes. Use HTTPS or a trusted
isolated service network; never log/expose the service key.

## Contracts and retention

All routes use `X-Nephos-Service-Key` and canonical `/internal/v1` paths:

- Library `POST /cleanup/claim`: 204 when empty; otherwise
  `{assetId,subject,leaseId}`. Library atomically claims only assets deleted at
  least 30 days ago, irreversibly rejects restore after claim, and re-leases
  unfinished work on the 10-minute lease expiry. Compound resource members are claimed
  individually. The cleanup service never supplies hashes or computes eligibility.
- Storage `DELETE /cleanup/{assetId}`, body `{subject}`: 204 after durable
  reference release; idempotent, including unknown IDs. Ownership mismatches and
  active upload/publication return 409. A permanent storage release marker
  prevents later reuse of the upload ID. The database, not the caller, determines
  the exact reference. This does not immediately promise physical deletion.
- Faces `DELETE /faces/assets/{assetId}`, body `{subject}`: remove per-asset
  analysis before Library completion when configured.
- Library `POST /cleanup/{assetId}/complete`, body `{leaseId}`: 204; 409 for a
  stale or expired current lease. The same completed lease remains idempotent.
  Assets and sync deletion tombstones remain permanently.
- Storage `POST /cleanup/gc`: `{collected}` (up to 100 per request). Runs even
  when no Library claims remain or a claim request failed, so expired holds
  eventually release bytes.

Logical delete does **not** release storage references or remove files. After a
claim, Storage removes only that upload's reference. Other references, unexpired
retention holds, active uploading/verifying intents and unsent outbox entries all
block physical GC. Holds remain in storage after reference release. All original
and fixed-size preview variants are removed together only when safe.

## Crash/race safety

Reference/intent creation, verification/file publication, retention creation,
preview regeneration, release and GC use one PostgreSQL advisory gate. GC first
commits `blobs.deleting=true`; new intents cannot use that hash until GC finishes.
It then reacquires the gate, rechecks eligibility, idempotently unlinks and fsyncs
file directories, and deletes the blob metadata. A crash during unlink or before
metadata commit leaves the durable deleting fence; the next scheduled GC finishes
it before writers can reuse those bytes. Released upload metadata/outbox and hold
records remain for idempotency/audit; old released IDs cannot resurrect resources.
No cleanup code writes another service's database.

Deploy the storage migration and upgraded Storage API **and worker** together
before enabling cleanup. Do not run older verification workers alongside GC:
they predate the shared publication gate.

The global gate deliberately favors correctness and a simple MVP implementation
over concurrent large verification/cleanup throughput. Monitor cleanup errors
and backlog; do not manually clear `deleting` fences after an interrupted unlink.

## Tests

Run the targeted unit/service tests:

```sh
dotnet test tests/Nephos.Tests --filter FullyQualifiedName~Cleanup
```

Storage persistence tests additionally require `STORAGE_CLEANUP_TEST_CONNECTION`
(app role) and `STORAGE_CLEANUP_TEST_ADMIN_CONNECTION` (fixture teardown only)
pointing to a **disposable, separately migrated storage database**. The tests
insert unique IDs and hashes and remove only their own fixtures; they never
reset a live database. See `scripts/cleanup-tests.py` for isolated container
validation.
