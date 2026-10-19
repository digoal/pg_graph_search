# pg_graph_search — 属性图搜索扩展（元函数驱动）
#
# 同时支持开源 PostgreSQL 与 OpenTenBase，两边产物由同一个构建开关切换：
#   make USE_PGXS=1                 默认 -> 原生 PostgreSQL 版（发布产物就是它）
#   make USE_PGXS=1 OPENTENBASE=1  -> OpenTenBase 版（注册表 REPLICATION）
#   make                            在 OpenTenBase contrib 树内就地构建（自动 OPENTENBASE=1）
#   make portable                   额外出一份 -portable.sql（开发期双平台回归用，不发布）
#   make install                    安装到 $(DESTDIR)$(datadir)/extension
#   make installcheck               对运行中的实例跑 pg_regress
#   make lint                       SQL 模板静态门禁
#
# OpenTenBase 适配：
#   注册表必须 DISTRIBUTE BY REPLICATION，否则默认按主键首列 HASH，
#   每个 DN 只看到一部分实例清单。子句通过 @DISTRIBUTE_CLAUSE@ 占位符注入，
#   这样同一份源码也能生成“可移植版”用于在原生 PostgreSQL 上做功能验证。
#
#   注意默认值的方向：发布出去的 pg_graph_search--1.0.0.sql 必须是**原生 PostgreSQL
#   能装**的那一版（PG 约定），所以独立构建（USE_PGXS）默认 OPENTENBASE=0；
#   只有在 OpenTenBase 源码树内就地构建时才默认 1。
#   反过来做（拿 OpenTenBase 版去装原生 PG）会直接报
#   `syntax error at or near "DISTRIBUTE"`。

EXTENSION   = pg_graph_search
EXTVERSION  = 1.0.0
DATA_built  = pg_graph_search--$(EXTVERSION).sql
PGFILEDESC  = "pg_graph_search - property graph search for PostgreSQL and OpenTenBase"

REGRESS      = pg_graph_search
REGRESS_OPTS = --inputdir=test --outputdir=test

# OPENTENBASE=1 注入 DISTRIBUTE BY REPLICATION + control 里的 sql_mode='all'；
# =0 两处都留空，产出原生 PostgreSQL 版。
ifdef USE_PGXS
OPENTENBASE ?= 0
else
OPENTENBASE ?= 1
endif
ifeq ($(OPENTENBASE),0)
DISTRIBUTE_CLAUSE ?=
SQL_MODE_LINE     ?=
else
DISTRIBUTE_CLAUSE ?= DISTRIBUTE BY REPLICATION
SQL_MODE_LINE     ?= sql_mode = 'all'
endif

SQL_PARTS    = $(wildcard sql/*.sql)
PORTABLE_SQL = pg_graph_search--$(EXTVERSION)-portable.sql
PORTABLE_CONTROL = pg_graph_search-portable.control
CONTROL_IN   = $(EXTENSION).control.in
CONTROL      = $(EXTENSION).control

.PHONY: sql portable lint FORCE

# 默认目标。产物文件名不带 flavor，OPENTENBASE 只是 make 变量、不体现在文件名里，
# 光靠时间戳依赖会出现"切了开关却不重新生成"（同一秒内 mtime 相同）。
# 拼装本身只是几十 KB 的 cat|sed，代价可忽略，所以直接每次都重生成。
sql: $(DATA_built) $(CONTROL)

$(DATA_built): $(SQL_PARTS) Makefile FORCE
	@echo "  GEN  $@  (DISTRIBUTE_CLAUSE='$(DISTRIBUTE_CLAUSE)')"
	@cat $(SQL_PARTS) | sed -e 's|@DISTRIBUTE_CLAUSE@|$(DISTRIBUTE_CLAUSE)|g' > $@

# control 同样要分平台：原生 PG 遇到不认识的 control 参数直接报
# unrecognized parameter "sql_mode"，那一行必须整行去掉。
$(CONTROL): $(CONTROL_IN) Makefile FORCE
	@echo "  GEN  $@  (SQL_MODE='$(SQL_MODE_LINE)')"
	@sed -e 's|@SQL_MODE@|$(SQL_MODE_LINE)|g' $(CONTROL_IN) > $@

FORCE:

# 原生 PostgreSQL 版（无 Postgres-XL 语法）：`make portable` 后把这两个文件改名
# 装到 extension 目录即可在原生 PG 上做功能验证。不随扩展发布。
portable: $(PORTABLE_SQL) $(PORTABLE_CONTROL)
	@echo "  GEN  $(PORTABLE_SQL) + $(PORTABLE_CONTROL)  (portable: no DISTRIBUTE BY, no sql_mode)"

$(PORTABLE_SQL): $(SQL_PARTS)
	@cat $(SQL_PARTS) | sed -e 's|@DISTRIBUTE_CLAUSE@||g' > $@

$(PORTABLE_CONTROL): $(CONTROL_IN)
	@sed -e 's|@SQL_MODE@||g' $(CONTROL_IN) > $@

lint:
	python3 test/lint_sql.py

# clean 用 PGXS / contrib-global 自带的（会清 DATA_built），这里只补可移植版产物。
# 注意别自己定义 clean：PGXS 也有同名目标，GNU make 会报 "overriding recipe"。
clean-ext:
	rm -f $(PORTABLE_SQL) $(PORTABLE_CONTROL)
	rm -rf test/results test/regression.diffs test/regression.out test/log

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_graph_search
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
