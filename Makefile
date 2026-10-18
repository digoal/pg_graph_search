# pg_graph_search — PostgreSQL property-graph search extension (meta-function based)
#
# make            生成 pg_graph_search--1.0.0.sql (由 sql/ 片段拼装)
# make install    安装到 $(pg_config --sharedir)/extension
# make installcheck 跑回归测试 (需要已 initdb 的测试实例)
# make clean      清理

EXTENSION   = pg_graph_search
EXTVERSION  = 1.0.0
DATA        = pg_graph_search--$(EXTVERSION).sql
PG_CONFIG  ?= pg_config
PGXS        := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

SQL_PARTS = $(wildcard sql/*.sql)

$(DATA): $(SQL_PARTS)
	@echo "cat $(SQL_PARTS) > $@"
	@cat $(SQL_PARTS) > $@

REGRESS      = regress_install regress_search regress_api
REGRESS_OPTS = --inputdir=test --load-extension=pg_graph_search

.PHONY: sql
sql: $(DATA)
