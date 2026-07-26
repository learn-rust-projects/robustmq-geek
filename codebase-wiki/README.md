# Codebase Wiki

This wiki reverse engineers `placement-center` (RobustMQ Geek demo) from code
structure → runtime mechanism → core abstractions → architecture boundaries →
design tradeoffs → system cognition output.

## How to read this wiki

Start with the seven deliverables, then inspect phase analysis views, then
follow links into atomic notes. **Read [05-tradeoffs](analysis/05-tradeoffs.md)
before assuming anything is production-grade**——这个仓库是教学演示，多处硬编码
和 demo bug 已在 atoms 中显式标注。

## Seven deliverables

1. [架构图](analysis/architecture-diagram.md)
2. [启动流程](analysis/startup-flow.md)
3. [请求链路](analysis/request-flow.md)
4. [核心对象](analysis/03-core-design.md)
5. [关键算法](analysis/03-core-design.md)
6. [设计权衡](analysis/05-tradeoffs.md)
7. [经验总结](analysis/lessons-learned.md)

## Phase analysis views

- [01 Repository Mapping](analysis/01-repo-map.md)
- [02 Runtime Analysis](analysis/02-runtime.md)
- [03 Core Design](analysis/03-core-design.md)
- [04 Architecture](analysis/04-architecture.md)
- [05 Tradeoffs](analysis/05-tradeoffs.md)

## Atomic notes index

### By topic

<!-- Group atoms by topic. Each topic heading matches a subfolder in atoms/. -->

#### raft
- [data route](atoms/data-route.md) — 自研 raft 路径的状态机分发器；含已知 demo bug
- [dual impl cost](atoms/dual-impl-cost.md) — 两套 raft 实现并存的复杂度成本
- [dual raft paths](atoms/dual-raft-paths.md) — 自研 raft-rs 路径 vs openraft 路径并列
- [dual state machine tradeoff](atoms/dual-state-machine-tradeoff.md) — 内存 BTreeMap vs RocksDB state machine
- [leader-only write](atoms/leader-only-write.md) — 只有 leader 能 propose 写入的不变量
- [raft log continuity](atoms/raft-log-continuity.md) — 日志连续性不变量
- [raft ready loop](atoms/raft-ready-loop.md) — raft-rs 主事件循环算法

#### openraft
- [openraft cluster init](atoms/openraft-cluster-init.md) — 最小 node_id 节点单点初始化集群
- [openraft KV write path](atoms/openraft-kv-write-path.md) — `client_write → apply → BTreeMap` 全链路
- [openraft TypeConfig](atoms/openraft-typeconfig.md) — `declare_raft_types!` 装配点

#### storage
- [big-endian log key](atoms/big-endian-log-key.md) — openraft 用 BE u64 编码 log_index 让 RocksDB 字典序匹配数值序
- [rocksdb engine](atoms/rocksdb-engine.md) — 共享 RocksDB 单例 + 多 CF
- [rocksdb single instance tradeoff](atoms/rocksdb-single-instance-tradeoff.md) — 单 DB + CF vs 多 DB tradeoff

#### foundation
- [client pool](atoms/client-pool.md) — mobc 连接池，按 (service, addr) 维度复用 tonic client
- [demo hardcoding](atoms/demo-hardcoding.md) — HTTP/gRPC 演示态硬编码 vs 生产可用 tradeoff
- [placement-center config](atoms/placement-center-config.md) — `OnceLock` 全局配置单例
- [process bootstrap](atoms/process-bootstrap.md) — `cmd::main → start_server` 启动算法
- [robustmq error](atoms/robustmq-error.md) — 统一错误模型 `RobustMQError`
- [workspace layout](atoms/workspace-layout.md) — 5-crate Cargo workspace 拓扑

## Inbox

Drop raw notes into [inbox/](inbox/). On the next skill run, notes are extracted
into atoms and moved to [inbox/processed/](inbox/processed/).

## Reference materials

补充参考资料：原始代码片段、设计文档摘录、外部链接摘要等。
atoms 只保留最有价值的精华，reference 作为素材库供 atoms 引用。
- [Reference](reference/)

## Learning loop

- [Open questions](questions/open/)
- [Solving questions](questions/solving/)
- [Answered questions](questions/answered/)
- [Learning plans](plans/)
- [Items — draft](items/draft/)
- [Items — next-actions](items/next-actions/)
- [Items — in-progress](items/in-progress/)
- [Items — review](items/review/)
- [Items — done](items/done/)
- [Tasks](tasks/)
- [Blog drafts](blog/drafts/)
- [Published posts](blog/published/)

## Evidence and maintenance

- Analysis target: `/home/l/projects/robustmq-geek` (branch: `release`)
- Last full analysis: 2026-06-16
- Last inbox processing: 2026-06-16 (inbox 为空)
- Stale areas: 无（全部 phase 0-5 已完成）
- 已识别但未修复的代码层 bug（在 atoms 中标注，留给后续 questions/plans 处理）：
  - `DataRoute::route` 二次解码用错变量（[data-route](atoms/data-route.md)）
  - `services_kv_new.rs::set/delete` 硬编码 `"k1"/"v1"`（[demo-hardcoding](atoms/demo-hardcoding.md)）
  - `services_kv_new.rs::get` 写读不一致（写内存 BTreeMap，读 RocksDB）
  - `services_openraft.rs` 用 `bincode::deserialize(...).unwrap()`
  - `cmd::main` 没调 `start_server`，binary 不能直接 run
  - `lib.rs` 中 `raft.run()` 被注释，自研 raft 路径不在 runtime 范围内
