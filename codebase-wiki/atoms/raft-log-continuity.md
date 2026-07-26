---
type: invariant
tags: [raft, log, rocksdb, consistency]
backlinks:
  - ../analysis/03-core-design.md
refs:
  - src/placement-center/src/storage/raft.rs
---

# Raft Log Continuity Invariant

## Rule

`RaftMachineStorage::append` 必须满足两条不变量，违反任一条直接 panic：

1. `first_index <= entrys[0].index`：不允许覆盖已被 compact 的日志。
2. `last_index + 1 >= entrys[0].index`：日志必须连续，不允许中间出现空洞。

## Why

raft 协议要求 log 是**有序、连续、不可空洞**的序列。这两条是 raft 一致性的硬约束：
- 若违反（1），等于试图改写已 truncate 的历史，会和 leader 视图永久不一致。
- 若违反（2），中间留洞，apply / replay 时会读到未定义状态。

raft-rs 框架本身在 `step()` 里通过逻辑保证不会触发这两种情况；但 `Storage` trait
实现需要把这层保证显式 assert，作为对自身实现的"防御"——一旦上层逻辑出 bug，
应该在最早的可观测点 panic，而不是悄悄写错日志。

## Enforcement sites

- `src/placement-center/src/storage/raft.rs:append`：两条 assert。

## Violation consequences

- 进程 panic，systemd 重启。
- 但 RocksDB 中已写入的"前置"内容仍存在；下次启动按 `last_index` 读出来时
  和 leader 复制的 index 错位，这时才会被 raft-rs 检测出来。
- 课程版接受这种"暴露问题大于优雅恢复"的取舍。
