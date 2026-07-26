---
type: object
tags: [config, startup, global-state]
backlinks:
  - ../analysis/01-repo-map.md
  - ../analysis/02-runtime.md
refs:
  - src/common/base/src/config/placement_center.rs
  - config/placement-center.toml
  - config/cluster/placement-center-1.toml
---

# PlacementCenterConfig

## Definition

placement-center 的全部静态配置；进程内单例，启动期由 toml 文件加载，
通过 `OnceLock` 保证只装载一次，运行期任意位置以 `&'static` 访问。

## Evidence

- `src/common/base/src/config/placement_center.rs:57-69`：结构体定义。
- `src/common/base/src/config/placement_center.rs:86-118`：`OnceLock` + 单例访问。
- `config/placement-center.toml`：单节点示例。
- `config/cluster/placement-center-{1,2,3}.toml`：3 节点集群示例。

## 字段

| 字段 | 含义 |
|------|------|
| `cluster_name` | 集群标识，用于隔离不同 placement 集群 |
| `addr` | 本节点对外地址 |
| `node_id` | raft 集群中的唯一 id（u64） |
| `grpc_port` | tonic gRPC 监听端口 |
| `http_port` | axum HTTP 监听端口 |
| `nodes: toml::Table` | 完整成员表 `node_id -> "host:raft_port"` |
| `data_path` | RocksDB 数据目录 |
| `log: Log` | log4rs 配置路径与日志输出目录 |

`node_id` 和 `grpc_port` 都有 `#[serde(default)]`：缺省时分别为 1 和 9982。

## Details

- **fail-fast**：任何 IO 错误、toml 语法错、字段缺失都直接 `panic!`——配置错属于
  启动期不可恢复故障，越早暴露越好。
- **不可变**：配置加载后不允许修改，避免 `Arc<Mutex<_>>` 的同步成本。
- **单元测试**：`tests::config_init_test` 直接读取仓库内置 toml，断言
  `node_id == 1 && grpc_port == 1228`，但实际仓库默认 `grpc_port = 8871`——
  测试值与 config 文件不一致，暗示两者更新不同步。
