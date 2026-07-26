---
type: tradeoff
tags: [openraft, raft-rs, state-machine, persistence]
backlinks:
  - ../analysis/05-tradeoffs.md
refs:
  - src/placement-center/src/openraft/store/state_machine_store.rs
  - src/placement-center/src/storage/kv.rs
---

# Tradeoff: 内存 state machine vs RocksDB state machine

## Choice

两条 raft 路径采用相反的 state machine 持久化策略：

- **openraft 路径**：state machine 是 `Arc<RwLock<BTreeMap<String,String>>>`（纯内存），
  靠 snapshot 周期性 dump 到 RocksDB `_raft_store` CF。
- **自研 raft 路径**：state machine 直接写 RocksDB `cluster` CF（`KvStorage`），每条
  apply 都同步落盘。

## Benefits

- openraft 路径 apply O(1) 内存写，吞吐高、延迟低；snapshot 成本摊到周期性任务。
- 自研路径 crash 后无需 replay log——state machine 已经在 disk 上，重启读 RocksDB 即可。

## Costs

- openraft 路径 crash 后要从 last snapshot + log replay 重建 BTreeMap，启动慢；
  状态机变大时 snapshot 序列化成本高（当前实现 `serde_json` dump 整个 BTreeMap）。
- 自研路径每条命令 O(log n) RocksDB 写 + fsync（取决于 WAL 设置），apply 阻塞 raft
  ready loop；写放大随 RocksDB compaction 浮动。

## Affected qualities

- latency：自研路径每写都同步 disk → tail latency 高；openraft 路径写延迟仅由
  raft 多数派 + 内存写决定。
- recovery time：openraft 路径正比于 (snapshot size + log length)；自研路径仅打开
  RocksDB 即就绪。
- memory footprint：openraft 整个 KV 存内存；自研路径几乎为零。

## Alternatives

- 让 openraft state machine 用 RocksDB 后端（参考 openraft examples 的
  `rocksstore`），代价是失去内存 BTreeMap 带来的零拷贝读。
- 让自研路径引入 write batch + 异步 apply，把 disk 写从 ready loop 移到后台。

## Evidence

- `src/placement-center/src/openraft/store/state_machine_store.rs`：apply 路径写
  `kvs: Arc<RwLock<BTreeMap>>`；snapshot 路径序列化整个 map。
- `src/placement-center/src/storage/kv.rs`：`KvStorage::set` 直接调
  `RocksDBEngine::write`，无 batching。

## Why this matters

这个 tradeoff 不是孤立的——它和 [services_kv_new.rs 写读不一致] 直接相关：openraft
写内存 BTreeMap，但同一个 service 的 `get` 读 RocksDB `KvStorage`，两份数据从来不
对齐。修复方式取决于"openraft 是否要把状态持久化到 KvStorage"——这是个 design
question 不是 bug，需要先决定。
