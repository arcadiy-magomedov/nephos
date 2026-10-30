ALTER TABLE principals ADD COLUMN access_generation bigint NOT NULL DEFAULT 0;
ALTER TABLE assets ADD COLUMN resource_set_id uuid;
ALTER TABLE assets ADD COLUMN pending_resource_set_id uuid;
ALTER TABLE assets ADD COLUMN hidden boolean NOT NULL DEFAULT false;

CREATE TABLE gallery_frontiers (
    library_id uuid PRIMARY KEY REFERENCES libraries(id) ON DELETE CASCADE,
    revision bigint NOT NULL DEFAULT 0
);
INSERT INTO gallery_frontiers(library_id,revision)
SELECT l.id,CASE WHEN EXISTS(SELECT 1 FROM assets a WHERE a.library_id=l.id) THEN 1 ELSE 0 END FROM libraries l;

CREATE TABLE gallery_versions (
    library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
    asset_id uuid NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    from_revision bigint NOT NULL,
    to_revision bigint,
    visible boolean NOT NULL,
    created_at timestamptz NOT NULL,
    body jsonb NOT NULL,
    PRIMARY KEY(asset_id,from_revision)
);
CREATE INDEX gallery_versions_page ON gallery_versions(library_id,created_at DESC,asset_id DESC);
CREATE UNIQUE INDEX gallery_versions_current ON gallery_versions(asset_id) WHERE to_revision IS NULL;
INSERT INTO gallery_versions(library_id,asset_id,from_revision,visible,created_at,body)
SELECT library_id,id,1,true,created_at,jsonb_build_object(
    'id',id,'libraryId',library_id,'fileName',file_name,'mediaType',media_type,
    'size',size,'sha256',sha256,'hasPreview',has_preview,'createdAt',created_at,'resourceSetId',NULL)
FROM assets;

CREATE TABLE gallery_changes (
    library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
    revision bigint NOT NULL,
    ordinal integer NOT NULL,
    asset_id uuid NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    operation text NOT NULL CHECK(operation IN ('upsert','remove')),
    body jsonb,
    PRIMARY KEY(library_id,revision,ordinal)
);
CREATE TABLE gallery_snapshots (
    id uuid PRIMARY KEY,
    library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
    subject text NOT NULL REFERENCES principals(subject) ON DELETE CASCADE,
    revision bigint NOT NULL,
    access_generation bigint NOT NULL,
    total_count bigint NOT NULL,
    expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days'
);
CREATE INDEX gallery_snapshots_owner ON gallery_snapshots(library_id,subject,expires_at);
CREATE TABLE resource_sets (
    id uuid PRIMARY KEY,
    library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
    subject text NOT NULL REFERENCES principals(subject),
    primary_asset_id uuid NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    manifest jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT,INSERT,UPDATE ON gallery_frontiers,gallery_versions,gallery_changes,resource_sets TO library_app;
GRANT SELECT,INSERT,UPDATE,DELETE ON gallery_snapshots TO library_app;
GRANT UPDATE ON assets TO library_app;
