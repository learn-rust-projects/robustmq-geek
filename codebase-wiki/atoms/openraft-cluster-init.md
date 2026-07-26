---
type: algorithm
tags: [openraft, init, leader-election, idempotency]
backlinks:
  - ../analysis/02-runtime.md
  - ../analysis/startup-flow.md
refs:
  - src/placement-center/src/openraft/raft_node.rs
---

# OpenRaft Cluster Init

## Definition

集群冷启动时由"指定的初始化节点"调一次 `Raft::initialize` 把所有 voter 写进
log。其他节点不调 initialize，它们通过正常的 raft 选举/复制加入。

## Inputs

- `nodes: BTreeMap<u64, Node>`：从 `placement_center_conf().nodes` 读出来的全集群成员表。
- 本节点 `node_id`。

## Outputs

- 集群第一条 log 包含全部 voter 的 membership entry。
- 之后选出 leader，开始接受 client_write。

## Steps

1. 把配置里的 `nodes` 表转成 `BTreeMap<NodeId, Node>`（`Node` 包含 `node_id` + `rpc_addr`）。
2. `calc_init_node(&nodes)`：取所有 node_id 中最小的。
3. 如果 `init_node_id == 本节点 node_id`：
   - `raft_node.is_initialized().await`：检查 log 里有没有 membership entry。
   - 如果没有，调 `raft_node.initialize(nodes.clone()).await`，把 nodes 全部写成
     第一条 membership entry。
   - 如果有，跳过。
4. 否则：什么都不做，等其他节点连过来。

## Why "smallest node_id"

冷启动时多个节点同时调 `initialize` 会导致：
- 它们各自写不同的 membership entry，产生 split brain。
- openraft 会 reject 后调用方（already initialized），但语义不优雅。

挑一个节点作为 unique initializer 是简单的去歧义办法。"最小 node_id" 是一个
全节点都能在不通信的情况下达成一致的选择函数（每个节点都有完整 `nodes` 配置）。

## Edge cases

- 节点重启：`is_initialized` 返回 true，跳过 initialize；正常加入。
- 唯一的 init node 永久挂掉：剩余节点都不会主动 initialize，集群无法 bootstrap。
  生产应该把 initializer 责任做成"任意活着的节点抢锁"，但课程版选择了简单方案。
- 配置里 `nodes` 表多节点不一致（比如节点 A 看到 {1,2}, 节点 B 看到 {2,3}）：
  initialize 时会写错 voters，后续选举失败。运维约束是 `nodes` 必须配置一致。

## Complexity

- O(N log N) 排序 node_ids（N = 节点数，通常 3-5）。
- 单次 RocksDB 写。
