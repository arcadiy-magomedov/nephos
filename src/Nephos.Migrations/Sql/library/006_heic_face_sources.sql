CREATE OR REPLACE VIEW analysis_sources AS
SELECT a.id,a.library_id,a.uploaded_by AS subject,a.media_type,a.size,a.sha256
FROM assets a
JOIN principals p ON p.subject=a.uploaded_by AND p.enabled
JOIN library_members m ON m.library_id=a.library_id AND m.subject=a.uploaded_by
WHERE NOT a.hidden AND a.media_type IN ('image/jpeg','image/png','image/webp','image/heic','image/heif')
  AND a.size BETWEEN 1 AND 20971520
  AND (a.pending_resource_set_id IS NULL OR EXISTS(
      SELECT 1 FROM resource_sets s WHERE s.id=a.resource_set_id AND s.primary_asset_id=a.id));

INSERT INTO face_publications(asset_id)
SELECT id FROM analysis_sources WHERE media_type IN ('image/heic','image/heif')
ON CONFLICT(asset_id) DO UPDATE SET delivered_at=NULL,next_attempt_at=now(),
    attempts=0,lease_id=NULL,lease_until=NULL,last_status=NULL;
