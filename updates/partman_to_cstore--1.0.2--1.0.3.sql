ALTER TABLE move_config ADD COLUMN compression text DEFAULT 'pglz';
ALTER TABLE move_config ADD COLUMN stripe_row_count int; 
ALTER TABLE move_config ADD COLUMN block_row_count int; 

DROP FUNCTION part_to_cstore(text,interval,interval);
CREATE OR REPLACE FUNCTION part_to_cstore(
    p_parent_table text, 
    move_int interval DEFAULT '1d', 
    drop_int interval DEFAULT NULL,
    compression text DEFAULT 'pglz',
    stripe_row_count int DEFAULT NULL, 
    block_row_count int DEFAULT NULL
) RETURNS VOID AS
$$
DECLARE
    _child_table text;
    _child_table_oid oid;
    _cmd text;
    _schema text;
    _partman_schema text;
    _tables_to_delete text[];
    _relowner text;
    _relacl boolean;
    _grant_privileges text;
    _grantee text;
    _change boolean DEFAULT false;
    _datetime_string text;
    _first boolean DEFAULT true;
    _options text;
    _options_arr text[];
    

BEGIN

    --get schema from pg_partman
    SELECT n.nspname 
    FROM pg_catalog.pg_extension e 
    LEFT JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace 
    WHERE e.extname = 'pg_partman'
    LIMIT 1
    INTO _partman_schema;

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

    --partitions to move to cstore < move_int
    FOR _child_table, _child_table_oid, _schema, _relowner, _relacl, _datetime_string IN EXECUTE
        'SELECT ci.oid::pg_catalog.regclass, ci.oid, nspname, pg_get_userbyid(ci.relowner), ci.relacl IS NOT NULL, p.datetime_string 
        FROM pg_catalog.pg_namespace nc
        JOIN pg_catalog.pg_class c ON nc.oid = c.relnamespace
        JOIN '||quote_ident(_partman_schema)||'.part_config p ON (nspname||''.''||relname = parent_table)
        JOIN pg_catalog.pg_inherits i ON(i.inhparent = c.oid)
        JOIN pg_catalog.pg_class ci ON (ci.oid = i.inhrelid)
        WHERE p.parent_table = '||quote_literal(p_parent_table)||' 
        AND to_timestamp(SUBSTRING(ci.oid::pg_catalog.regclass::text,''_p(.{10}$)''),p.datetime_string) < now()-'||quote_literal(move_int)||'::interval 
        ORDER BY ci.oid::pg_catalog.regclass'
    LOOP
        IF _first THEN
            _change = true;
            _first = false;
        END IF;
        RAISE DEBUG 'CREATE FOREIGN TABLE for %', _child_table;
        SELECT string_agg(attname||' '||pg_catalog.format_type(atttypid, atttypmod)||CASE WHEN attnotnull THEN ' NOT NULL' ELSE '' END,',' ORDER BY attnum) 
        FROM pg_attribute 
        WHERE attrelid = _child_table_oid AND attnum > 0 AND NOT attisdropped 
        INTO _cmd;


        --create table
        _cmd = format('CREATE FOREIGN TABLE %s_cstore(%s) SERVER partman_to_cstore_server%s;', _child_table, _cmd, ' OPTIONS('||_options||')'); 
        RAISE DEBUG '%', _cmd;
        EXECUTE _cmd;

        --alter owner
        _cmd = format('ALTER FOREIGN TABLE %s_cstore OWNER TO %s;', _child_table, _relowner); 
        RAISE DEBUG '%', _cmd;
        EXECUTE _cmd;

        --revoke from public
        _cmd = format('REVOKE ALL ON TABLE %s_cstore FROM PUBLIC;', _child_table); 
        RAISE DEBUG '%', _cmd;
        EXECUTE _cmd;

        --revoke from user
        IF _relacl THEN
            _cmd = format('REVOKE ALL ON TABLE %s_cstore FROM %s;', _child_table, _relowner); 
            RAISE DEBUG '%', _cmd;
            EXECUTE _cmd;
        END IF;

        --grant all privileges
        FOR _grant_privileges, _grantee IN
            SELECT string_agg(DISTINCT privilege_type::text,',' ORDER BY privilege_type::text) AS types, grantee 
            FROM information_schema.table_privileges 
            WHERE table_schema||'.'||table_name = _child_table 
            GROUP BY grantee
        LOOP
            --grant
            _cmd = format('GRANT %s ON TABLE %s_cstore TO %s;', _grant_privileges, _child_table, _grantee); 
            RAISE DEBUG '%', _cmd;
            EXECUTE _cmd;
        END LOOP;

        RAISE DEBUG 'Moving data from table % to cstore', _child_table;

        _cmd = format('INSERT INTO %s_cstore SELECT * FROM %s', _child_table, _child_table);
        RAISE DEBUG '%', _cmd;
        EXECUTE _cmd;

        -- add table to delete list
        _tables_to_delete = array_append(_tables_to_delete, _child_table);
    
    END LOOP;

    IF _schema IS NULL THEN
        _schema = COALESCE(substring(p_parent_table, '([^.]*)'),'public');
        SELECT datetime_string FROM partman.part_config WHERE parent_table = p_parent_table INTO _datetime_string; 
    END IF;

    --update last check
    UPDATE @extschema@.move_config SET last_check=clock_timestamp() WHERE parent_table = p_parent_table;

    --drop old cstore tables < drop_int
    IF drop_int IS NOT NULL THEN
        _first = True;
        FOR _child_table IN
            SELECT c.oid::pg_catalog.regclass 
            FROM pg_catalog.pg_namespace nc
            JOIN pg_catalog.pg_class c ON nc.oid = c.relnamespace 
            WHERE nspname = _schema 
            AND c.oid::pg_catalog.regclass::text LIKE '%'||p_parent_table||'%_cstore' 
            AND to_timestamp(SUBSTRING(c.oid::pg_catalog.regclass::text, '_p(.{10}_cstore$)'), _datetime_string) < now()- drop_int
            ORDER BY c.oid::pg_catalog.regclass
        LOOP
            IF _first THEN
                _cmd = format('DROP VIEW IF EXISTS %s_with_cstore', p_parent_table);
                RAISE DEBUG '%', _cmd;
                EXECUTE _cmd;                
                _change = true;
                _first = false;
            END IF;

            _cmd = format('DROP FOREIGN TABLE %s',_child_table);
            RAISE DEBUG '%', _cmd;
            EXECUTE _cmd;

        END LOOP;
    END IF;

    --nothing changed
    IF NOT _change THEN
        RAISE DEBUG 'NOTHING CHANGED EXITING';
        RETURN;
    END IF;

    --create view
    SELECT ' UNION ALL '||string_agg('SELECT * FROM '||c.oid::pg_catalog.regclass::text,' UNION ALL ' ORDER BY c.oid::pg_catalog.regclass), pg_get_userbyid(c.relowner)
    FROM pg_catalog.pg_namespace nc
    JOIN pg_catalog.pg_class c ON nc.oid = c.relnamespace 
    WHERE nspname = _schema AND c.relkind='f'
    AND c.oid::pg_catalog.regclass::text LIKE '%'||p_parent_table||'%_cstore' 
    GROUP BY pg_get_userbyid(c.relowner)
    INTO _cmd, _relowner;

    _cmd = format('CREATE OR REPLACE VIEW %s_with_cstore AS SELECT * FROM %s%s', p_parent_table, p_parent_table, _cmd);
    RAISE DEBUG '%', _cmd;
    EXECUTE _cmd;

    --alter owner
    _cmd = format('ALTER TABLE %s_with_cstore OWNER TO %s;', p_parent_table, _relowner); 
    RAISE DEBUG '%', _cmd;
    EXECUTE _cmd;

    --revoke from public
    _cmd = format('REVOKE ALL ON TABLE %s_with_cstore FROM PUBLIC;', p_parent_table); 
    RAISE DEBUG '%', _cmd;
    EXECUTE _cmd;

    --revoke from user
    IF _relacl THEN
        _cmd = format('REVOKE ALL ON TABLE %s_with_cstore FROM %s;', p_parent_table, _relowner); 
        RAISE DEBUG '%', _cmd;
        EXECUTE _cmd;
    END IF;

    --grant all privileges
    FOR _grant_privileges, _grantee IN
        SELECT string_agg(DISTINCT privilege_type::text,',' ORDER BY privilege_type::text) AS types, grantee 
        FROM information_schema.table_privileges 
        WHERE table_schema||'.'||table_name = p_parent_table 
        GROUP BY grantee
    LOOP
        --grant
        _cmd = format('GRANT %s ON TABLE %s_with_cstore TO %s;', _grant_privileges, p_parent_table, _grantee); 
        RAISE DEBUG '%', _cmd;
        EXECUTE _cmd;
    END LOOP;


    IF _tables_to_delete IS NULL THEN
        RETURN;
    END IF;    

    --delete moved tables
    FOREACH _child_table IN ARRAY _tables_to_delete 
    LOOP
        _cmd = format('DROP TABLE %s', _child_table);
        RAISE DEBUG '%', _cmd;
        EXECUTE _cmd;

    END LOOP;


END;
$$ LANGUAGE plpgsql VOLATILE;
