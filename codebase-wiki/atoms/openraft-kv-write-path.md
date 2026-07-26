---
type: algorithm
tags: [openraft, kv, write-path, request-flow]
backlinks:
  - ../analysis/02-runtime.md
  - ../analysis/request-flow.md
refs:
  - src/placement-center/src/server/grpc/services_kv_new.rs
  - src/placement-center/src/openraft/store/state_machine_store.rs
  - src/placement-center/src/openraft/route/mod.rs
---

# OpenRaft KV Write Path

## Definition

业务侧通过 gRPC `KvService::set` 发起一次 KV 写入，最终被 raft 复制到多数派、
apply 到内存 BTreeMap，并返回响应的完整路径。openraft 路径下没有显式 leader 检测，
openraft 内部自动 forward。

## Inputs

- `SetRequest { key, value }`（protobuf）。

## Outputs

- 内存 KV map 中插入 `(key, value)`，返回 `CommonReply`。

## Steps

1. **gRPC 入口**：`GrpcKvServices::set`（`services_kv_new.rs`）。
2. **参数校验**：key/value 不能为空；空则返回 `Status::cancelled`。
3. **构造 openraft 命令**：`AppRequestData::Set { key, value }`。
   - 注意：当前实现里硬编码为 `key="k1", value="v1"`，**没用 req 的实际值**——demo bug。
4. **`raft_node.client_write(data).await`**：openraft 的 `client_write` API：
   - 如果本节点不是 leader，openraft 自动通过 `Network::ForwardToLeader` 转发。
   - 如果是 leader：把 `AppRequestData` 包成 raft Entry，propose 到 log。
5. **复制**：openraft 通过 `Network` 把 `AppendEntriesRequest` 发给 follower
   （`OpenRaftService::append` gRPC）。多数派 ack 后认为 committed。
6. **Apply**：openraft 调 `StateMachineStore::apply`：
   - `EntryPayload::Normal(AppRequestData::Set { key, value })` → 写入 `kvs: BTreeMap`。
   - 更新 `last_applied_log_id`。
7. **返回**：`client_write` future resolve，gRPC 回 `CommonReply::default()`。

## Read path（对照）

读不走 raft：`GrpcKvServices::get` 直接从 `RocksDBEngine` 读（`KvStorage`）。
但 openraft 的 state machine 数据其实在 `kvs: Arc<RwLock<BTreeMap>>` 里——
**这是个不一致**：写走 openraft state machine（内存），读走 RocksDB（自研 raft 的存储）。
课程版混用了两条路径的存储，运行时只跑 openraft 时读不到刚写的 key。

## Edge cases

- Follower 被发到 set 请求：openraft 透明转发，业务侧不需要关心。
- Leader 在 commit 之前挂掉：`client_write` 返回错误，`Status::cancelled`。
- Snapshot 安装期间：openraft 内部排队，client_write 可能短暂阻塞。
