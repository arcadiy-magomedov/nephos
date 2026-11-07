ALTER TABLE principals ADD COLUMN login text;
ALTER TABLE principals ADD COLUMN admin_revision bigint NOT NULL DEFAULT 0;
ALTER TABLE principals ADD COLUMN identity_revision bigint NOT NULL DEFAULT 0;
ALTER TABLE principals ADD COLUMN identity_synced_at timestamptz;
CREATE UNIQUE INDEX principals_login ON principals(lower(login)) WHERE login IS NOT NULL;
ALTER TABLE libraries ADD COLUMN owner_subject text REFERENCES principals(subject) ON DELETE SET NULL;
ALTER TABLE libraries ADD COLUMN admin_revision bigint NOT NULL DEFAULT 0;
ALTER TABLE libraries ADD COLUMN creation_name text;
UPDATE libraries SET creation_name=name;

-- Historical memberships are not ownership evidence; only unambiguous libraries
-- can be backfilled without granting or removing anyone's existing rights.
UPDATE libraries l SET owner_subject=m.subject
FROM (SELECT library_id,min(subject) subject FROM library_members GROUP BY library_id HAVING count(*)=1) m
WHERE l.id=m.library_id;
CREATE TABLE personal_libraries (
    subject text PRIMARY KEY REFERENCES principals(subject) ON DELETE CASCADE,
    library_id uuid NOT NULL UNIQUE REFERENCES libraries(id) ON DELETE CASCADE
);
INSERT INTO personal_libraries(subject,library_id)
SELECT owner_subject,min(id::text)::uuid FROM libraries
WHERE owner_subject IS NOT NULL GROUP BY owner_subject HAVING count(*)=1;

CREATE TABLE administration_operations (
    id uuid PRIMARY KEY,
    kind text NOT NULL CHECK(kind IN ('provision','profile','access')),
    request_hash text NOT NULL CHECK(length(request_hash)=64),
    login text,
    subject text NOT NULL,
    library_id uuid,
    display_name text,
    discoverable boolean NOT NULL DEFAULT false,
    library_name text,
    desired_enabled boolean NOT NULL DEFAULT true,
    expected_revision bigint,
    provider_revision bigint NOT NULL DEFAULT 0,
    step text NOT NULL DEFAULT 'reserved' CHECK(step IN ('reserved','identity-created','library-created','completed')),
    status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','failed','completed')),
    revision bigint NOT NULL DEFAULT 0,
    attempts integer NOT NULL DEFAULT 0,
    error_code text,
    lease_id uuid,
    lease_until timestamptz,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX administration_login_reservation ON administration_operations(lower(login)) WHERE kind='provision';
CREATE UNIQUE INDEX administration_active_subject ON administration_operations(subject) WHERE status<>'completed';
CREATE INDEX administration_pending ON administration_operations(next_attempt_at,created_at) WHERE status IN ('pending','running');
GRANT SELECT ON administration_operations,personal_libraries TO library_app;
