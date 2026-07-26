# 05 — Tradeoffs

placement-center 不是一个"通用最优"的设计。每条架构决策都在三个轴上取舍：
**simplicity / scalability / correctness**。本节把所有 tradeoff 显式列出，
让 reader 看清"为什么这里这么写"。

## Tradeoff table

| Choice | Benefits | Costs | Affected qualities | Atom |
|--------|----------|-------|---------------------|------|
| 两条 raft 实现并存 | 教学对照、演化保险 | 加新命令改两处、状态机歧义、维护成本×2 | complexity ↑↑、correctness ↓ | [dual-impl-cost](../atoms/dual-impl-cost.md) |
| openraft state machine 在内存（BTreeMap） | apply 快、tail latency 低 | crash 后 replay snapshot+log；snapshot 序列化整个 map | latency ↓、recovery time ↑ | [dual-state-machine-tradeoff](../atoms/dual-state-machine-tradeoff.md) |
| 自研 raft state machine 同步落 RocksDB | crash 即恢复；无 replay | 每条 apply 阻塞 ready loop；写放大随 compaction | recovery time ↓、apply latency ↑ | [dual-state-machine-tradeoff](../atoms/dual-state-machine-tradeoff.md) |
| RocksDB 单例 + CF 隔离 | 资源少、配置简单 | compaction 互扰、配置一刀切、故障 blast radius 大 | latency 抖动、operability ↓ | [rocksdb-single-instance-tradeoff](../atoms/rocksdb-single-instance-tradeoff.md) |
| 课程演示态硬编码（HTTP/`services_kv_new`） | 演示门槛低 | 业务正确性失真、HTTP 绕过 service 层校验 | correctness ↓↓、security ↓ | [demo-hardcoding](../atoms/demo-hardcoding.md) |
| openraft log key 用 big-endian u64 | 字典序 == 数值序，range_scan 直接用 | 没有 namespace prefix，元数据 key 与 log key 共享 keyspace | correctness（脆弱不变量） | [big-endian-log-key](../atoms/big-endian-log-key.md) |
| `KvServiceManager` 用 mobc 连接池 | 连接复用、控并发 | 每个 (service, addr) 一个池，addr 列表大时池数线性涨；retry 仅 service 层 | resource 利用率 ↑、tail latency 部分受 mobc 调度 | [client-pool](../atoms/client-pool.md) |
| `RocksDBEngine::exist` 用 `key_may_exist_cf` | bloom filter，O(1) 不读 SST | **可能假阳性** | latency ↓、correctness（HTTP `/exists` 容忍假阳性） | [rocksdb-engine](../atoms/rocksdb-engine.md) |
| `services_openraft.rs` 直接 `bincode::deserialize(...).unwrap()` | 代码短 | 任何坏字节直接 panic 整个 server | correctness、availability | — |
| `cmd::main` 不调 `start_server` | 当前是占位/演示 | 二进制实际跑不起完整 server，只能靠测试或手工调用 | usability | — |

## Scalability analysis

placement-center 当前是**3 节点演示规模**的设计，没有水平扩展机制：

- **写吞吐上限 = leader 单进程 RocksDB 写 + 多数派复制 RTT**。一旦 leader CPU 或
  disk 饱和，整个集群就到顶。
- **读吞吐**：openraft 路径 follower 也能读（直接读 BTreeMap），但和 leader 写
  存在不一致窗口；自研路径 follower 读 RocksDB，同样会 stale。没有 linearizable
  read 实现。
- **状态机大小**：openraft `StateMachineStore` 把 `BTreeMap` 全部装内存——单节点
  RAM 决定 KV 上限。snapshot 时序列化整个 map（`serde_json`），map 大了之后
  snapshot 周期会变成阻塞窗口。
- **集群规模**：`calc_init_node` 假设 nodes 配置静态；动态加节点要走 openraft 的
  `add_learner` + `change_membership`，HTTP handler 当前硬编码 node_id=3。

## Consistency analysis

- **写**：通过 raft 多数派达成 strong consistency。
- **读**：当前实现都是 stale read：
  - 自研路径 `services_kv.rs::get` 直接读 RocksDB——任何 follower 都返回它本地
    apply 到的版本。
  - openraft 路径 `services_kv_new.rs::get` 读 RocksDB `KvStorage`——但写走的是
    openraft 内存 BTreeMap，**两份数据从来不对齐**。这不是 stale read，是 **wrong
    read**。需要修。
- **跨 CF**：写 raft log 和写 state machine 不在同一个 RocksDB write batch 里，
  所以"log 已落但 state machine 没 apply"的窗口存在；通过 raft applied_index
  recovery 修复。
- **`RaftGroupMetadata` vs openraft membership view**：两个 source of truth，没
  有同步机制。当前自研路径不跑所以无冲突；同时启用就会出错。

## Latency analysis

- **写延迟主导项**：raft 多数派 RTT + leader RocksDB WAL fsync。
  - 单机 demo 全 127.0.0.1，RTT < 1ms，主要是 fsync 成本。
  - 跨机部署 RTT 决定 P50；fsync 决定 tail。
- **读延迟**：直接 RocksDB bloom filter + memtable，O(0.1ms) 量级。
- **client 端 retry**：`retry_call` 失败 sleep `times*2` 秒，最多 3 次——总等待
  上限 12s。任何 leader 切换期间客户端会感知到这段抖动。
- **HTTP/gRPC 同进程不互相阻塞**：tokio 多线程 runtime + 三个独立 task，但都共
  享 RocksDB——任何一条慢路径会拖慢其他路径。

## Complexity analysis

按"读懂这份代码所需的概念数"排序，复杂度集中在：

1. **两条 raft 路径的并列**——必须先理解这点，再读 service 层，否则会反复混淆
   `services_kv.rs` 和 `services_kv_new.rs`。
2. **bincode + prost 双层编码**——`StorageData::value` 是 prost bytes，外层是
   bincode bytes。`DataRoute::route` 的 demo bug 就来自混淆这两层。
3. **openraft 的 trait 装配**——`TypeConfig` / `RaftLogStorage` / `RaftStateMachine`
   / `RaftNetworkFactory` 四件套必须一起读才知道 `Raft<TypeConfig>` 是怎么拼起来的。
4. **`OnceLock` 全局配置**——`placement_center_conf()` 在任何模块里都能拿到 Arc，
   测试隔离困难。

## Future change risks

| 改动场景 | 阻塞点 | 缓解 |
|----------|--------|------|
| 加新业务命令（如 ClusterRegister） | 必须改 `StorageDataType` + `AppRequestData` + `DataRoute::route` + `StateMachineStore::apply`，4 处 | 决定二选一后只改一边 |
| 替换 RocksDB（换 sled / fjall） | `RocksDBEngine` 暴露的是 rocksdb crate 的 ColumnFamily，不是抽象 trait | 先抽象 `Engine` trait，再换 |
| 加 auth / rate limit | HTTP 直接 propose 绕过 service 层 | HTTP 改只读 + 健康检查 |
| 状态机变大（>1GB） | snapshot serde_json 全量 dump 会阻塞 | 改增量 snapshot 或 RocksDB-backed state machine |
| 启用自研 raft（取消注释 `raft.run()`） | `RaftGroupMetadata` 会被两条路径同时写 | 删除 openraft 或重新设计共享 metadata |

## 结论

placement-center 是一个**"清晰展示 raft 概念"的教学产物**，不是 production
candidate。它的价值在于"代码量小到可读完，但又涵盖了 raft 工程化中的全部要素
（log、snapshot、state machine、networking、client pool、HTTP/gRPC）"。

如果要走向生产，最大的三件事按优先级：

1. 二选一：删掉自研 raft 或删掉 openraft，把所有 service 收敛到一条路径。
2. 修写读不一致：openraft 路径的读必须读 BTreeMap，不能读 RocksDB。
3. HTTP 调试面板降级为只读，业务写入只走 gRPC。

这三件事做完后，再考虑 scalability（snapshot 增量化、双 DB 拆分、follower 线性
读）等"高级问题"。
