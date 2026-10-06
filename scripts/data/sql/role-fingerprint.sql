SET timezone = 'UTC';
SELECT 'role|' || json_build_array(r.rolname, r.rolsuper, r.rolinherit, r.rolcreaterole, r.rolcreatedb,
  r.rolcanlogin, r.rolreplication, r.rolbypassrls, r.rolconnlimit, r.rolpassword,
  r.rolvaliduntil, ARRAY(SELECT unnest(v.rolconfig) ORDER BY 1))::text FROM pg_authid r JOIN pg_roles v USING (oid)
WHERE r.rolname !~ '^pg_'
  AND r.rolname = ANY(string_to_array(:'required_roles', ',')) ORDER BY r.rolname;
SELECT 'membership|' || json_build_array(p.rolname, c.rolname, g.rolname, m.admin_option, m.inherit_option, m.set_option)::text
FROM pg_auth_members m JOIN pg_roles p ON p.oid=m.roleid JOIN pg_roles c ON c.oid=m.member JOIN pg_roles g ON g.oid=m.grantor
WHERE p.rolname=ANY(string_to_array(:'required_roles', ',')) OR c.rolname=ANY(string_to_array(:'required_roles', ',')) ORDER BY 1;
