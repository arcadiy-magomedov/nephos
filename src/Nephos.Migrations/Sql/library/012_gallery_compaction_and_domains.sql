ALTER TABLE libraries ADD COLUMN domain text NOT NULL DEFAULT 'photos'
    CHECK (domain IN ('photos', 'cinema', 'books', 'files'));

ALTER TABLE gallery_versions ADD COLUMN closed_at timestamptz;
UPDATE gallery_versions SET closed_at = now() WHERE to_revision IS NOT NULL AND closed_at IS NULL;
CREATE INDEX gallery_versions_compaction ON gallery_versions(library_id, to_revision, closed_at)
    WHERE to_revision IS NOT NULL;

ALTER TABLE gallery_changes ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();
CREATE INDEX gallery_changes_compaction ON gallery_changes(library_id, revision, created_at);

GRANT DELETE ON gallery_versions, gallery_changes TO library_app;

CREATE OR REPLACE VIEW analysis_sources AS
SELECT a.id,a.library_id,a.uploaded_by AS subject,a.media_type,a.size,a.sha256
FROM assets a
JOIN libraries l ON l.id=a.library_id AND l.domain='photos'
JOIN principals p ON p.subject=a.uploaded_by AND p.enabled
JOIN library_members m ON m.library_id=a.library_id AND m.subject=a.uploaded_by
WHERE a.deleted_at IS NULL AND NOT a.hidden
  AND a.media_type IN ('image/jpeg','image/png','image/webp','image/heic','image/heif')
  AND a.size BETWEEN 1 AND 20971520
  AND (a.pending_resource_set_id IS NULL OR EXISTS(
      SELECT 1 FROM resource_sets s WHERE s.id=a.resource_set_id AND s.primary_asset_id=a.id));
