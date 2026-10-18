#!/usr/bin/env bash
# 并行灌大规模测试数据
# 用法: bash bench/gen_big.sh <节点数> <每点出边> <分群数> <并发数>
set -euo pipefail
NODES=${1:-20000}
FANOUT=${2:-50}
BUCKETS=${3:-40}
JOBS=${4:-4}
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUCKET_SIZE=$(( NODES / BUCKETS ))

echo ">>> nodes=$NODES fanout=$FANOUT buckets=$BUCKETS jobs=$JOBS 预计边数=$((NODES*FANOUT/1000000))M"

su postgres -c "psql -X -q -v VERBOSITY=terse -d postgres -c \"
  DROP TABLE IF EXISTS big_edge;
  CREATE UNLOGGED TABLE big_edge (c1 int, c2 int, prop jsonb, PRIMARY KEY (c1,c2));
  ALTER TABLE big_edge SET (autovacuum_enabled=off, toast.autovacuum_enabled=off);
  DROP SCHEMA IF EXISTS gbench CASCADE; DROP SCHEMA IF EXISTS gbench_u CASCADE;
\""

STEP=$(( NODES / JOBS ))
pids=()
for ((j=0; j<JOBS; j++)); do
  LO=$(( j * STEP + 1 ))
  HI=$(( (j+1) * STEP ))
  [[ $j -eq $((JOBS-1)) ]] && HI=$NODES
  su postgres -c "psql -X -q -v VERBOSITY=terse -d postgres \
     -v nodes=$NODES -v fanout=$FANOUT -v buckets=$BUCKETS -v bucket_size=$BUCKET_SIZE \
     -v lo=$LO -v hi=$HI \
     -c \"INSERT INTO big_edge (c1,c2,prop)
         SELECT id, ((width_bucket(id,1,$NODES,$BUCKETS)-1)*$BUCKET_SIZE
                     + ceil(random()*($BUCKET_SIZE-1))::int),
                jsonb_build_object('weight', round((random()*1000)::numeric/1000,3))
           FROM generate_series($LO,$HI) s(id), LATERAL generate_series(1,$FANOUT) g
         ON CONFLICT (c1,c2) DO NOTHING;\"" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait $p; done

echo ">>> vacuum analyze..."
su postgres -c "psql -X -q -v VERBOSITY=terse -d postgres -c 'VACUUM ANALYZE big_edge;'"

echo ">>> 安装图搜索实例..."
su postgres -c "psql -X -q -v VERBOSITY=terse -d postgres -c \"
  CREATE SCHEMA gbench; CREATE SCHEMA gbench_u;
  SELECT graph_search.install(jsonb_build_object('table','public.big_edge','c1','c1','c2','c2',
    'prop','prop','target_schema','gbench','prefix','b','directed',true,'max_depth_cap',10));
  SELECT graph_search.install(jsonb_build_object('table','public.big_edge','c1','c1','c2','c2',
    'prop','prop','target_schema','gbench_u','prefix','bu','directed',false,'max_depth_cap',10));
\""

su postgres -c "psql -X -d postgres -c \"
  SELECT count(*) AS edges,
         pg_size_pretty(pg_total_relation_size('big_edge')) AS total_size
    FROM big_edge;\""
