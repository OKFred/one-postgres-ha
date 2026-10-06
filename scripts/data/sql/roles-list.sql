WITH RECURSIVE needed(oid) AS (
  SELECT refobjid FROM pg_shdepend WHERE refclassid = 'pg_authid'::regclass
    AND (dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
      OR (classid = 'pg_database'::regclass AND objid = (SELECT oid FROM pg_database WHERE datname = current_database())))
  UNION SELECT oid FROM pg_roles WHERE rolname = ANY(string_to_array(:'required_roles', ','))
  UNION SELECT u.oid FROM needed n JOIN pg_auth_members m ON n.oid IN (m.roleid, m.member)
  CROSS JOIN LATERAL unnest(ARRAY[m.roleid, m.member, m.grantor]) u(oid)
)
SELECT r.rolname FROM pg_roles r JOIN needed n USING (oid)
WHERE r.rolname !~ '^pg_' AND r.rolname NOT IN ('postgres', 'replicator', 'rewind_user') ORDER BY r.rolname;
