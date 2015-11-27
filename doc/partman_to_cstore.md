# Usage

```sql
-- install extensions
-- columnar storage
CREATE EXTENSION cstore_fdw;

-- partman
CREATE SCHEMA partman;
CREATE EXTENSION pg_partman WITH SCHEMA partman;

-- partman to cstore
CREATE SCHEMA partman_to_cstore;
CREATE EXTENSION partman_to_cstore WITH SCHEMA partman_to_cstore;

-- create testing structure
CREATE SCHEMA test;
CREATE TABLE test.test_time(
	ts timestamptz PRIMARY KEY, 
	data int
);

-- add table to partman
SELECT * FROM partman.create_parent(
    p_parent_table:='test.test_time',
    p_control:='ts',
    p_type:='time-static',
    p_interval:='daily',
    p_premake:=30,
    p_use_run_maintenance:=NULL::boolean,
    p_inherit_fk:=true,
    p_jobmon:=false,
    p_debug:=false
);

-- fill table with some data
INSERT INTO test.test_time
SELECT *, random()*1000  FROM generate_series(now()-'30days'::interval,now(),'1h'::interval);

-- configure partman_to_cstore
INSERT INTO partman_to_cstore.move_config(parent_table, move_int, drop_int) VALUES('test.test_time','1day','15days');

-- lets move data using cron job or manually using script partman_to_cstore_move_data or with SQL command below
SELECT partman_to_cstore.part_to_cstore(p_parent_table:='test.test_time', move_int:='1day', drop_int:='15days');

-- now can look on data
SELECT * FROM test.test_time_with_cstore ORDER BY ts;
```
