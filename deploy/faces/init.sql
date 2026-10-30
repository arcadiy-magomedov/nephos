\getenv owner_password FACES_OWNER_PASSWORD
\getenv app_password FACES_APP_PASSWORD
CREATE ROLE faces_owner LOGIN PASSWORD :'owner_password';
CREATE ROLE faces_app LOGIN PASSWORD :'app_password';
CREATE DATABASE faces OWNER faces_owner;
REVOKE CONNECT ON DATABASE faces FROM PUBLIC;
GRANT CONNECT ON DATABASE faces TO faces_app;
\connect faces
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO faces_app;
