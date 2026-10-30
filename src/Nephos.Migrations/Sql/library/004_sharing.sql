ALTER TABLE principals ADD COLUMN display_name text;
ALTER TABLE principals ADD COLUMN discoverable boolean NOT NULL DEFAULT false;
ALTER TABLE principals ADD COLUMN share_generation bigint NOT NULL DEFAULT 0;
GRANT UPDATE(share_generation) ON principals TO library_app;

CREATE TABLE shares (
    id uuid PRIMARY KEY,
    library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
    owner_subject text NOT NULL REFERENCES principals(subject) ON DELETE CASCADE,
    recipient_subject text NOT NULL REFERENCES principals(subject) ON DELETE CASCADE,
    all_assets boolean NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK(owner_subject<>recipient_subject),
    UNIQUE(library_id,owner_subject,recipient_subject)
);
CREATE INDEX shares_recipient ON shares(recipient_subject,library_id);
CREATE TABLE share_items (
    share_id uuid NOT NULL REFERENCES shares(id) ON DELETE CASCADE,
    asset_id uuid NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    PRIMARY KEY(share_id,asset_id)
);
CREATE INDEX share_items_asset ON share_items(asset_id,share_id);
GRANT SELECT,INSERT,UPDATE,DELETE ON shares,share_items TO library_app;

CREATE FUNCTION can_read_library(who text, library uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM principals p WHERE p.subject=who AND p.enabled AND (
        EXISTS(SELECT 1 FROM library_members m WHERE m.subject=who AND m.library_id=library)
        OR EXISTS(SELECT 1 FROM shares s JOIN principals owner ON owner.subject=s.owner_subject AND owner.enabled
            JOIN library_members m ON m.subject=s.owner_subject AND m.library_id=s.library_id
            WHERE s.recipient_subject=who AND s.library_id=library)));
$$;
CREATE FUNCTION can_read_asset(who text, asset uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM assets a JOIN principals p ON p.subject=who AND p.enabled
        WHERE a.id=asset AND (
          EXISTS(SELECT 1 FROM library_members m WHERE m.subject=who AND m.library_id=a.library_id)
          OR EXISTS(SELECT 1 FROM shares s JOIN principals owner ON owner.subject=s.owner_subject AND owner.enabled
              JOIN library_members m ON m.subject=s.owner_subject AND m.library_id=s.library_id
              WHERE s.recipient_subject=who AND s.library_id=a.library_id AND s.owner_subject=a.uploaded_by
                AND (s.all_assets OR EXISTS(SELECT 1 FROM share_items i WHERE i.share_id=s.id AND i.asset_id=a.id)))));
$$;
REVOKE ALL ON FUNCTION can_read_library(text,uuid),can_read_asset(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION can_read_library(text,uuid),can_read_asset(text,uuid) TO library_app;
