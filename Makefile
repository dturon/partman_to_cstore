EXTENSION = partman_to_cstore
EXTVERSION = $(shell grep default_version $(EXTENSION).control | \
               sed -e "s/default_version[[:space:]]*=[[:space:]]*'\([^']*\)'/\1/")

DATA = $(filter-out $(wildcard updates/*--*.sql),$(wildcard sql/*.sql))
PG_CONFIG = pg_config


all: sql/$(EXTENSION)--$(EXTVERSION).sql


sql/$(EXTENSION)--$(EXTVERSION).sql: sql/fdw/*.sql sql/tables/*.sql sql/functions/*.sql
	cat $^ > $@


DATA = $(wildcard updates/*--*.sql) sql/$(EXTENSION)--$(EXTVERSION).sql
EXTRA_CLEAN = sql/$(EXTENSION)--$(EXTVERSION).sql


PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
