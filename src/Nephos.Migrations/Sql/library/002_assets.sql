CREATE TABLE assets (
    id uuid PRIMARY KEY,
    library_id uuid NOT NULL REFERENCES libraries(id),
    uploaded_by text NOT NULL REFERENCES principals(subject),
    file_name text NOT NULL,
    media_type text NOT NULL,
    size bigint NOT NULL,
    sha256 text NOT NULL,
    has_preview boolean NOT NULL,
    created_at timestamptz NOT NULL
);
CREATE INDEX assets_chronology ON assets(library_id, created_at DESC, id DESC);
GRANT SELECT, INSERT ON assets TO library_app;
