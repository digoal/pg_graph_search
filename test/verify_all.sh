#!/usr/bin/env bash
# pg_graph_search 全链路验证（OpenTenBase 分布式 / 原生 PostgreSQL 单机 双档）
#
# 用法：
#   PGHOST=172.16.16.49 PGPORT=11000 PGUSER=opentenbase bash test/verify_all.sh
#   bash test/verify_all.sh                 # 用默认本地连接
#   su postgres -c "bash test/verify_all.sh"  # 单机用 peer 认证时
#
# 可选环境变量：
#   DBNAME=gs_verify       验证用临时库名
#   VERIFY_CREATE_AGE=1    建库后执行 CREATE EXTENSION age
#                          （绕开"实例预载 age、但库内没建 AGE，导致 TRUNCATE
#                            临时表报 schema ag_catalog 不存在"的环境陷阱）
#   KEEP_DB=1              验证完保留临时库
#   SKIP_MAKE=1            跳过 make（只跑测试）
#   RUN_OPENTENBASE_SQL=0  在分布式集群上跳过 test/opentenbase/* 用例
set -uo pipefail

cd "$(dirname "$0")/.."
DBNAME=${DBNAME:-gs_verify}
PSQL=${PSQL:-psql}
RUN_OPENTENBASE_SQL=${RUN_OPENTENBASE_SQL:-1}
FAIL=0

step() { echo; echo "########## $* ##########"; }
psql_x() { $PSQL -X -q -v ON_ERROR_STOP=1 "$@"; }

# 已配置的源码树用 in-tree make，否则用 PGXS
if [[ -f ../../src/Makefile.global ]]; then
  MAKE="make"
else
  MAKE="make USE_PGXS=1"
fi
echo ">>> make 方式: ${MAKE}"

if [[ "${SKIP_MAKE:-0}" != "1" ]]; then
  step "1. 生成扩展 SQL（OpenTenBase 版 + 可移植版）"
  $MAKE >/dev/null || { echo "make 失败"; FAIL=1; }
  $MAKE portable >/dev/null || { echo "make portable 失败"; FAIL=1; }
  ls -l pg_graph_search--1.0.0.sql pg_graph_search--1.0.0-portable.sql
fi

step "2. SQL 模板静态门禁"
python3 test/lint_sql.py || FAIL=1

step "3. 连接与平台识别"
PLATFORM=$($PSQL -X -tAc "SELECT CASE WHEN to_regclass('pg_catalog.pgxc_class') IS NULL
                                  THEN 'pg' ELSE 'opentenbase' END" 2>/dev/null)
if [[ -z "$PLATFORM" ]]; then
  echo "无法连接数据库，请检查 PGHOST/PGPORT/PGUSER/PGDATABASE";
  $PSQL -X -c "SELECT 1" 2>&1 | head -3
  exit 1
fi
echo ">>> 平台: ${PLATFORM}（pg=原生单机, opentenbase=分布式集群）"
$PSQL -X -tAc "SELECT version()" | head -1

step "4. 建临时库 ${DBNAME}"
psql_x -d postgres -c "DROP DATABASE IF EXISTS ${DBNAME}" \
  || { echo "需要 CREATEDB 权限（或用已有库 DBNAME=...）"; FAIL=1; }
psql_x -d postgres -c "CREATE DATABASE ${DBNAME}" || { echo "CREATE DATABASE 失败"; exit 1; }
if [[ "${VERIFY_CREATE_AGE:-0}" == "1" ]]; then
  psql_x -d "${DBNAME}" -c "CREATE EXTENSION IF NOT EXISTS age" || FAIL=1
fi

step "5. 装载扩展"
# 两平台统一走 CREATE EXTENSION —— 那才是使用者真正的路径。
# 原生 PG 若还没 make install，退一步直接加载本次构建出的 SQL（免安装跑一遍功能）。
BUILT_SQL=$(ls pg_graph_search--*.sql 2>/dev/null | grep -v -- '-portable\.sql$' | head -1)
LOADED=no
if psql_x -d "${DBNAME}" -c "CREATE EXTENSION pg_graph_search" 2>/tmp/_ext.err; then
  LOADED="CREATE EXTENSION"
elif [[ "$PLATFORM" == "pg" && -n "$BUILT_SQL" ]]; then
  # 退路：直接灌脚本。独立构建（make USE_PGXS=1）产出的就是原生 PG 版，
  # 不含 DISTRIBUTE BY，所以在 PG 上可以裸灌（CREATE EXTENSION 还需要 control 装进 sharedir）。
  if psql_x -d "${DBNAME}" -c "CREATE SCHEMA graph_search" \
     && psql_x -d "${DBNAME}" -f "$BUILT_SQL" >/dev/null; then
    LOADED="直接加载 ${BUILT_SQL}（未 make install）"
  fi
fi

if [[ "$LOADED" != no ]]; then
  echo "扩展已装载：${LOADED}"
else
  echo "扩展装载失败：先执行 make && make install"
  head -5 /tmp/_ext.err 2>/dev/null
  FAIL=1
fi

step "6. 造图 + 装有向/无向实例（test/01_setup.sql）"
psql_x -d "${DBNAME}" -f test/01_setup.sql >/tmp/_setup.log 2>&1 \
  && echo "setup OK" || { echo "setup FAIL"; tail -5 /tmp/_setup.log; FAIL=1; }

step "7. 正确性验证（15 项；第 14/15 项抛错是预期）"
psql_x -d "${DBNAME}" -f test/02_correctness.sql >/tmp/_corr.log 2>&1
rc=$?
BADERR=$(grep -E "^psql:.*ERROR" /tmp/_corr.log | grep -vE ":71:|:77:" || true)
if [[ -n "$BADERR" ]]; then echo "$BADERR" | head -5; FAIL=1;
else echo "correctness OK（$rc，预期抛错 2 处）"; fi

step "8. 断言式回归（18 项）"
psql_x -d "${DBNAME}" -f test/03_regress.sql >/tmp/_reg.log 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "regress FAIL (rc=$rc)"; grep -E "ERROR|EXCEPTION" /tmp/_reg.log | head -5; FAIL=1
else
  echo "$(tail -1 /tmp/_reg.log)"
fi

step "9. 注册表分布策略（OpenTenBase 期望 REPLICATION）"
psql_x -d "${DBNAME}" -c "SELECT graph_search.registry_distribution()" || FAIL=1

if [[ "$PLATFORM" == "opentenbase" && "$RUN_OPENTENBASE_SQL" == "1" ]]; then
  step "10. 分布式用例（test/opentenbase/01_setup_distributed.sql）"
  psql_x -d "${DBNAME}" -f test/opentenbase/01_setup_distributed.sql >/tmp/_rep.log 2>&1 \
    && tail -20 /tmp/_rep.log || { echo "分布式用例 FAIL"; tail -8 /tmp/_rep.log; FAIL=1; }
  echo
  echo "提示：节点级验证需要节点名与超级用户，请手工执行："
  echo "  psql ... -f test/opentenbase/02_verify_nodes.sql   （先把 dn0001/dn0002 换成实际节点名）"
fi

# Markdown 渲染门禁：脚本位置走环境变量，不写死本机路径。
# 未设置 MARKDOWN_CHECK 时整段跳过——公开仓库里不该假设使用者有同一套工具。
if [[ -n "${MARKDOWN_CHECK:-}" && -x "${MARKDOWN_CHECK}" ]]; then
  step "11. Markdown 渲染门禁"
  for f in README.md SKILL.md; do
    python3 "${MARKDOWN_CHECK}" "$f" --quiet \
      >/dev/null && echo "$f OK" || { echo "$f FAIL"; FAIL=1; }
  done
fi

if [[ "${KEEP_DB:-0}" != "1" ]]; then
  psql_x -d postgres -c "DROP DATABASE IF EXISTS ${DBNAME}" >/dev/null 2>&1 || true
fi

echo
if (( FAIL )); then echo "===== 全链路验证失败 ====="; exit 1; fi
echo "===== 全链路验证通过（平台 ${PLATFORM}）====="
