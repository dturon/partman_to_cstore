# Partman to cstore

Partman to cstore is postgresql extension for moving old partman partitions to cstore columnar storage using cron job. When data are moved, inheritance is set on child table and parent table contains data from all cstore children and other regular children. Table check constraints are cloned too. All settings is in table **move_config**, there are attributes **move_int** - move old partman tables than $interval and **drop_int** - drop old cstore tables than $interval. Basic idea of this extension is save space and maybe can speedup some queries on slow disks.  

```sql
-- configuration table for move partman partitions and drop cstore partitions
CREATE TABLE move_config(
    parent_table text PRIMARY KEY,
    move_int text NOT NULL DEFAULT '1d', 
    drop_int text DEFAULT '30d',
    compression text DEFAULT 'pglz', --if NULL use no compression
    stripe_row_count int, -- if NULL use default 150000
    block_row_count int, --if NULL use default 10000
    last_check timestamptz
);
```

## Limitations

Its experimental extension, working only for partman **time-based(epoch too)** partitions!!! Don't forget that cstore tables isn't backuped by pg_dump and FDW tables don't have inheritence, checks and pushdown, so query planner scan all FDW tables.

## Support for move common partitions
There is function called **move_singlepart_to_cstore** with arguments schema and table name that can move single part of parted table to cstore. Doesn't matter if part is from pg_partman or standart postgresql partition. 


## Links

[pg_partman extension](https://github.com/keithf4/pg_partman)
[cstore_fdw extension](https://github.com/citusdata/cstore_fdw)
