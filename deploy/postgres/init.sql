\getenv library_owner_password LIBRARY_OWNER_PASSWORD
\getenv library_app_password LIBRARY_APP_PASSWORD
\getenv storage_owner_password STORAGE_OWNER_PASSWORD
\getenv storage_app_password STORAGE_APP_PASSWORD
\getenv keycloak_password KEYCLOAK_DB_PASSWORD
CREATE ROLE library_owner LOGIN PASSWORD :'library_owner_password';
CREATE ROLE library_app LOGIN PASSWORD :'library_app_password';
CREATE ROLE storage_owner LOGIN PASSWORD :'storage_owner_password';
CREATE ROLE storage_app LOGIN PASSWORD :'storage_app_password';
CREATE ROLE keycloak LOGIN PASSWORD :'keycloak_password';
CREATE DATABASE library OWNER library_owner;
CREATE DATABASE storage OWNER storage_owner;
CREATE DATABASE keycloak OWNER keycloak;
REVOKE CONNECT ON DATABASE library FROM PUBLIC;
REVOKE CONNECT ON DATABASE storage FROM PUBLIC;
REVOKE CONNECT ON DATABASE keycloak FROM PUBLIC;
GRANT CONNECT ON DATABASE library TO library_app;
GRANT CONNECT ON DATABASE storage TO storage_app;
\connect library
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO library_app;
\connect storage
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO storage_app;
