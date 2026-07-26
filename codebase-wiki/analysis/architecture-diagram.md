# Architecture Diagram

## 组件视图

```mermaid
graph TB
    subgraph Edge[Edge / Transport]
        HTTP[axum HTTP server]
        GRPC[tonic gRPC server]
    end

    subgraph Service[Service handler]
        KvSvc[GrpcKvServices<br/>self-built raft path]
        KvSvcN[GrpcKvServices new<br/>openraft path]
        RaftSvc[GrpcRaftServices<br/>raft peer RPC]
        ORaftSvc[GrpcOpenRaftServices<br/>openraft peer RPC]
        HttpHandler[index/openraft handlers]
    end

    subgraph Consensus[Consensus + state machine]
        subgraph SelfRaft[raft-rs path]
            RM[RaftMachine main loop]
            RMA[RaftMachineApply]
            DR[DataRoute]
            PM[PeersManager]
        end
        subgraph OR[openraft path]
            ORaft[Raft TypeConfig]
            SM[StateMachineStore]
            kvs[(kvs: BTreeMap)]
            LS[LogStore]
            Net[Network/Connection]
        end
    end

    subgraph Storage[Persistence]
        RDB[RocksDBEngine - shared]
        KVS[KvStorage]
        RaftStore[RaftMachineStorage]
    end

    subgraph Net2[Networking out]
        Pool[ClientPool mobc]
        KvCli[KvServiceManager]
        ORCli[OpenRaftServiceManager]
    end

    subgraph Crosscut[Cross-cutting]
        CB[common-base]
        Proto[protocol]
    end

    HTTP --> HttpHandler
    HttpHandler --> ORaft
    HttpHandler --> kvs

    GRPC --> KvSvc
    GRPC --> KvSvcN
    GRPC --> RaftSvc
    GRPC --> ORaftSvc

    KvSvc --> RMA
    KvSvc --> Pool
    KvSvc --> KVS
    KvSvcN --> ORaft
    KvSvcN --> KVS
    RaftSvc --> RMA
    ORaftSvc --> ORaft

    RMA --> RM
    RM --> DR
    RM --> PM
    DR --> KVS
    RM --> RaftStore
    PM --> Pool

    ORaft --> LS
    ORaft --> SM
    ORaft --> Net
    SM --> kvs
    LS --> RDB
    Net --> Pool

    KVS --> RDB
    RaftStore --> RDB

    Pool --> KvCli
    Pool --> ORCli
    KvCli --> Proto
    ORCli --> Proto

    KvSvc -.uses.-> CB
    ORaft -.uses.-> CB
```

## Layer 视图

```mermaid
graph TD
    L1[Edge: axum HTTP / tonic gRPC] --> L2
    L2[Service handlers] --> L3
    L3[Consensus + state machine] --> L4
    L3 --> L5
    L4[Persistence: RocksDB CFs]
    L5[Networking out: ClientPool]
    L1 -.cross-cut.-> CB1[common-base]
    L2 -.cross-cut.-> CB1
    L3 -.cross-cut.-> CB1
    L4 -.cross-cut.-> CB1
    L5 -.cross-cut.-> CB1
    L1 -.cross-cut.-> P1[protocol]
    L2 -.cross-cut.-> P1
    L5 -.cross-cut.-> P1
```

## 依赖方向

无循环依赖；上层只引用下层：

```
common-base / protocol  (无依赖)
        ↑
        clients
        ↑
        placement-center  (storage / raft / openraft / server)
        ↑
        cmd  (二进制入口)
```

## 部署拓扑（3 节点演示）

```mermaid
graph LR
    subgraph Host1[node 1]
        PC1[placement-center<br/>node_id=1<br/>grpc=1228 http=8971]
        DB1[(RocksDB<br/>/tmp/.../geek-local)]
        PC1 --- DB1
    end
    subgraph Host2[node 2]
        PC2[placement-center<br/>node_id=2<br/>grpc=1228 http=8972]
        DB2[(RocksDB<br/>/tmp/.../geek-2)]
        PC2 --- DB2
    end
    subgraph Host3[node 3]
        PC3[placement-center<br/>node_id=3<br/>grpc=1238 http=8973]
        DB3[(RocksDB<br/>/tmp/.../geek-3)]
        PC3 --- DB3
    end
    PC1 <-- raft RPC --> PC2
    PC2 <-- raft RPC --> PC3
    PC1 <-- raft RPC --> PC3
    Client1[KvServiceClient] -.gRPC.-> PC1
```

每节点：1 个进程、1 个 RocksDB 目录、2 类 gRPC service（业务 KV + raft peer）+
1 个 HTTP 调试面板。

## Sources

- [04 architecture](04-architecture.md)
- [workspace layout](../atoms/workspace-layout.md)
- [dual raft paths](../atoms/dual-raft-paths.md)
- [RocksDBEngine](../atoms/rocksdb-engine.md)
- [client pool](../atoms/client-pool.md)
