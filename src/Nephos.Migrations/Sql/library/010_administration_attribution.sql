ALTER TABLE administration_operations ADD COLUMN operator_subject text;
CREATE TABLE administration_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid REFERENCES administration_operations(id),
    operator_subject text,
    action text NOT NULL,
    error_code text,
    occurred_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON administration_events TO library_app;
