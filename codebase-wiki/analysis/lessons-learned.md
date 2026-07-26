# Lessons Learned

读完 placement-center 的全部 5 个 phase，下面是给"未来维护者 / 类似项目作者"的
经验提炼。每条经验都有源码证据支撑，不是泛泛之谈。

## 1. 共识库不是越多越好——挑一个

**证据**：[dual-impl-cost](../atoms/dual-impl-cost.md)。raft-rs 和 openraft 在
本仓库并存，但 `lib.rs` 注释掉了 `raft.run()`，意味着自研路径**根本没在跑**。
然而 `services_kv.rs` / `services_raft.rs` / `RaftMachine` / `DataRoute` 等
全套实现仍在编译产物里——纯粹的死重量。

**经验**：
- 在引入第二个共识库前，先问"为什么第一个不够用"。如果只是想对照学习，做成
  examples/ 下的孤岛，不要让两条路径的依赖污染主 binary。
- 一旦决定二选一，**立刻**删除被淘汰的一条所有 surface（types、service handler、
  storage 适配器、protobuf 定义），不要留 dead path。
- raft 库的选择是"地基级"决策——`Storage` trait、log 编码、网络层全都要为它定制。

## 2. write/read 路径必须经过同一份存储

**证据**：`services_kv_new.rs::set` 写 openraft 内存 BTreeMap；`get` 读 RocksDB
`KvStorage`。两份数据**从来没对齐过**——这意味着 demo 的 set/get 测试如果还
"看起来通过"，要么是因为 set 失败、要么是因为 get 直接返回 None 被算作"测试不
关心 value"。

**经验**：
- 写一个新 service 的 第一件事：画出"业务请求 → 写哪里 → 读哪里"，确保是同一份
  存储。
- 内存状态机要么自己实现 read API（直接读 BTreeMap），要么 commit 后双写到
  RocksDB——但绝不能"写 A 读 B"。
- 类似的 [demo-hardcoding](../atoms/demo-hardcoding.md) 问题往往**和 write/read
  分裂同时出现**——硬编码 key/value 让 bug 永远 silent。

## 3. 序列化分层要有显式 contract

**证据**：[data-route](../atoms/data-route.md)。外层 bincode + 内层 prost，
`DataRoute::route` 错把外层 bytes 喂给 prost decoder——只是因为 prost wire format
能"容忍"未知字段才没有 panic。这是一种隐式契约：作者假设 `bincode(StorageData)`
的 bytes 跨过 header 后正好就是 `prost(SetRequest)` 的 bytes，但**这个假设没有
任何文档或测试保护**。

**经验**：
- 跨层序列化（外层 envelope + 内层 payload）一定要：
  1. 在 type 层面就分开：`StorageData::value: Vec<u8>` 已经分开了，但 caller 用
     错变量没有编译期信号。
  2. 在测试里加 round-trip：`encode → decode` 必须 byte-for-byte 一致。
  3. 在文档里写明"外层用 X，内层用 Y"——而不是靠"凑巧能解码"。
- 用 prost 不一定意味着 wire format 总是兼容；**未知 tag 被丢弃**这件事不是协议
  保证，是性能优化。

## 4. RocksDB key 编码 = 数据排序契约

**证据**：[big-endian-log-key](../atoms/big-endian-log-key.md)。openraft `LogStore`
把 log_index 编码成 big-endian u64 才能让 RocksDB 字典序匹配数值序。如果误用
`to_string()` 或 little-endian，`range_scan(10..200)` 会扫到错误的 entry。

**经验**：
- 任何把数值当 key 的 LSM-store，第一反应应当是 big-endian 定长编码。
- 元数据 key 和数据 key 应当用**前缀 namespace** 隔开（如 `b"meta/" + ...`），
  不要靠"长度不会冲突"的隐式假设。
- 这条规则同样适用于 timestamp、sequence number、log offset。

## 5. `unwrap` 在 RPC handler 里 = 集群级 DoS

**证据**：`services_openraft.rs` 的 vote / append / snapshot handler 全都用
`bincode::deserialize(&req.value).unwrap()`——一个恶意/损坏的 peer 发来一个坏
bytes 就能让本节点 panic。本节点 panic 后，多数派可能丢失，集群停摆。

**经验**：
- gRPC handler 和 raft network 入口**不要 unwrap**。`?` 转 `Status::invalid_argument`
  即可。
- `unwrap_or_else(|e| panic!(...))` 同样危险——任何 unwrap 都要先问"输入可控吗"。
- 节点间 RPC 比客户端 RPC 更敏感：客户端坏数据只影响一次请求；peer 坏数据可能
  来自被攻陷的节点，影响整个集群。

## 6. 全局 `OnceLock` 配置很方便，测试很痛

**证据**：[placement-center-config](../atoms/placement-center-config.md)。
`PLACEMENT_CENTER_CONF` 是 `static OnceLock`——`init_placement_center_conf_by_path`
只能在进程启动期写一次，任何模块都能 `placement_center_conf()` 拿到 `&'static`。

**经验**：
- 这种模式让"业务代码不用层层传 config"，但也让单元测试很难做：
  - 多个测试不能用不同 config（`OnceLock` 不能重置）。
  - 测试之间会通过这个全局变量隐式共享状态。
- 折中方案：业务代码接受 `&PlacementCenterConfig` 而不是调用全局 getter，
  顶层装配点（`start_server`）从全局拿一次再传下去。

## 7. demo 代码和生产代码的边界要写在 README 里

**证据**：[demo-hardcoding](../atoms/demo-hardcoding.md)。HTTP `/v1/openraft/set`、
`/add_learner`、`/change_membership` 全部硬编码字面量。`cmd::main` 不调用
`start_server` 而是直接 `(stop_send).await`——意味着 `cargo run --bin
placement-center` 可能跑不起来一个完整服务。

**经验**：
- 教学/演示代码 vs 生产代码必须显式标记。可选做法：
  - cfg feature flag：`#[cfg(feature = "demo")]` 包住所有硬编码。
  - 文件名前缀：`demo_*.rs`。
  - 顶层 README 写明"这个仓库不是 production-ready，以下文件仅作演示"。
- 不要让 reader 读到一半才意识到"哦这是个 demo"——这种延迟认知会让所有 atom 都
  被误读。

## 8. 进程入口一定要能直接 `cargo run`

**证据**：`src/cmd/src/placement-center/server.rs::main` 调 `init_placement_center_conf_by_path`
和 `init_placement_center_log` 后，直接 `(stop_send).await`——没调 `start_server`。
如果 reader 从 `cmd` crate 入手追代码，会得出"这个 binary 啥都不做"的结论；
真正的 server 在 `placement-center` crate 的 `lib.rs::start_server` 里。

**经验**：
- main 函数应当**直接** call 完整 boot 流程，不要让"binary entrypoint 和 library
  entrypoint 断链"。
- 哪怕 demo，也要保证 `cargo run -- --conf config/placement-center.toml` 能跑出
  可观察的服务。
- 否则集成测试和文档示例都会失效。

## 9. 双层架构（HTTP + gRPC）共享后端要有访问控制

**证据**：HTTP 和 gRPC 共享 `Raft<TypeConfig>` 和 `RaftMachineApply`——任何 HTTP
handler 都能直接 propose。`server/http/openraft.rs::set` 直接调 `client_write`，
连 service 层都不过。

**经验**：
- HTTP 调试面板 = 公开 attack surface，必须默认只读 + 鉴权。
- gRPC service 是业务入口，HTTP handler 不应该重新实现写路径——直接复用 service
  handler 才能让 auth / rate limit / validation 走同一条路。
- 这条同样适用于"管理 API + 业务 API"双 endpoint 的任何系统。

## 10. 反向工程的方法论也是一种沉淀

最后一条不是关于代码的，是关于**怎么读代码**：

- **从行为出发，不从文件出发**：先问"这个进程启动后做什么"，再去找入口；
  比从 main.rs 一行一行往下读高效十倍。
- **三层抽象提取**：每个 atom 都要有 runtime fact + abstraction + tradeoff。
  只有 runtime fact 的 atom（"这个函数做 X"）等价于注释，没有沉淀价值。
- **bug 和 design choice 要分开**：`DataRoute::route` 是 bug；`dual raft path`
  是 design choice。前者要修，后者要文档化。混淆这两类会让 wiki 充满"这里
  错了应该改成 ..."的噪声。
- **顺源码看不到的东西要单独捕获**：`raft.run()` 被注释意味着"自研路径不在
  runtime 范围内"——这个事实在 source view 里看不到，必须在 atom 里写明。

## Sources

- [01 repo map](01-repo-map.md)
- [02 runtime](02-runtime.md)
- [03 core design](03-core-design.md)
- [04 architecture](04-architecture.md)
- [05 tradeoffs](05-tradeoffs.md)
- 所有 [atoms/](../atoms/)
