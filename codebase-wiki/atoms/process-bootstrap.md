---
type: object
tags: [runtime, entrypoint, startup]
backlinks:
  - ../analysis/02-runtime.md
  - ../analysis/startup-flow.md
refs:
  - src/cmd/src/placement-center/server.rs
  - src/placement-center/src/lib.rs
---

# Process Bootstrap

## Definition

placement-center 二进制启动到"可对外服务"的全过程。入口在 `cmd::main`，
组装在 `placement_center::start_server`，最终阻塞在 ctrl+c。

## Evidence

- `src/cmd/src/placement-center/server.rs:36-47`：`main` 实现。
- `src/placement-center/src/lib.rs:44-103`：`start_server` 实现。

## Steps

1. **clap 解析**：`ArgsParams::parse()` 读取 `--conf` 路径，缺省 `config/placement-center.toml`。
2. **配置加载**：`init_placement_center_conf_by_path(&args.conf)` 通过 `OnceLock`
   把 toml 反序列化为 `PlacementCenterConfig` 单例；任何错误 panic。
3. **日志初始化**：`init_placement_center_log()` 装载 `config/log4rs.yaml`。
4. **`start_server(stop_sx)`** 内部：
   - 创建两条 mpsc channel：`raft_message`（自研 raft 主循环用）、`peer_message`（PeersManager 用，当前未启用）。
   - 创建共享状态：`RaftGroupMetadata`（Arc<RwLock>）、`RaftMachineApply`、`RocksDBEngine`。
   - 构造自研 raft：`RaftMachineStorage` + `DataRoute` + `RaftMachine`。
   - `ClientPool::new(3)`：连接池上限 3。
   - **`create_raft_node(client_poll).await`**：组装 openraft `Raft<TypeConfig>` 实例；
     返回 raft handle + 内存 KV map（`Arc<RwLock<BTreeMap>>`）。
   - **3 个 `tokio::spawn`**：
     - `start_grpc_server`：tonic server 挂载 KV/raft/openraft 三类 service。
     - `start_openraft_node`：仅在 node_id 最小的节点上调用 `Raft::initialize`。
     - `start_http_server`：axum router + openraft 调试路由。
   - `// raft.run().await;` —— 自研 raft 主循环**已被注释掉**。
5. **`awaiting_stop`**：`tokio::signal::ctrl_c().await`，捕获后通过 broadcast 发送
   `true`，所有子任务通过 `select!` 接收停机信号优雅退出。

## Invariants

- 配置必须在 `start_server` 之前初始化，否则 `placement_center_conf()` panic。
- broadcast `stop_sx` 必须在所有子任务 spawn 之前创建，否则 subscribe 漏信号。

## 已知缺陷

- `cmd::main` 末尾 `(stop_send).await;` 直接 await `broadcast::Sender`，并不会执行
  `start_server`——这是课程版的占位写法，需要学员自行修正。如果直接跑 `main`，
  服务实际上不会起来；要跑起来必须自己改 main 调 `start_server(stop_send).await`。
