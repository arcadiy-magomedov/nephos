CREATE TABLE generated_clusters (
    id uuid PRIMARY KEY,
    owner text NOT NULL,
    pipeline_version text NOT NULL,
    person_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(owner,pipeline_version,person_id),
    UNIQUE(owner,id),
    FOREIGN KEY(owner,person_id) REFERENCES people(owner,id)
);
ALTER TABLE observations ADD COLUMN cluster_id uuid;
ALTER TABLE observations ADD FOREIGN KEY(owner,cluster_id) REFERENCES generated_clusters(owner,id);
ALTER TABLE face_tracks ADD FOREIGN KEY(owner,manual_person_id) REFERENCES people(owner,id);
ALTER TABLE people ADD FOREIGN KEY(owner,redirect_id) REFERENCES people(owner,id);
GRANT SELECT, INSERT, UPDATE, DELETE ON generated_clusters TO faces_app;
