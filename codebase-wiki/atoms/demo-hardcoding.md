---
type: tradeoff
tags: [http, demo, security, hardcoded]
backlinks:
  - ../analysis/05-tradeoffs.md
refs:
  - src/placement-center/src/server/http/openraft.rs
  - src/placement-center/src/server/grpc/services_kv_new.rs
---

# Tradeoff: 课程演示态硬编码 vs 生产可用

## Choice

placement-center 当前版本对外暴露的**写**入口（HTTP `/v1/openraft/set`、gRPC
`KvService::set` 的 openraft 实现）都把请求参数硬编码或绕过校验：

- `server/http/openraft.rs::set` 把 key/value 写死成 `"k1"` / `"v1"`，并且直接调
  `raft_node.client_write`（不走 service handler）。
- `server/grpc/services_kv_new.rs::set` 也把 key/value 写死。
- HTTP `add_learner` / `change_membership` 把 node_id=3 写死。

## Benefits

- 课程演示成本极低：跑起来就能在 3 节点上看到 raft replication，不用准备测试客户端。
- 阅读路径短：reader 不用追完 service 层就能看到 `client_write` 在哪触发 apply。

## Costs

- **任何模仿这个项目改造的人都需要先反硬编码**——现实中这是新接手开发者最容易
  踩的 trap。
- HTTP 路径完全绕过 service 层校验/限流——即使在 service 层加 auth，HTTP 仍然能
  直接 propose。
- 写入仅作为 demo 验证，**业务逻辑不正确**（写"k1"，读用户传的 key，永远 miss）。

## Affected qualities

- correctness：如果有人误以为可以直接用，所有写入都会变成往同一个 key 上覆盖。
- security：HTTP 调试面板有 propose 权限，无任何 auth。
- maintainability：service 层和 HTTP 层校验逻辑不对称，未来加任何"propose 前
  hook"都要在两处加。

## Alternatives

- 把 HTTP 限制为只读 + 健康检查；写入只走 gRPC service。
- 让 `services_kv_new.rs` 真正使用 `req.key` / `req.value`（一行 fix）。
- 给 `change_membership` 接受路径参数 `:node_id` 而不是硬编码 3。

## Evidence

- `src/placement-center/src/server/http/openraft.rs`：见所有 handler 中的字面常量。
- `src/placement-center/src/server/grpc/services_kv_new.rs`：`set` / `delete`
  实现忽略 `req` 字段，使用字面 `"k1"`。

## Why this matters

这条 tradeoff 是 placement-center "demo first / production maybe later" 取向的
**显式标记**。读者必须先认识这一点，再读上面所有 atom——否则会误以为 propose
路径有"参数透传契约"，从而错失修复点。
