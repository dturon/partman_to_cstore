CREATE TABLE move_config(
    parent_table text PRIMARY KEY,
    move_int text NOT NULL DEFAULT '1d', 
    drop_int text DEFAULT '30d',
    compression text DEFAULT 'pglz', --if NULL use no compression
    stripe_row_count int, -- if NULL use default 150000
    block_row_count int, --if NULL use default 10000
    last_check timestamptz
);

SELECT pg_catalog.pg_extension_config_dump('move_config', '');
