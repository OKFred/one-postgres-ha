-- Isolated test data only. The fixture password is generated at test runtime.
CREATE ROLE app_parent NOLOGIN;
CREATE ROLE app_writer LOGIN PASSWORD :'fixture_password';
CREATE ROLE app_viewer LOGIN PASSWORD :'fixture_password';
CREATE ROLE grant_manager NOLOGIN;
CREATE ROLE unrelated_other_database_role NOLOGIN;
ALTER ROLE app_writer SET statement_timeout='20s';
ALTER ROLE app_writer SET lock_timeout='5s';
GRANT app_parent TO app_writer WITH ADMIN FALSE, INHERIT TRUE, SET TRUE;
GRANT app_parent TO grant_manager WITH ADMIN TRUE;
SET ROLE grant_manager;
GRANT app_parent TO app_viewer WITH ADMIN FALSE, INHERIT TRUE, SET TRUE GRANTED BY grant_manager;
RESET ROLE;
CREATE DATABASE one_minihouse OWNER app_writer;
CREATE DATABASE unrelated_database;
\connect one_minihouse
CREATE EXTENSION pg_trgm;
CREATE SCHEMA iot AUTHORIZATION app_writer;
CREATE TABLE iot.telemetry(id bigserial PRIMARY KEY, value jsonb, captured_at timestamptz NOT NULL);
ALTER TABLE iot.telemetry OWNER TO app_writer;
INSERT INTO iot.telemetry(value,captured_at) VALUES ('{"temperature":25}',now()), ('{"temperature":null}',now());
ALTER TABLE iot.telemetry ENABLE ROW LEVEL SECURITY;
CREATE POLICY reader ON iot.telemetry FOR SELECT TO app_viewer USING (id>0);
GRANT USAGE ON SCHEMA iot TO app_viewer;
GRANT SELECT ON iot.telemetry TO app_viewer;
CREATE VIEW iot.visible WITH (security_barrier=true,security_invoker=true) AS SELECT * FROM iot.telemetry;
ALTER VIEW iot.visible OWNER TO app_writer;
GRANT SELECT ON iot.visible TO app_viewer;
ALTER DEFAULT PRIVILEGES FOR ROLE app_writer IN SCHEMA iot GRANT SELECT ON TABLES TO app_viewer;
