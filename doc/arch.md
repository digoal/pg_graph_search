# pg_graph_search 三张图

## 图 1　图搜索算法

![pg_graph_search 图搜索算法](pg_graph_search_1_algorithm.svg)

覆盖内容：

- `plan()` / `install()` 的分工——前者只拼 DDL 文本供预览，后者才执行
- 边视图：有向直映射 vs 无向 `UNION ALL` 双向展开
- N 度搜索的递归 CTE 锚点/递归项，以及 `path` 数组防环与每层 `LIMIT` 剪枝
- 逐层展开的实例用的是 `test/03_regress.sql` 的确定性小图，`root=1 depth=3` 实际出 9 条路径，与 R2 断言一致
- 最短路径为什么用显式 BFS 而不是「递归 CTE + LIMIT 1」
- `subgraph` / `stats` 复用同一条递归 CTE

## 图 2　两个平台的调用逻辑对比

![两平台调用逻辑对比](pg_graph_search_2_platform_compare.svg)

覆盖内容：

- 装载 / 建对象 / 取数 / 查询四步在两个平台上的差异
- OpenTenBase 侧画出实测集群拓扑（GTM:6666 / CN:11000 / DN1:12001 / DN2:12002）
- `CREATE EXTENSION` 在 OTB 是 PREPARE + EXECUTE 两阶段并广播到全部节点
- 生成函数是 CN 侧 pull-up 函数，DN 上的副本不参与计算
- 底部表格是 pull-up 函数的 SQL 边界表，**每一条都是实测到的内核报错原文**，不是推测

## 图 3　适配做了什么

![适配做了什么](pg_graph_search_3_adaptation.svg)

四层结构：

1. **代码层**——平台差异只有 3 处（`@DISTRIBUTE_CLAUSE@`、`sql_mode='all'`、`registry_distribution()`），以及为什么注册表必须是 REPLICATION
2. **构建层**——`OPENTENBASE` 一个开关出两份产物；默认值为什么必须跟着构建方式走
3. **真机上发现并修正的 5 件事**——分布策略写错、验证脚本在干净环境必失败、断言用了会静默出错的写法、压测脚本 DROP 顺序、集群搭建本身的坑
4. **验证结果**——两个平台从空目录构建安装全量跑测试的结论，以及明确标注的未覆盖项（`opentenbase_ora` 模式）
  
