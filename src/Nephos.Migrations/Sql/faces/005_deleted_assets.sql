CREATE TABLE deleted_assets (
    owner text NOT NULL,
    asset_id uuid NOT NULL,
    deleted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(owner,asset_id)
);
GRANT SELECT, INSERT ON deleted_assets TO faces_app;
GRANT DELETE ON observations, corrections TO faces_app;
