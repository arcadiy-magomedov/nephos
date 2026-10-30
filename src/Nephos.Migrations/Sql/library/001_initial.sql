CREATE TABLE principals (
    subject text PRIMARY KEY,
    enabled boolean NOT NULL DEFAULT false
);

CREATE TABLE libraries (
    id uuid PRIMARY KEY,
    name text NOT NULL CHECK (length(name) BETWEEN 1 AND 200)
);

CREATE TABLE library_members (
    subject text NOT NULL REFERENCES principals(subject),
    library_id uuid NOT NULL REFERENCES libraries(id),
    PRIMARY KEY (subject, library_id)
);

GRANT SELECT ON principals, libraries, library_members TO library_app;
