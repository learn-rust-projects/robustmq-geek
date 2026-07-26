---
type: concept
tags: [raft, openraft, architecture, comparison]
backlinks:
  - ../analysis/01-repo-map.md
  - ../analysis/02-runtime.md
  - ../analysis/03-core-design.md
  - ../analysis/04-architecture.md
  - ../analysis/05-tradeoffs.md
refs:
  - src/placement-center/src/raft/mod.rs
  - src/placement-center/src/openraft/mod.rs
  - src/placement-center/src/lib.rs
---

# Dual Raft Paths

## Definition

placement-center 同时实现了**两条**互相独立的 raft 路径，业务逻辑（KV）可以走任一条达成共识。
这是仓库的核心特征——课程演示 `raft-rs` 与 `openraft` 两种风格的对照。

## Evidence

- `src/placement-center/src/raft/mod.rs`：自研路径（基于 `raft-rs`）。
- `src/placement-center/src/openraft/mod.rs`：openraft 路径（基于 `openraft` crate）。
- `src/placement-center/src/lib.rs:60-100`：两条路径在 `start_server` 中并存；
  `tokio::spawn(async move { start_openraft_node(...) })` 启用 openraft，
  而 `// raft.run().await;` 把自研 raft 主循环注释掉了——**当前运行时只跑 openraft 一条**。

## Details

| 维度 | 自研 raft（`raft/`） | openraft（`openraft/`） |
|------|----------------------|--------------------------|
| 底层 crate | `raft-rs`（fork from robustmq） | `openraft`（databendlabs fork） |
| 状态机 | `DataRoute` 自己写，apply 到 RocksDB | `StateMachineStore` 内存 `BTreeMap` |
| 日志存储 | `RaftRocksDBStorage` 适配 raft-rs `Storage` trait | `LogStore` 实现 openraft `RaftLogStorage` |
| 网络层 | `PeersManager` + tonic `PlacementCenterService` | `Network`/`NetworkConnection` + tonic `OpenRaftService` |
| 业务入口 | `RaftMachineApply::apply_propose_message` | `Raft<TypeConfig>::client_write` |
| KV gRPC service | `services_kv.rs`（leader 检测 + 转发 + propose） | `services_kv_new.rs`（直接 client_write） |
| HTTP 调试路由 | 无 | `server/http/openraft.rs`（demo handler） |
| RocksDB CF | `cluster` | `_raft_logs` + `_raft_store` |

两条路径**共享** `RocksDBEngine` 实例和同一份 `placement_cluster: RaftGroupMetadata`，
但日志/状态机互不影响（不同 CF / 不同存储路径）。

## 为什么保留两条

教学价值：

- raft-rs 是 "ready loop" 风格——你写主循环，frame work 给你 ready 你处理。
- openraft 是声明式——你声明 `TypeConfig`，trait 拼装好了。
- 同一个业务（KV）在两套范式里实现，对比工作量、出错点、可扩展性。

## 注意事项

- 当前运行时只走 openraft；自研 raft 路径仍编译，但 `raft.run()` 注释掉，**不会消费 channel**。
- 如果重新启用 `raft.run()`，需要确认两条路径的状态机是否冲突——共享 `placement_cluster`
  metadata 时谁来写 leader 信息要明确。
