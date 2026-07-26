# 04 — Architecture

## Layer 模型

placement-center 是一个**分层进程**：每一层只依赖下层，不允许反向调用。
两条 raft 路径在共识层并列，但都共享同一个持久化层和网络层。

```
┌──────────────────────────────────────────────────────────────────────┐
│  Edge / Transport         axum HTTP server   |  tonic gRPC server    │
│  (server/{http,grpc})     /v1/...            |  KV / Placement / OpenRaft │
├──────────────────────────────────────────────────────────────────────┤
│  Service handler          GrpcKvServices  GrpcKvServices(new)        │
│  (server/grpc/services_*) GrpcRaftServices  GrpcOpenRaftServices     │
├──────────────────────────────────────────────────────────────────────┤
│  Consensus / state-machine                                            │
│  (raft/, openraft/)                                                   │
│   ┌─────────────────────────┬────────────────────────────────────┐    │
│   │ raft-rs path            │ openraft path                      │    │
│   │ RaftMachine + Apply     │ Raft<TypeConfig>                   │    │
│   │ DataRoute + KvStorage   │ StateMachineStore (BTreeMap)       │    │
│   └─────────────────────────┴────────────────────────────────────┘    │
├──────────────────────────────────────────────────────────────────────┤
│  Persistence              RocksDBEngine (单例)                        │
│  (storage/)               cluster CF (raft-rs) | _raft_logs / _raft_store (openraft) │
├──────────────────────────────────────────────────────────────────────┤
│  Networking out           ClientPool (mobc) → tonic clients          │
│  (clients/)               KvServiceManager  OpenRaftServiceManager   │
├──────────────────────────────────────────────────────────────────────┤
│  Cross-cutting            common-base (config, error, logging)       │
│                           protocol (prost generated stubs)           │
└──────────────────────────────────────────────────────────────────────┘
```

完整图见 [architecture-diagram.md](architecture-diagram.md)。

## Boundary map

| 边界 | 类型 | 协议 | 同步策略 |
|------|------|------|----------|
| Client ↔ placement-center | 网络（process） | gRPC tonic | 同步阻塞调用（async/await） |
| 客户端 ↔ HTTP 调试面板 | 网络（process） | HTTP/JSON axum | 同步 |
| Placement-center ↔ Placement-center（自研 raft） | 网络（cluster） | gRPC（`PlacementCenterService`） | mobc 连接池 + retry |
| Placement-center ↔ Placement-center（openraft） | 网络（cluster） | gRPC（`OpenRaftService`） | mobc 连接池 |
| Service handler ↔ Consensus | in-process | mpsc + oneshot（自研） / 直接 await（openraft） | 异步 |
| Consensus ↔ Persistence | in-process | trait 调用 | 同步阻塞（RocksDB IO） |

## Ownership matrix

| 资源 / 状态 | 拥有者 | 修改方 | 强制点 |
|-------------|--------|--------|--------|
| `PlacementCenterConfig` | OnceLock 全局 | 只在 `init_*_by_path` 写入 | 编译期：`&'static` 引用 |
| RocksDB DB instance | `RocksDBEngine` Arc | 任何持有 Arc 的子模块 | RocksDB 内部 |
| 自研 raft 状态机（KV） | `KvStorage` over `RocksDBEngine` | 只能由 `DataRoute::route`（apply 路径） | 业务约定，无编译期保证 |
| openraft 状态机（kvs BTreeMap） | `StateMachineStore` Arc | 只能由 openraft `apply` | trait 调用约定 |
| openraft 日志 (`_raft_logs`) | `LogStore` | 只能由 openraft 框架 | trait |
| 自研 raft 日志 | `RaftMachineStorage` | 只能由 `RaftMachine::on_ready` | 业务约定 |
| `RaftGroupMetadata` | `Arc<RwLock>` | `RaftMachine::run` 同步 raft 角色；`services_kv.rs` 只读 | RwLock |
| `kvs: BTreeMap<String,String>` | openraft state machine | apply 写；HTTP/gRPC 读 | RwLock |
| ClientPool 内部 DashMap | `ClientPool` Arc | 各 service 子模块按需插入 | DashMap |

## Cross-cutting concerns

| 关注点 | 实现 | 位置 |
|--------|------|------|
| 错误模型 | `RobustMQError` enum + `thiserror` 自动 from | `common-base/errors.rs` |
| HTTP 公共响应 | `success_response<T>` / `error_response` | `common-base/http_response.rs` |
| 日志 | `log4rs` + 三 appender（stdout / server.log / raft.log） | `common-base/log/`, `config/log4rs.yaml` |
| 配置 | OnceLock 单例，TOML 解析 | `common-base/config/` |
| 协议 | prost-build 生成 4 个 stub | `protocol/` |
| 序列化 | `serde_json` (业务) + `bincode` (raft 内部) + `prost` (gRPC) | 各处 |
| 关停 | `tokio::sync::broadcast<bool>` + `select!` | `lib.rs::start_server` |

## Deployment / runtime topology

- **单进程**：placement-center 是一个二进制；多副本通过 N 个独立进程组成 raft 集群。
- **进程内并发**：tokio 多线程 runtime；3 个长 task：HTTP server / gRPC server / openraft init。
- **文件系统**：每个进程一个 `data_path`，下含两个 RocksDB 子目录：`/_engine_storage`（openraft）和默认 path（自研 raft）。
- **网络拓扑**：3 节点 demo 在 `127.0.0.1` 上分配不同端口（1228/1238/1248）。
  生产部署应该在不同 host，每节点 `node_id` 唯一。

## Boundary risks / 已识别违反

1. **写读不一致**：`services_kv_new.rs::set` 写 openraft state machine（内存
   BTreeMap），`get` 读 RocksDB `KvStorage`。属于"层间状态拆得太开"——同一业务
   写读应当走同一存储。
2. **HTTP 调试面板写状态**：`server/http/openraft.rs::set` 直接调
   `raft_node.client_write`，绕过 service handler 层；意味着改 service 层的校验/
   路由逻辑（比如增加 rate limit）不会作用于 HTTP 路径。课程版接受这个不对称。
3. **`DataRoute::route` 二次解码 bug**：详见 [DataRoute](../atoms/data-route.md)。
   层间约定（外层 bincode + 内层 prost）没有显式 contract 文档化，依靠"凑巧能解码"。
4. **共享 `RaftGroupMetadata`**：自研 raft 写入，openraft 不读；如果将来同时启用，
   两条路径都试图写就会冲突。
5. **`cmd::main` 不调 `start_server`**：进程入口和库入口断链；只看 cmd crate 看不出
   服务怎么起来的。

## Design boundary 对架构的约束

- **加新业务命令**：因为两条路径并存，必须在 `DataRoute::route` 和
  `StateMachineStore::apply` 都加分支，否则只在一条路径上生效。这种"加一个功能改两处"
  的代价随业务命令数量线性增长——如果不打算两条都长期保留，应尽快删一条。
- **替换 RocksDB**：因为 `RocksDBEngine` 暴露的是 `ColumnFamily` + 通用 API（不是抽象
  trait），上层 `KvStorage` / `LogStore` / `RaftMachineStorage` 都直接耦合 rocksdb crate
  类型。换存储要改这三个文件。
- **HTTP/gRPC server 共享同一份 raft handle**：HTTP 任意 handler 都能直接 propose，
  没有"管理 vs 业务"的隔离。生产应当把 HTTP 限制为只读 + 健康检查。
