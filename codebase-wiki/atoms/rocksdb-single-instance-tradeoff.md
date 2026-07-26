---
type: tradeoff
tags: [storage, rocksdb, single-instance, blast-radius]
backlinks:
  - ../analysis/05-tradeoffs.md
refs:
  - src/placement-center/src/storage/rocksdb.rs
---

# Tradeoff: RocksDB 单例 + CF 隔离 vs 多实例

## Choice

整个进程共享**同一个** RocksDB 实例（`RocksDBEngine` Arc），通过 column family
隔离不同用途的数据：

- `cluster`：自研 raft 路径的业务 KV + raft 元数据。
- `_raft_logs`：openraft 日志。
- `_raft_store`：openraft snapshot / vote / committed。

## Benefits

- 资源占用低：一个 LSM tree、一组 background thread、一个 WAL 文件。
- 实现简单：不用为不同用途各自管理一个 DB handle / 配置。
- 便于跨 CF 的原子性扩展（虽然当前没用）。

## Costs

- **compaction / flush 互相影响**：openraft 大量小 log entry 触发的 L0→L1 compaction
  会消耗 IO，影响业务 KV 的 read latency。
- **配置一刀切**：write_buffer_size / max_write_buffer_number / WAL 都是全局设置，
  raft log（写多读少、有过期）和业务 KV（读多）的最优配置不同，无法分别调。
- **故障 blast radius 大**：一个 CF 数据损坏（例如断电时 WAL 截断不一致），所有
  CF 的 DB open 都会失败。
- **删除 CF 不能在线做**：换存储或重建索引需要全实例下线。

## Affected qualities

- latency：业务 KV 受 raft log 写入风暴影响。
- operability：升级 RocksDB / 调参影响所有路径。
- correctness：CF 边界靠"prefix 命名 + 业务自觉"维持，没有编译期保证。

## Alternatives

- 双 DB 实例：raft log 一个 DB（侧重写性能 + 短 retention），业务 KV 一个 DB
  （侧重读性能）。代价是多一份资源 + 跨 DB 原子性更难。
- 用专门的 raft log 存储（mmap / append-only file）替代 RocksDB log_store，把
  RocksDB 留给状态机。

## Evidence

- `src/placement-center/src/storage/rocksdb.rs`：`RocksDBEngine::new` 一次性 open
  所有 CF；`exist`/`read`/`write` 都接受 `&ColumnFamily`。
- `src/placement-center/src/openraft/store/log_store.rs` 和 `storage/kv.rs` 共享
  同一个 `Arc<RocksDBEngine>`。

## Why this matters

这条 tradeoff 决定了 placement-center "单进程 / 单 DB" 的形态。如果未来要支持
"raft log 高吞吐写"或"业务 KV 高 read 吞吐"，第一刀就会切在这里。
