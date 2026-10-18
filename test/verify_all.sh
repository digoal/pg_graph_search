#!/usr/bin/env bash
# 全链路验证：静态门禁 -> 全新装扩展 -> 正确性 -> 回归
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
step() { echo; echo "########## $* ##########"; }

step "1. SQL 模板静态门禁"
python3 test/lint_sql.py || FAIL=1

step "2. 构建并安装扩展"
make sql >/dev/null && make install >/dev/null 2>&1 && echo "make OK" || { echo "make FAIL"; FAIL=1; }

step "3. 全新 CREATE EXTENSION"
su postgres -c "psql -X -q -v VERBOSITY=terse -d postgres -c \
  'DROP EXTENSION IF EXISTS pg_graph_search CASCADE; DROP SCHEMA IF EXISTS gtest CASCADE;'"
su postgres -c "psql -X -q -v VERBOSITY=terse -d postgres -c 'CREATE EXTENSION pg_graph_search;'" \
  && echo "CREATE EXTENSION OK" || { echo "CREATE EXTENSION FAIL"; FAIL=1; }

step "4. 元函数链路（advise / plan / install）"
su postgres -c "psql -X -q -v VERBOSITY=terse -d postgres -f test/01_setup.sql" \
  && echo "setup OK" || { echo "setup FAIL"; FAIL=1; }

step "5. 正确性验证（15 项；第 14/15 项的 ERROR 是预期的抛错断言）"
su postgres -c "psql -X -q -v VERBOSITY=terse -d postgres -f test/02_correctness.sql" > /tmp/_corr.log 2>&1
# 只把"非预期行号"的 ERROR 算失败：预期抛错的两项在第 71 / 77 行
BADERR=$(grep -E "^psql:.*ERROR" /tmp/_corr.log | grep -vE ":71:|:77:" || true)
if [[ -n "$BADERR" ]]; then
  echo "$BADERR" | head -5; FAIL=1
else
  n=$(grep -cE "^psql:.*ERROR" /tmp/_corr.log || true)
  echo "correctness OK（$n 个预期抛错，其余全过）"
fi

step "6. 断言式回归（16 项）"
su postgres -c "psql -X -q -v VERBOSITY=terse -d postgres -f test/03_regress.sql" > /tmp/_reg.log 2>&1
tail -3 /tmp/_reg.log
if grep -q "ERROR" /tmp/_reg.log; then
  grep -E "ERROR" /tmp/_reg.log | head -5; FAIL=1
else
  echo "regress OK（16/16）"
fi

step "7. Markdown 渲染门禁"
python3 /root/new/shared_proj/markdown-render-check/markdown_render_check.py README.md --quiet \
  && echo "markdown OK" || { echo "markdown FAIL"; FAIL=1; }

echo
if (( FAIL )); then echo "===== 全链路验证失败 ====="; exit 1; fi
echo "===== 全链路验证通过 ====="
