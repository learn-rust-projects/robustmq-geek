---
type: object
tags: [grpc, client, pool, mobc]
backlinks:
  - ../analysis/01-repo-map.md
  - ../analysis/02-runtime.md
  - ../analysis/04-architecture.md
refs:
  - src/clients/src/poll.rs
  - src/clients/src/placement/mod.rs
  - src/clients/src/placement/kv/mod.rs
  - src/clients/src/placement/openraft/mod.rs
---

# ClientPool

## Definition

按 `(service, address)` 维度缓存 mobc gRPC 连接池。`placement-center` 在多个地方
（KV 转发、openraft 网络层）需要打到对端节点的 gRPC，使用 `ClientPool` 避免每次
请求重建 channel。

## Evidence

- `src/clients/src/poll.rs`：`ClientPool` 结构体 + `placement_center_*_service_pools` DashMap。
- `src/clients/src/placement/mod.rs:retry_call`：同时使用 KV pool 和 OpenRaft pool 的入口。

## 内部结构

```rust
pub struct ClientPool {
    max_open_connection: u64,
    placement_center_kv_service_pools: DashMap<String, Pool<KvServiceManager>>,
    placement_center_openraft_service_pools: DashMap<String, Pool<OpenRaftServiceManager>>,
}
```

- 一个 ClientPool 实例同时管理两类 service 的连接池。
- DashMap key 是地址字符串（如 `"127.0.0.1:1228"`），value 是 mobc `Pool<Manager>`。

## 行为

- `ClientPool::new(max_open_connection)`：构造，每个 sub-pool 大小上限相同。
- 真正"取连接"的逻辑在每个 service 子模块里（`placement_center_kv_services_client` 等），
  按地址查 DashMap，没有就 `Pool::builder().build(Manager::new(addr))` 后塞进去。

## retry_call 路由层

`retry_call(service, interface, pool, addrs, request)` 是统一的发送入口：
- 按 `service` 字段（`Kv` / `OpenRaft`）选择对应的 sub-pool。
- 按 `interface` 枚举（`Set/Get/Delete/Exists/Vote/Append/Snapshot`）做 method 分发。
- 内置 retry：`retry_times() = 3`，`retry_sleep_time(times) = times * 2` 秒。
- 多地址轮询：每次重试可换 `addrs` 里的另一个地址，模拟 leader follower 场景下
  "盲发到任意节点找 leader"。
