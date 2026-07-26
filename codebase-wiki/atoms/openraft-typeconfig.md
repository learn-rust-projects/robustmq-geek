---
type: object
tags: [openraft, type-config, declarative]
backlinks:
  - ../analysis/03-core-design.md
refs:
  - src/placement-center/src/openraft/typeconfig.rs
  - src/placement-center/src/openraft/route/mod.rs
---

# TypeConfig (openraft)

## Definition

openraft 用关联类型驱动整个 raft 实现：用户声明一个 `TypeConfig`，把
请求/响应/节点/快照等类型一次性绑定，框架的所有泛型都通过 `TypeConfig` 解析。
这是 openraft "声明式" 风格的核心机制。

## Evidence

- `src/placement-center/src/openraft/typeconfig.rs`：
  ```rust
  openraft::declare_raft_types!(
      pub TypeConfig:
          D = AppRequestData,
          R = AppResponseData,
          Node = Node,
  );
  ```
- `src/placement-center/src/openraft/route/mod.rs`：`AppRequestData` / `AppResponseData` 定义。

## 关联类型解析

| 关联类型 | 绑定到 | 作用 |
|----------|--------|------|
| `D` (Decision) | `AppRequestData::{Set, Delete}` | 业务命令；leader propose 时打包，apply 时分发 |
| `R` (Response) | `AppResponseData { value: Option<String> }` | apply 完成后返回给 client_write 的结果 |
| `Node` | `Node { node_id, rpc_addr }` | 节点元信息；写进 log 的 membership entry |
| `SnapshotData` | `Cursor<Vec<u8>>` | snapshot 的字节流类型 |

## 为什么这么设计

声明式有几个好处：
- 所有 trait 实现（`RaftLogStorage`, `RaftStateMachine`, `RaftNetwork`）都用同一组
  类型，编译器会卡住任何不一致。
- 业务命令的 `enum AppRequestData` 自带 serde 派生，序列化成 raft entry payload
  自动完成，不需要业务手工 encode。
- 替换底层实现（比如把 RocksDB 换 sled）只改对应 trait impl，业务完全不动。

## 与自研 raft 路径对比

自研路径里业务命令是 `StorageData { data_type: StorageDataType, value: Vec<u8> }`，
`value` 是 prost 编码的 bytes，apply 时再二次解码。这是"运行时类型"风格——
框架不知道命令的具体形状，只把 bytes 投递给状态机。

声明式（openraft）vs 运行时（raft-rs）：
- **类型安全**：openraft > raft-rs。
- **样板代码**：openraft 少（不用手工 encode/decode）。
- **灵活性**：raft-rs 可以混合多种业务命令类型；openraft 必须把所有命令塞进一个 enum。
