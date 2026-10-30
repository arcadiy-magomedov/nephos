REVOKE ALL ON schema_migrations FROM faces_app;
REVOKE UPDATE, DELETE ON observations, corrections FROM faces_app;
REVOKE ALL ON FUNCTION resolve_person(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION resolve_person(text,uuid) TO faces_app;
