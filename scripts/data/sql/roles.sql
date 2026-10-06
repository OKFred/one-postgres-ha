-- Export only roles referenced by this database and their membership closure.
-- Password hashes are secrets: keep this output in a mode-0600 file.
CREATE TEMP TABLE migration_roles AS
WITH RECURSIVE needed(oid) AS (
  SELECT refobjid FROM pg_shdepend
  WHERE refclassid = 'pg_authid'::regclass
    AND (dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
      OR (classid = 'pg_database'::regclass AND objid = (SELECT oid FROM pg_database WHERE datname = current_database())))
  UNION
  SELECT oid FROM pg_roles WHERE rolname = ANY (string_to_array(:'required_roles', ','))
  UNION
  SELECT u.oid FROM needed n JOIN pg_auth_members m ON n.oid IN (m.roleid, m.member)
  CROSS JOIN LATERAL unnest(ARRAY[m.roleid, m.member, m.grantor]) u(oid)
)
SELECT a.*, r.rolconfig FROM pg_authid a JOIN needed n USING (oid) JOIN pg_roles r USING (oid)
WHERE a.rolname !~ '^pg_' AND a.rolname NOT IN ('postgres', 'replicator', 'rewind_user');

SELECT format('DO $migration$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = %L) THEN CREATE ROLE %I; END IF; END $migration$;', rolname, rolname)
FROM migration_roles ORDER BY rolname;
SELECT format('ALTER ROLE %I WITH %s %s %s %s %s %s %s CONNECTION LIMIT %s PASSWORD %L%s;',
  rolname, CASE WHEN rolsuper THEN 'SUPERUSER' ELSE 'NOSUPERUSER' END,
  CASE WHEN rolinherit THEN 'INHERIT' ELSE 'NOINHERIT' END,
  CASE WHEN rolcreaterole THEN 'CREATEROLE' ELSE 'NOCREATEROLE' END,
  CASE WHEN rolcreatedb THEN 'CREATEDB' ELSE 'NOCREATEDB' END,
  CASE WHEN rolcanlogin THEN 'LOGIN' ELSE 'NOLOGIN' END,
  CASE WHEN rolreplication THEN 'REPLICATION' ELSE 'NOREPLICATION' END,
  CASE WHEN rolbypassrls THEN 'BYPASSRLS' ELSE 'NOBYPASSRLS' END,
  rolconnlimit, rolpassword, CASE WHEN rolvaliduntil IS NULL THEN '' ELSE format(' VALID UNTIL %L', rolvaliduntil::text) END)
FROM migration_roles ORDER BY rolname;
SELECT format('ALTER ROLE %I SET %I TO %L;', r.rolname, split_part(s.setting, '=', 1), substring(s.setting FROM position('=' IN s.setting) + 1))
FROM migration_roles r CROSS JOIN LATERAL unnest(r.rolconfig) s(setting) ORDER BY r.rolname, s.setting;
-- Grant each ADMIN chain before privileges that rely on that grantor.
WITH RECURSIVE grant_order AS (
  SELECT m.roleid,m.member,m.grantor,m.admin_option,0 AS depth,
    ARRAY[format('%s/%s/%s',m.roleid,m.member,m.grantor)] AS path
  FROM pg_auth_members m WHERE m.grantor=10
  UNION ALL
  SELECT m.roleid,m.member,m.grantor,m.admin_option,g.depth+1,
    g.path || format('%s/%s/%s',m.roleid,m.member,m.grantor)
  FROM grant_order g JOIN pg_auth_members m ON m.roleid=g.roleid AND m.grantor=g.member
  WHERE g.admin_option AND NOT format('%s/%s/%s',m.roleid,m.member,m.grantor)=ANY(g.path)
), ordered AS (
  SELECT roleid,member,grantor,min(depth) AS depth FROM grant_order GROUP BY roleid,member,grantor
)
SELECT format('GRANT %I TO %I WITH ADMIN %s, INHERIT %s, SET %s GRANTED BY %I;',
  parent.rolname, child.rolname, m.admin_option::text, m.inherit_option::text, m.set_option::text, grantor.rolname)
FROM pg_auth_members m JOIN pg_roles parent ON parent.oid = m.roleid
JOIN pg_roles child ON child.oid = m.member JOIN pg_roles grantor ON grantor.oid = m.grantor
JOIN ordered o USING (roleid,member,grantor)
WHERE (m.roleid IN (SELECT oid FROM migration_roles) OR m.member IN (SELECT oid FROM migration_roles))
ORDER BY o.depth,parent.rolname,m.admin_option DESC,child.rolname,grantor.rolname;
