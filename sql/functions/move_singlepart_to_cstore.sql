CREATE OR REPLACE FUNCTION move_singlepart_to_cstore(
    part_schema text,
    part_table text, 
    compression text DEFAULT 'pglz',
    stripe_row_count int DEFAULT NULL, 
    block_row_count int DEFAULT NULL
) RETURNS VOID AS
$$
DECLARE
    _child_table text;
    _child_table_oid oid;
    _parent_table text;
    _cmd text;
    _schema text;
    _relowner text;
    _relacl boolean;
    _grant_privileges text;
    _grantee text;
    _change boolean DEFAULT false;
    _datetime_string text;
    _first boolean DEFAULT true;
    _options text;
    _options_arr text[];
    _constr_name text;
    _constr_def text;
    

BEGIN

    --options for tables
    IF compression IS NOT NULL THEN
        _options_arr = array_append(_options_arr, 'compression '''||compression||'''');
    END IF;

    IF stripe_row_count IS NOT NULL THEN
        _options_arr = array_append(_options_arr, 'stripe_row_count '''||stripe_row_count||'''');
    END IF;

    IF block_row_count IS NOT NULL THEN
        _options_arr = array_append(_options_arr, 'block_row_count '''||block_row_count||'''');
    END IF;

    _options = array_to_string(_options_arr,',');

    RAISE DEBUG 'options: %', _options;

    _cmd = format(
'SELECT 
  n.nspname,
  c.relname,
  c.oid,
  pg_get_userbyid(c.relowner), 
  c.relacl IS NOT NULL,
  ci.relname

FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_inherits i ON(i.inhrelid = c.oid) 
JOIN pg_catalog.pg_class ci ON(ci.oid=i.inhparent)
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace

WHERE n.nspname = %L AND c.relname = %L
ORDER BY 2, 3 LIMIT 1;
', part_schema, part_table);

    RAISE DEBUG '%', _cmd;
    EXECUTE _cmd INTO _schema, _child_table, _child_table_oid,  _relowner, _relacl, _parent_table;

    IF _child_table_oid IS NULL THEN
        RAISE DEBUG 'No parent or child table found';
        RETURN;
    END IF;

    RAISE DEBUG 'CREATE FOREIGN TABLE for %.%', _schema, _child_table;
    SELECT string_agg(attname||' '||pg_catalog.format_type(atttypid, atttypmod)||CASE WHEN attnotnull THEN ' NOT NULL' ELSE '' END,',' ORDER BY attnum) 
    FROM pg_attribute 
    WHERE attrelid = _child_table_oid AND attnum > 0 AND NOT attisdropped 
    INTO _cmd;


    --create table
    _cmd = format('CREATE FOREIGN TABLE %s.%s_cstore(%s) SERVER partman_to_cstore_server%s;', _schema, _child_table, _cmd, ' OPTIONS('||_options||')'); 
    RAISE DEBUG '%', _cmd;
    EXECUTE _cmd;

    --alter owner
    _cmd = format('ALTER FOREIGN TABLE %s.%s_cstore OWNER TO %s;', _schema, _child_table, _relowner); 
    RAISE DEBUG '%', _cmd;
    EXECUTE _cmd;

    --set inheritence (working from PG 9.5)
    _cmd = format('ALTER FOREIGN TABLE %s.%s_cstore INHERIT %s.%s;', _schema, _child_table, _schema, _parent_table); 
    RAISE DEBUG '%', _cmd;
    EXECUTE _cmd;

    --constraints (working from PG 9.5)
    FOR _constr_name, _constr_def IN SELECT r.conname, pg_catalog.pg_get_constraintdef(r.oid, true)
        FROM pg_catalog.pg_constraint r
        WHERE r.conrelid = _child_table_oid AND r.contype = 'c'
        ORDER BY 1
    LOOP
        _cmd = format('ALTER FOREIGN TABLE %s.%s_cstore ADD CONSTRAINT %s %s;', _schema, _child_table, _constr_name, _constr_def); 
        RAISE DEBUG '%', _cmd;
        EXECUTE _cmd;
    END LOOP;         

    --revoke from public
    _cmd = format('REVOKE ALL ON TABLE %s.%s_cstore FROM PUBLIC;', _schema, _child_table); 
    RAISE DEBUG '%', _cmd;
    EXECUTE _cmd;

    --revoke from user
    IF _relacl THEN
        _cmd = format('REVOKE ALL ON TABLE %s.%s_cstore FROM %s;', _schema, _child_table, _relowner); 
        RAISE DEBUG '%', _cmd;
        EXECUTE _cmd;
    END IF;

    --grant all privileges
    FOR _grant_privileges, _grantee IN
        SELECT string_agg(DISTINCT privilege_type::text,',' ORDER BY privilege_type::text) AS types, grantee 
        FROM information_schema.table_privileges 
        WHERE table_schema = _schema AND table_name = _child_table 
        GROUP BY grantee
    LOOP
        --grant
        _cmd = format('GRANT %s ON TABLE %s.%s_cstore TO %s;', _grant_privileges, _schema, _child_table, _grantee); 
        RAISE DEBUG '%', _cmd;
        EXECUTE _cmd;
    END LOOP;

    RAISE DEBUG 'Moving data from table %.% to cstore', _schema, _child_table;

    _cmd = format('INSERT INTO %s.%s_cstore SELECT * FROM %s.%s;', _schema, _child_table, _schema, _child_table);
    RAISE DEBUG '%', _cmd;
    EXECUTE _cmd;

    --delete moved table
    _cmd = format('DROP TABLE %s.%s;', _schema, _child_table);
    RAISE DEBUG '%', _cmd;
    EXECUTE _cmd;
    
    _cmd = format('ALTER FOREIGN TABLE %s.%s_cstore RENAME TO %s;', _schema, _child_table, part_table);
    RAISE DEBUG '%', _cmd;
    EXECUTE _cmd;
  
    
END;
$$ LANGUAGE plpgsql VOLATILE;
