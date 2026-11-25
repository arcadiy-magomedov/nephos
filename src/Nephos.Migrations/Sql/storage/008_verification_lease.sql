ALTER TABLE uploads ADD COLUMN verify_lease_id uuid;
ALTER TABLE uploads ADD COLUMN verify_lease_until timestamptz;
CREATE INDEX uploads_verifying_lease ON uploads(created_at, id) WHERE state = 'verifying';
