---
type: algorithm
tags: [raft, ready-loop, raft-rs]
backlinks:
  - ../analysis/02-runtime.md
  - ../analysis/03-core-design.md
refs:
  - src/placement-center/src/raft/machine.rs
  - src/placement-center/src/raft/apply.rs
---

# Self-Built Raft Ready Loop

## Definition

自研 raft 路径基于 `raft-rs`，核心是 `RaftMachine::run` 主循环：100 ms 一拍，
轮询 mpsc channel 收命令，定期调 `tick()`，最后通过 `on_ready` 处理 raft-rs 的
ready 状态。

## Inputs

- `receiver: mpsc::Receiver<RaftMessage>`：业务命令、其他节点的 raft message、conf-change、transfer-leader。
- `RawNode`：raft-rs 的核心对象，封装持久状态 + 主循环的 step 接口。
- `placement_cluster: Arc<RwLock<RaftGroupMetadata>>`：内存视图。
- `data_route: Arc<RwLock<DataRoute>>`：apply 已提交日志到 RocksDB。

## Outputs

- 持久化日志、hard_state、snapshot 到 RocksDB。
- 通过 oneshot channel 回 ack 给业务侧。
- 通过 `peer_message_send` 把出站 raft message 发到 `PeersManager`。

## Steps（一次 tick）

1. **收命令**：从 `receiver` 非阻塞收 `RaftMessage`，按类型 dispatch：
   - `Propose { data, chan }`：raft-rs 的 `propose` API。
   - `Raft { message, chan }`：`step()` 把 peer message 喂进 raft。
   - `ConfChange { change, chan }`：`propose_conf_change`。
   - `TransferLeader { node_id, chan }`：`transfer_leader`。
2. **没消息**：`tick()`，推进 raft 内部时钟（election timeout / heartbeat）。
3. **同步内存视图**：把 `RawNode::raft.state` 写回 `placement_cluster.raft_role`。
4. **`on_ready()`**：raft-rs ready loop。顺序敏感：
   1. 发送出站消息（`ready.messages()` → `send_peer_message`）。
   2. 持久化新日志（`storage.append_entries`）。
   3. 持久化 `hard_state`、snapshot。
   4. **`apply` committed entries**：调 `DataRoute::route` 落到 RocksDB；apply 完通过
      `chan` 回 ack。
   5. `advance(ready)`：通知 raft-rs 这一轮 ready 已处理。

## Snapshot 触发

每 1000 个已提交 entry 触发一次 `create_snapshot`，把当前状态机 snapshot 写到 RocksDB。

## Edge cases

- channel 收到的 propose 在 follower 上：raft-rs 自动 forward 给 leader 或 reject。
- 业务侧 30s 等不到 ack：`RaftLogCommitTimeout`，调用方决定重试。
- 主循环 panic：进程崩溃，无自恢复——上层守护进程负责重启。

## 当前状态

`raft.run()` 在 `lib.rs::start_server` 里**被注释掉了**，所以这条路径目前不消费
channel。`RaftMachineApply::apply_propose_message` 在自研路径下会永远 30s 超时。
