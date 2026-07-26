---
type: object
tags: [error, cross-cutting]
backlinks:
  - ../analysis/01-repo-map.md
  - ../analysis/04-architecture.md
refs:
  - src/common/base/src/errors.rs
---

# RobustMQError

## Definition

跨 crate 的统一错误枚举，使用 `thiserror::Error` 派生。所有底层错误（IO/RocksDB/
serde/tonic Status）都通过 `#[from]` 自动转换进来，业务层只关心这一个类型。

## Evidence

- `src/common/base/src/errors.rs`：枚举定义。

## 主要变体

- `IOJsonError(io::Error)`、`RocksdbError(rocksdb::Error)`、`SerdeJsonError`：来自外部 crate 的自动转换。
- `ParameterCannotBeNull(String)`：参数校验。
- `ClusterNoAvailableNode`：客户端没有可用节点（`retry_call` 返回）。
- `RaftLogCommitTimeout(String)`：raft propose 30s 仍未 apply 的超时信号。
- `NoAvailableGrpcConnection(String, String)`：连接池空。
- `GrpcServerStatus(Status)`：tonic 服务端返回非 Ok。
- `CommmonError(String)`：通用包装错误。

## 注意事项

- `CommmonError` 是**保留的拼写错误**（多了一个 m），全仓库引用，重命名属破坏性改动。
- `RaftLogCommitTimeout` 是上层判定"提交失败"的唯一信号——业务无法区分 "raft 拒绝"
  与 "30s 超时未 ack"，统一按超时处理。
