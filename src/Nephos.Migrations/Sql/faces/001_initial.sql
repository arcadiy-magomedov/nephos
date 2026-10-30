CREATE TABLE jobs (
    id uuid PRIMARY KEY,
    owner text NOT NULL,
    asset_id uuid NOT NULL,
    source_sha256 text NOT NULL CHECK (source_sha256 ~ '^[0-9a-f]{64}$'),
    pipeline_version text NOT NULL,
    status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','complete','no_faces','error','denied')),
    attempts integer NOT NULL DEFAULT 0,
    error text,
    lease_token uuid,
    lease_until timestamptz,
    available_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(owner, asset_id, source_sha256, pipeline_version)
);
CREATE INDEX jobs_claim ON jobs(available_at) WHERE status IN ('queued','running');
CREATE INDEX jobs_owner ON jobs(owner,id);

CREATE TABLE people (
    id uuid PRIMARY KEY,
    owner text NOT NULL,
    name text,
    aliases text[] NOT NULL DEFAULT '{}',
    redirect_id uuid REFERENCES people(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(owner,id)
);
CREATE INDEX people_owner ON people(owner,id);

CREATE TABLE face_tracks (
    id uuid PRIMARY KEY,
    owner text NOT NULL,
    asset_id uuid NOT NULL,
    source_sha256 text NOT NULL,
    x double precision NOT NULL,
    y double precision NOT NULL,
    width double precision NOT NULL,
    height double precision NOT NULL,
    manual_override boolean NOT NULL DEFAULT false,
    manual_person_id uuid REFERENCES people(id),
    UNIQUE(owner,id)
);
CREATE INDEX face_tracks_asset ON face_tracks(owner,asset_id);

CREATE TABLE observations (
    id uuid PRIMARY KEY,
    job_id uuid NOT NULL REFERENCES jobs(id),
    track_id uuid NOT NULL REFERENCES face_tracks(id),
    owner text NOT NULL,
    generated_person_id uuid REFERENCES people(id),
    embedding real[],
    quality text NOT NULL,
    confidence double precision NOT NULL,
    x double precision NOT NULL,
    y double precision NOT NULL,
    width double precision NOT NULL,
    height double precision NOT NULL,
    image_width integer NOT NULL,
    image_height integer NOT NULL,
    model_version text NOT NULL,
    preprocess_version text NOT NULL,
    UNIQUE(job_id,track_id),
    FOREIGN KEY(owner,track_id) REFERENCES face_tracks(owner,id),
    FOREIGN KEY(owner,generated_person_id) REFERENCES people(owner,id)
);
CREATE INDEX observations_owner ON observations(owner,job_id);

CREATE TABLE negative_matches (
    owner text NOT NULL,
    person_id uuid NOT NULL,
    other_id uuid NOT NULL,
    PRIMARY KEY(owner,person_id,other_id),
    FOREIGN KEY(owner,person_id) REFERENCES people(owner,id),
    FOREIGN KEY(owner,other_id) REFERENCES people(owner,id)
);
CREATE TABLE track_exclusions (
    owner text NOT NULL,
    track_id uuid NOT NULL,
    person_id uuid NOT NULL,
    PRIMARY KEY(owner,track_id,person_id),
    FOREIGN KEY(owner,track_id) REFERENCES face_tracks(owner,id),
    FOREIGN KEY(owner,person_id) REFERENCES people(owner,id)
);
CREATE TABLE corrections (
    id uuid PRIMARY KEY,
    owner text NOT NULL,
    kind text NOT NULL,
    subject_id uuid NOT NULL,
    target_id uuid,
    details jsonb NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX corrections_owner ON corrections(owner,id);

CREATE FUNCTION resolve_person(scope text, person uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
    WITH RECURSIVE chain AS (
        SELECT id, redirect_id, 0 AS depth FROM people WHERE owner=scope AND id=person
        UNION ALL
        SELECT p.id,p.redirect_id,c.depth+1 FROM people p JOIN chain c ON p.id=c.redirect_id
        WHERE p.owner=scope AND c.depth<32
    ) SELECT id FROM chain WHERE redirect_id IS NULL ORDER BY depth DESC LIMIT 1
$$;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO faces_app;
