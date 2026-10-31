# API compatibility

## Version boundaries

Public application HTTP contracts use a major version in the URL: `/v1/...`.
Library, Storage and Faces currently implement v1. New incompatible contracts
must use `/v2/...` alongside v1, not replace the v1 implementation in place.
There is no implicit "latest" version or fallback from an unsupported major.
Infrastructure health/metrics and the identity provider's own OIDC endpoints are
not application API versions.

Private Library, Storage and Faces endpoints use `/internal/v1/...`.
Their historical `/internal/...` aliases invoke the **same v1 handler and
endpoint conventions**, including authorization. Legacy responses include a
`Link` to the versioned successor. These aliases are permanently pinned to v1;
they must never be repointed to v2.

The private image services expose `/v1/infer` and `/v1/render`; `/infer` and
`/render` remain v1-only compatibility aliases. Versioned and legacy paths have
identical peer authentication and bounded input/processing. Neither private API
is published through the internet gateway.

## Changes within v1

- Preserve field names, types, nullability, requiredness and established meaning.
  Clients must ignore unknown optional response fields. Do not assume that old
  clients tolerate new enum values.
- Preserve status codes, authentication/authorization, idempotency, pagination,
  upload receipts and retry semantics. Security corrections may restrict
  previously unauthorized behavior, but must be called out explicitly.
- Internal refactoring, repository/database changes and implementation fixes do
  not by themselves require a new HTTP major version.
- Model weights, embedding/pipeline versions, events and database migrations have
  separate compatibility boundaries. A new face model does not automatically
  create HTTP v2; incompatible embeddings must still be kept separate.

## Deployment and retirement

Deploy receiving services with versioned routes before enabling new callers.
Old callers remain supported by the aliases. This first migration changes both
sides: use a coordinated Compose update of Library, Storage, Faces, their workers,
admin console and image services, or split route introduction and caller rollout
into separate deployment phases. An old receiver does not understand the new
path; there is deliberately no unsafe retry of writes against a legacy path.

Keep v1 while deployed native clients or peers still depend on it. Retirement
requires an explicit release/migration decision, announced support window and
client update path; adding v2 alone does not authorize deleting v1.

## Regression protection

`ApiContractTests` protects the public discovery wire contract, explicit major
selection, legacy/versioned handler equivalence and shared endpoint filters.
Analysis/client tests protect peer keys, owner boundaries and versioned URLs.
`face-inference/test_api_versions.py` exercises both image-service paths and
rejects unsupported versions before processing. Existing API authorization,
upload, sharing and native end-to-end tests remain required for affected v1
behavior. These checks are not a complete OpenAPI/schema compatibility diff;
new or changed endpoints need their own request/response contract tests.
