---
type: invariant
tags: [raft, leader, write, forwarding]
backlinks:
  - ../analysis/03-core-design.md
  - ../analysis/02-runtime.md
refs:
  - src/placement-center/src/server/grpc/services_kv.rs
  - src/placement-center/src/server/grpc/services_kv_new.rs
---

# Leader-Only Write Invariant

## Rule

所有改变 raft 状态机的写入（KV set/delete、conf change）只能由 leader 发起 propose；
follower 收到写请求必须**转发**或拒绝，不允许自行 propose。

## Why

raft 的安全性依赖于"只有 leader 能 propose"：每条 entry 都打 leader 的 term，
follower 拒绝低 term 的 propose，从而保证 log 单调一致。

## Enforcement sites

### 自研 raft 路径

`services_kv.rs::set` / `delete`：
```rust
if !self.is_leader() {
    let leader_addr = self.leader_addr();
    return placement_set(self.client_poll.clone(), vec![leader_addr], req).await;
}
// 否则才走 RaftMachineApply::apply_propose_message
```

显式判断 + 显式转发。

### openraft 路径

`services_kv_new.rs::set` / `delete`：直接调 `raft_node.client_write`。
openraft **内部**实现转发：如果本节点不是 leader，client_write 通过
`Network::ForwardToLeader` 内部 RPC 转发；业务侧不需要显式判断。

两种风格各有取舍：
- 自研路径"显式"：业务能精准控制转发逻辑，也能在 leader 检测和转发之间做缓存/限流。
- openraft 路径"声明式"：业务零样板，但 leader 信息和转发延迟都被框架接管。

## Violation consequences

- 自研路径：如果业务跳过 `is_leader` 检查直接 propose，raft-rs 在 follower 上会
  reject，业务侧返回 `RaftLogCommitTimeout`。
- openraft 路径：业务**无法**绕过 client_write 直接 propose；invariant 由框架保证。

## 边界情况

- Leader 切换瞬间：旧 leader 已经 step down 但 metadata 尚未更新，业务转发到旧
  leader → 旧 leader 自己再转发。多一跳但仍正确。
- 没有 leader（election timeout 中）：openraft `client_write` 阻塞或返回 Err；
  自研路径里 `leader_addr()` 可能返回空字符串，转发失败。
