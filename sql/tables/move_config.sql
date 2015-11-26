CREATE TABLE move_config(
    parent_table text PRIMARY KEY,
    move_int text NOT NULL DEFAULT '1d', 
    drop_int text DEFAULT '30d',
    last_check timestamptz
);

SELECT pg_catalog.pg_extension_config_dump('move_config', '');
