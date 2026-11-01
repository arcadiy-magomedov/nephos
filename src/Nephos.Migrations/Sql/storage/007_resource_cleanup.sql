ALTER TABLE uploads ADD COLUMN released_at timestamptz;
ALTER TABLE blobs ADD COLUMN deleting boolean NOT NULL DEFAULT false;
CREATE TABLE cleanup_releases (
    asset_id uuid PRIMARY KEY,
    subject text NOT NULL,
    released_at timestamptz NOT NULL DEFAULT now()
);
-- Holds survive reference release and continue protecting the original.
ALTER TABLE retention_holds DROP CONSTRAINT retention_holds_asset_id_fkey;
ALTER TABLE retention_holds ADD CONSTRAINT retention_holds_asset_id_fkey
    FOREIGN KEY(asset_id) REFERENCES uploads(id);
CREATE INDEX blob_references_hash ON blob_references(sha256);
CREATE INDEX uploads_active_hash ON uploads(expected_hash) WHERE state IN ('uploading','verifying');
GRANT SELECT, INSERT ON cleanup_releases TO storage_app;
