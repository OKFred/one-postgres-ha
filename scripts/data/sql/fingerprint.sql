-- Stable logical checks, generated from the same exported snapshot as pg_dump.
SET timezone = 'UTC';
SET extra_float_digits = 3;
SELECT 'database|' || json_build_array(d.datname, pg_get_userbyid(d.datdba), d.datacl, d.datconnlimit)::text
FROM pg_database d WHERE datname = current_database();
SELECT 'relation|' || json_build_array(n.nspname, c.relname, c.relkind, pg_get_userbyid(c.relowner), c.relacl,
  c.relrowsecurity, c.relforcerowsecurity, c.reloptions)::text
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_'
AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f') ORDER BY n.nspname, c.relname;
SELECT 'schema|' || json_build_array(nspname, pg_get_userbyid(nspowner), nspacl)::text
FROM pg_namespace WHERE nspname NOT IN ('pg_catalog', 'information_schema') AND nspname !~ '^pg_' ORDER BY nspname;
SELECT 'policy|' || json_build_array(n.nspname, c.relname, p.polname, p.polcmd, p.polpermissive,
  ARRAY(SELECT pg_get_userbyid(u) FROM unnest(p.polroles) u ORDER BY 1),
  pg_get_expr(p.polqual, p.polrelid), pg_get_expr(p.polwithcheck, p.polrelid))::text
FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace
ORDER BY n.nspname, c.relname, p.polname;
SELECT 'default-acl|' || json_build_array(pg_get_userbyid(d.defaclrole), n.nspname, d.defaclobjtype, d.defaclacl)::text
FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace ORDER BY 1;
SELECT 'view|' || json_build_array(n.nspname, c.relname, pg_get_viewdef(c.oid, false))::text
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('v', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1;
SELECT 'constraint|' || json_build_array(n.nspname, c.relname, k.conname, pg_get_constraintdef(k.oid, false))::text
FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_' AND k.contype <> 'n' ORDER BY 1;
-- PG18 represents NOT NULL in pg_constraint; PG17 uses pg_attribute only.
SELECT 'column|' || json_build_array(n.nspname,c.relname,a.attname,format_type(a.atttypid,a.atttypmod),
  a.attnotnull,a.attidentity,a.attgenerated,a.attacl,pg_get_expr(d.adbin,d.adrelid))::text
FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_'
AND c.relkind IN ('r','p','v','m','f') AND a.attnum>0 AND NOT a.attisdropped ORDER BY n.nspname,c.relname,a.attnum;
SELECT 'index|' || json_build_array(n.nspname, c.relname, pg_get_indexdef(i.indexrelid))::text
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_' ORDER BY 1;
SELECT 'extension|' || json_build_array(extname, n.nspname)::text
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace ORDER BY extname;
SELECT 'function|' || json_build_array(n.nspname,p.proname,pg_get_function_identity_arguments(p.oid),
  pg_get_userbyid(p.proowner),p.proacl,p.prosecdef,p.proconfig,pg_get_functiondef(p.oid))::text
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_' AND p.prokind IN ('f','p') ORDER BY 1;
SELECT 'sequence-definition|' || json_build_array(n.nspname,c.relname,format_type(s.seqtypid,NULL),
  s.seqstart,s.seqincrement,s.seqmax,s.seqmin,s.seqcache,s.seqcycle)::text
FROM pg_sequence s JOIN pg_class c ON c.oid=s.seqrelid JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_' ORDER BY 1;
-- Sum two halves of row MD5s as numeric values: constant memory and order independent.
SELECT format('SELECT ''table|'' || json_build_array(%L,%L,count(*),COALESCE(sum((''x''||substr(md5(row_to_json(t)::text),1,16))::bit(64)::bigint::numeric),0),COALESCE(sum((''x''||substr(md5(row_to_json(t)::text),17,16))::bit(64)::bigint::numeric),0))::text FROM %I.%I t;',
  n.nspname, c.relname, n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_' ORDER BY n.nspname, c.relname
\gexec
SELECT format('SELECT ''sequence|'' || json_build_array(%L,%L,last_value,is_called)::text FROM %I.%I;', n.nspname, c.relname, n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'S' AND n.nspname NOT IN ('pg_catalog', 'information_schema') ORDER BY n.nspname, c.relname
\gexec
