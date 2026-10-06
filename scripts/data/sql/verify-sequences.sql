-- Used only inside the isolated restore container, against archived SEQUENCE SET.
CREATE OR REPLACE FUNCTION pg_temp.assert_sequence(sequence_name regclass, expected bigint, expected_called boolean)
RETURNS bigint LANGUAGE plpgsql AS $verify$
DECLARE actual bigint; actual_called boolean;
BEGIN
  EXECUTE format('SELECT last_value,is_called FROM %s',sequence_name) INTO actual,actual_called;
  IF actual IS DISTINCT FROM expected OR actual_called IS DISTINCT FROM expected_called THEN
    RAISE EXCEPTION 'Restored sequence % does not match the dump archive',sequence_name;
  END IF;
  RETURN actual;
END
$verify$;
