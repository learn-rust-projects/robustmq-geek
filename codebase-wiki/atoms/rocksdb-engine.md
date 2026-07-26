---
type: object
tags: [storage, rocksdb, encapsulation]
backlinks:
  - ../analysis/03-core-design.md
  - ../analysis/04-architecture.md
refs:
  - src/placement-center/src/storage/rocksdb.rs
  - src/placement-center/src/storage/engine.rs
  - src/placement-center/src/storage/keys.rs
---

# RocksDBEngine

## Definition

RocksDB 的薄封装。整个 placement-center 进程只有一个 `Arc<RocksDBEngine>` 实例，
所有需要持久化的子模块（业务 KV、自研 raft 日志/元数据、openraft 日志/状态机）
都从这里拿 column family handle 读写。

## Evidence

- `src/placement-center/src/storage/rocksdb.rs`：包装结构 + 通用 read/write/exist。
- `src/placement-center/src/storage/engine.rs`：`engine_*_by_cluster` 函数族。
- `src/placement-center/src/storage/keys.rs`：所有逻辑前缀（`/raft/...` 等）。

## Responsibility

- 持有 `rocksdb::DB`。
- 创建 / 维护多个 column family。
- 提供 `read` / `write` / `delete` / `exist` 等 generic helper。
- **不**做业务逻辑：业务相关的 key 编码、序列化在 `KvStorage` / `RaftMachineStorage` 等上层。

## Column families（实际使用）

| CF 名 | 用途 | 写入方 |
|-------|------|--------|
| `cluster` | 自研 raft 路径下的业务 KV / raft 元数据，按 `keys.rs` 前缀划分逻辑命名空间 | `KvStorage`, `RaftMachineStorage` |
| `_raft_logs` | openraft 日志条目（big-endian u64 index 作 key） | `LogStore` |
| `_raft_store` | openraft 元数据（vote、committed、last_purged、snapshot） | `LogStore`, `StateMachineStore` |

## 关键 API

- `RocksDBEngine::new(&PlacementCenterConfig)`：从配置打开 `data_path` 下的 DB。
- `read<T: DeserializeOwned>(cf, key)`：通用读取 + serde_json 反序列化。
- `write<T: Serialize>(cf, key, &val)`：通用写入。
- `exist(cf, key)`：基于 bloom filter 的"可能存在"判定（**有假阳性**）。
- `delete(cf, key)` / `read_prefix(cf, prefix)`。

## 与 raft 路径的关系

- 自研 raft 的日志/状态机也走 `RocksDBEngine`（同一份 DB），但用不同前缀 +
  同一个 `cluster` CF。逻辑命名空间靠 key 前缀（`/raft/log/...`、`/raft/snapshot/...`）。
- openraft 路径走独立的 `_raft_logs` / `_raft_store` CF；它的 state machine
  数据**不在** RocksDB，而在内存 BTreeMap。

## Notes

- `key_may_exist_cf` 仅供"快速预检"，业务不能依赖它做强一致判断。
- 没有显式的事务接口；写多个 key 不是原子的（需要的话上层用 batch）。
