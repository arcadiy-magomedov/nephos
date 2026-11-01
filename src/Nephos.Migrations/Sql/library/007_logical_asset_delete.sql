ALTER TABLE assets ADD COLUMN deleted_at timestamptz;
ALTER TABLE assets ADD COLUMN purge_started_at timestamptz;
ALTER TABLE assets ADD COLUMN purged_at timestamptz;
ALTER TABLE assets ADD COLUMN purge_lease_id uuid;
ALTER TABLE assets ADD COLUMN purge_lease_until timestamptz;
CREATE INDEX assets_trash ON assets(uploaded_by,deleted_at DESC,id DESC)
    WHERE deleted_at IS NOT NULL AND purged_at IS NULL;
CREATE INDEX assets_purge ON assets(deleted_at,purge_lease_until)
    WHERE deleted_at IS NOT NULL AND purged_at IS NULL;

CREATE TABLE face_deletions (
    asset_id uuid PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    subject text NOT NULL REFERENCES principals(subject),
    lease_id uuid,
    lease_until timestamptz,
    attempts integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    last_status integer
);
CREATE INDEX face_deletions_pending ON face_deletions(next_attempt_at,lease_until);
GRANT SELECT, INSERT, UPDATE, DELETE ON face_deletions TO library_app;

CREATE OR REPLACE VIEW analysis_sources AS
SELECT a.id,a.library_id,a.uploaded_by AS subject,a.media_type,a.size,a.sha256
FROM assets a
JOIN principals p ON p.subject=a.uploaded_by AND p.enabled
JOIN library_members m ON m.library_id=a.library_id AND m.subject=a.uploaded_by
WHERE a.deleted_at IS NULL AND NOT a.hidden
  AND a.media_type IN ('image/jpeg','image/png','image/webp','image/heic','image/heif')
  AND a.size BETWEEN 1 AND 20971520
  AND (a.pending_resource_set_id IS NULL OR EXISTS(
      SELECT 1 FROM resource_sets s WHERE s.id=a.resource_set_id AND s.primary_asset_id=a.id));
