#!/usr/bin/env bash
# ============================================================================
# OpenTenBase 单机 1CN + 2DN 分布式集群构建脚本（可复现）
#
# 用途：为 contrib/pg_graph_search 的 OpenTenBase 适配提供真机验证环境。
#
# 本脚本固化了搭建过程中踩到的 4 个坑（每个都有实测证据）：
#   1) DN 上不能写 gtm_host / gtm_port —— 本版本只认 gtm_unix_socket_directory，
#      写了会 FATAL: configuration file contains errors。
#   2) pooler_port 全节点默认值都是 6667，而 pooler 的 unix socket 锁文件只按
#      端口命名（/tmp/.s.PGPOOL.<port>.lock）。同机多节点共用默认端口时，
#      只有一个节点的 pooler 能起来，其余的 pooler 进程每秒 FATAL 一次，
#      CN 的分布式远程连接永远建不起来 → 任何跨节点语句挂死。
#      必须给每个节点分配互不相同的 pooler_port。
#   3) forward_port 默认 6669，同样会互相冲突，必须逐节点错开。
#   4) initdb 必须带 --master_gtm_nodename/--master_gtm_ip/--master_gtm_port，
#      否则 pgxc_node 里没有 GTM 行，启动后所有语句报
#      "GetMasterGtmInfo: can not get master gtm info from pgxc_node"。
#
# 用法：sudo bash build_cluster.sh [BASE]   # BASE 默认 /tmp/otb_cluster
# ============================================================================
set -euo pipefail

BASE="${1:-/tmp/otb_cluster}"

# OpenTenBase 的 bin 目录：优先用 OTB_BIN；否则从 PATH 上的 postgres 反推；
# 都没有就直接报错，不要写死某台机器的路径。
if [[ -z "${OTB_BIN:-}" ]]; then
  _pg="$(command -v postgres || true)"
  if [[ -n "$_pg" ]]; then
    OTB_BIN="$(dirname "$_pg")"
  else
    echo "找不到 OpenTenBase 的 postgres，请先 export OTB_BIN=<opentenbase 安装目录>/bin" >&2
    exit 1
  fi
fi
if [[ ! -x "$OTB_BIN/postgres" ]]; then
  echo "OTB_BIN=$OTB_BIN 下没有 postgres 可执行文件" >&2
  exit 1
fi
echo ">>> 使用 OpenTenBase: $OTB_BIN ($("$OTB_BIN/postgres" --version))"

export LD_LIBRARY_PATH="${OTB_BIN%/bin}/lib"
export PATH="$OTB_BIN:$PATH"

CN_PORT=11000;  CN_FWD=11001;  CN_POOL=11004
D1_PORT=12001;  D1_FWD=12003;  D1_POOL=12007
D2_PORT=12002;  D2_FWD=12004;  D2_POOL=12008
GTM_PORT=6666;  GTM_NAME=a_one
DBUSER=postgres

run_as_pg() { su postgres -c "$1"; }

echo "==> 清理旧实例"
{ ps -ef | grep -E "(bin/(postgres|gtm)).*$BASE" | grep -v grep | awk '{print $2}' \
  | while read -r p; do kill -9 "$p" 2>/dev/null || true; done; } || true
# gtm 是以相对路径启动的（`gtm -D .../gtm`），上面的模式匹配不到，单独按数据目录兜底
{ pgrep -f "^gtm -D $BASE/gtm" | while read -r p; do kill -9 "$p" 2>/dev/null || true; done; } || true
rm -f /tmp/.s.PGPOOL.* /tmp/.s.GTM.* /tmp/.s.PGSQL.11* /tmp/.s.PGSQL.12* 2>/dev/null || true
sleep 2
rm -rf "$BASE"
mkdir -p "$BASE"
chown postgres:postgres "$BASE"

echo "==> 初始化 GTM（$GTM_NAME:$GTM_PORT）"
# initgtm 要求目标目录不存在或为空（它自己负责创建），且不接受 nodename/port 参数 ——
# 这两个值只能来自 gtm.conf，所以顺序是：先 initgtm，再覆盖 gtm.conf。
run_as_pg "$OTB_BIN/initgtm -Z gtm -D $BASE/gtm"
cat > "$BASE/gtm/gtm.conf" <<EOF
nodename = '$GTM_NAME'
port = $GTM_PORT
EOF
chown postgres:postgres "$BASE/gtm/gtm.conf"

echo "==> initdb：cn0001 / dn0001 / dn0002"
for spec in "cn:cn0001:coordinator:$CN_PORT" "dn1:dn0001:datanode:$D1_PORT" "dn2:dn0002:datanode:$D2_PORT"; do
  dir="${spec%%:*}"; rest="${spec#*:}"
  name="${rest%%:*}"; rest="${rest#*:}"
  ntype="${rest%%:*}"; port="${rest##*:}"
  run_as_pg "$OTB_BIN/initdb -U $DBUSER -E utf8 --locale=zh_CN.utf8 \
      --nodename $name --nodetype $ntype -D $BASE/$dir \
      --master_gtm_nodename $GTM_NAME --master_gtm_ip 127.0.0.1 \
      --master_gtm_port $GTM_PORT" > "$BASE/$dir.initdb.log" 2>&1
  echo "    $dir ($name/$ntype) 端口 $port"
done

echo "==> 写入逐节点 GUC（forward_port / pooler_port 必须错开，见脚本头注释）"
apply_guc() {  # $1=dir $2=port $3=fwd $4=pool
  cat >> "$BASE/$1/postgresql.conf" <<EOF

# --- OTB per-node overrides (single-host cluster, must not collide) ---
port = $2
forward_port = $3
pooler_port = $4
EOF
  chown postgres:postgres "$BASE/$1/postgresql.conf"
}
apply_guc cn  "$CN_PORT" "$CN_FWD" "$CN_POOL"
apply_guc dn1 "$D1_PORT" "$D1_FWD" "$D1_POOL"
apply_guc dn2 "$D2_PORT" "$D2_FWD" "$D2_POOL"

echo "==> 启动 GTM"
run_as_pg "$OTB_BIN/gtm_ctl start -D $BASE/gtm -w -t 30 -l $BASE/gtm.log"
sleep 2

echo "==> 启动 DN（先起数据节点，再起协调节点）"
for d in dn1 dn2; do
  run_as_pg "$OTB_BIN/pg_ctl start -Z datanode -D $BASE/$d -o '-i' -w -t 30 -l $BASE/$d.log"
done
sleep 3
run_as_pg "$OTB_BIN/pg_ctl start -Z coordinator -D $BASE/cn -o '-i' -w -t 30 -l $BASE/cn.log"
sleep 3

echo "==> 注册节点 + 建立默认 node group"
run_as_pg "$OTB_BIN/psql -h 127.0.0.1 -p $CN_PORT -U $DBUSER -d postgres -v ON_ERROR_STOP=1" <<SQL
CREATE NODE dn0001 WITH (TYPE='datanode', HOST='127.0.0.1', PORT=$D1_PORT);
CREATE NODE dn0002 WITH (TYPE='datanode', HOST='127.0.0.1', PORT=$D2_PORT);
SELECT pgxc_pool_reload();
CREATE DEFAULT NODE GROUP ng1 WITH (dn0001, dn0002);
SQL
sleep 2

echo "==> 自检"
run_as_pg "$OTB_BIN/psql -h 127.0.0.1 -p $CN_PORT -U $DBUSER -d postgres" <<'SQL'
SELECT node_name, node_type, node_host, node_port FROM pgxc_node ORDER BY node_name;
SELECT group_name, default_group FROM pgxc_group;
CREATE TABLE _otb_probe(id int) DISTRIBUTE BY shard (id);
INSERT INTO _otb_probe SELECT generate_series(1,100);
SELECT count(*) AS rows_on_both_dn FROM _otb_probe;
DROP TABLE _otb_probe;
SQL

echo
echo "==> 完成。连接串：psql -h 127.0.0.1 -p $CN_PORT -U $DBUSER -d postgres"
