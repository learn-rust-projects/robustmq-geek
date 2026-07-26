---
type: tradeoff
tags: [raft, replication, complexity, dual-impl]
backlinks:
  - ../analysis/05-tradeoffs.md
refs:
  - src/placement-center/src/raft/
  - src/placement-center/src/openraft/
  - src/placement-center/src/lib.rs
---

# Tradeoff: 两套 raft 实现并存

## Choice

placement-center 同时维护：

- 自研 raft 路径（基于 `raft-rs`）：`RaftMachine` ready loop + `DataRoute` + `KvStorage`。
- openraft 路径（基于 `openraft`）：`Raft<TypeConfig>` + `LogStore` + `StateMachineStore`。

当前默认 runtime（`lib.rs::start_server`）只启用 openraft；自研路径的 `raft.run()` 被
注释掉，但所有 wiring（gRPC service、storage、PeersManager）依然在编译产物里。

## Benefits

- 教学价值：两条路径并列展示"声明式 raft 框架（openraft）"和"事件循环式 raft
  库（raft-rs）"两种风格的差异。
- 可比性：同一 RocksDB 实例下，相同业务命令在两条路径上的 apply 行为可以直接对照。
- 演化保险：如果 openraft 出现阻断性问题，可以快速切回自研路径而不重写网络/存储层。

## Costs

- **加新业务命令必须改两处**：详见 [架构边界风险]——`StorageDataType::*` 和
  `AppRequestData::*` 必须同步演化，否则只在一条路径上生效。
- 抽象重复：两条路径各有自己的 `apply` / `route` / `Storage` 适配器，3 个相似但不
  互通的状态机模型。
- 共享状态歧义：`RaftGroupMetadata`（自研）和 openraft 自己的成员视图都试图描述
  cluster membership——并行启用时谁是真相？没有显式约定。
- 二进制体积：两条路径的依赖（`raft-rs` + `openraft` + 相关 protobuf stub）都进了
  最终产物。

## Affected qualities

- complexity（高）：阅读门槛、增量改动成本随两条路径线性 ×2。
- correctness：单条路径 bug 影响 1 倍，两条路径不对齐 bug（如 `RaftGroupMetadata`
  写入冲突）影响×N，且非常难复现。
- maintenance：未来要二选一时，需要先把"被淘汰的那条"的所有调用方迁移完。

## Alternatives

- 课程走完后只留一条——参考标准做法保留 openraft，删除 `raft/` 子模块。
- 把自研路径降级为"教学示例"，搬到 `examples/` 目录、不参与默认编译。

## Evidence

- `src/placement-center/src/lib.rs`：`raft.run()` 被注释——证明两条路径不并发运行。
- `src/placement-center/src/server/grpc/services_kv.rs` vs `services_kv_new.rs`：
  两份近似的 KV service handler，只差 propose 入口。
- `src/placement-center/src/raft/route.rs` vs `src/placement-center/src/openraft/store/state_machine_store.rs`：
  两份 apply 分发逻辑，各自维护命令枚举。

## Why this matters

这是 placement-center 整个架构上**最大**的偶然复杂度来源。所有 [03-core-design]
中"加新功能要改两处"的描述都来自这条 tradeoff。如果项目目标是"做一个能用的
placement-center"，应当尽快二选一；如果目标是"做一个对照演示"，则需要把这点写在
README 顶部，避免被新读者误以为是生产形态。
