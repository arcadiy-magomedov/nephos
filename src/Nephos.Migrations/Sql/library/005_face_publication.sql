CREATE TABLE face_publications (
    asset_id uuid PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    attempts integer NOT NULL DEFAULT 0,
    lease_id uuid,
    lease_until timestamptz,
    delivered_at timestamptz,
    last_status integer
);
CREATE INDEX face_publications_pending ON face_publications(next_attempt_at)
    WHERE delivered_at IS NULL;
GRANT SELECT,INSERT,UPDATE ON face_publications TO library_app;

CREATE VIEW analysis_sources AS
SELECT a.id,a.library_id,a.uploaded_by AS subject,a.media_type,a.size,a.sha256
FROM assets a
JOIN principals p ON p.subject=a.uploaded_by AND p.enabled
JOIN library_members m ON m.library_id=a.library_id AND m.subject=a.uploaded_by
WHERE NOT a.hidden AND a.media_type IN ('image/jpeg','image/png','image/webp')
  AND a.size BETWEEN 1 AND 20971520
  AND (a.pending_resource_set_id IS NULL OR EXISTS(
      SELECT 1 FROM resource_sets s WHERE s.id=a.resource_set_id AND s.primary_asset_id=a.id));
GRANT SELECT ON analysis_sources TO library_app;

INSERT INTO face_publications(asset_id) SELECT id FROM analysis_sources;
