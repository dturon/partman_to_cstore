# Partman to cstore

Partman to cstore is postgresql extension for moving old partman partitions to cstore columnar storage using cron job. When data is moved, new view **$parent_table+'_with_cstore'** contains parent table and data from cstore is created. All settings is in table **move_config**, there are attributes **move_int** - move old partman tables than $interval and **drop_int** - drop old cstore tables than $interval.

```
--configuration table for move partman partitions and drop cstore partitions
CREATE TABLE move_config(
    parent_table text PRIMARY KEY,
    move_int text NOT NULL DEFAULT '1d', 
    drop_int text DEFAULT '30d',
    last_check timestamptz
);
```

## Limitations

Its experimental extension, working only for partman **time-based** partitions!!!