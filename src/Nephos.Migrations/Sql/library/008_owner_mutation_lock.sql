CREATE FUNCTION lock_asset_owner(who text, asset uuid) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
    SELECT a.library_id FROM assets a
    JOIN principals p ON p.subject=a.uploaded_by AND p.enabled
    JOIN library_members m ON m.library_id=a.library_id AND m.subject=p.subject
    WHERE a.id=asset AND a.uploaded_by=who
    FOR SHARE OF p,m;
$$;
REVOKE ALL ON FUNCTION lock_asset_owner(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION lock_asset_owner(text,uuid) TO library_app;
