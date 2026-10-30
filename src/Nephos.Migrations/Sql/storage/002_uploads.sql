CREATE TABLE uploads (
    id uuid PRIMARY KEY,
    subject text NOT NULL,
    library_id uuid NOT NULL,
    file_name text NOT NULL,
    media_type text NOT NULL,
    size bigint NOT NULL CHECK (size > 0 AND size <= 8589934592),
    expected_hash text NOT NULL,
    state text NOT NULL CHECK (state IN ('uploading', 'verifying', 'stored', 'failed')),
    sha256 text,
    has_preview boolean NOT NULL DEFAULT false,
    staging_cleaned boolean NOT NULL DEFAULT false,
    error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX uploads_pending ON uploads(state, created_at);
CREATE INDEX uploads_owner_hash ON uploads(subject, library_id, expected_hash) WHERE state='stored';
CREATE TABLE upload_parts (
    upload_id uuid NOT NULL REFERENCES uploads(id),
    part integer NOT NULL CHECK (part >= 0),
    sha256 text NOT NULL,
    PRIMARY KEY(upload_id, part)
);
CREATE TABLE blobs (
    sha256 text PRIMARY KEY,
    size bigint NOT NULL CHECK (size > 0),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE blob_references (
    asset_id uuid PRIMARY KEY REFERENCES uploads(id),
    sha256 text NOT NULL REFERENCES blobs(sha256)
);
CREATE TABLE outbox (
    id uuid PRIMARY KEY REFERENCES uploads(id),
    payload jsonb NOT NULL,
    sent_at timestamptz
);
CREATE TABLE retention_holds (
    asset_id uuid PRIMARY KEY REFERENCES blob_references(asset_id),
    hold_id uuid NOT NULL,
    retained_until timestamptz NOT NULL
);
GRANT SELECT, INSERT, UPDATE, DELETE ON uploads, upload_parts, blobs, blob_references, outbox TO storage_app;
GRANT SELECT, INSERT, UPDATE ON retention_holds TO storage_app;
