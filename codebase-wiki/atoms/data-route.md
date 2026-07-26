---
type: object
tags: [self-built-raft, state-machine, dispatch]
backlinks:
  - ../analysis/03-core-design.md
refs:
  - src/placement-center/src/raft/route.rs
  - src/placement-center/src/raft/apply.rs
  - src/placement-center/src/storage/kv.rs
---

# DataRoute

## Definition

自研 raft 路径下的状态机分发器。raft-rs 主循环把 committed entry 交给它，
它按 `StorageData::data_type` 分发到对应的 handler，写入业务存储（RocksDB）。

## Evidence

- `src/placement-center/src/raft/route.rs`
- 被 `src/placement-center/src/raft/machine.rs:handle_committed_entries` 调用。

## 行为

```rust
pub fn route(&self, data: Vec<u8>) -> Result<(), RobustMQError> {
    let storage_data: StorageData = bincode::deserialize(&data)?;
    match storage_data.data_type {
        StorageDataType::KvSet => {
            let req = SetRequest::decode(data.as_ref())?;  // ⚠ 用了 data 而不是 storage_data.value
            self.kv_storage.set(req.key, req.value)
        }
        StorageDataType::KvDelete => {
            let req = DeleteRequest::decode(data.as_ref())?;
            self.kv_storage.delete(req.key)
        }
    }
}
```

## 已知 demo bug

分发分支里的第二次解码用了 `data.as_ref()`（外层 bincode bytes），不是
`storage_data.value.as_ref()`（内层 prost bytes）。

之所以"看起来能跑通"：
- 外层 bincode 编码后的 bytes 长这样：`<data_type tag><value length><value bytes>`。
- prost 解码 `SetRequest` 时使用 protobuf wire format，会容忍前缀的"未知字段"
  并继续往后扫描，正好跨过 bincode 的头部、读到内层 SetRequest bytes。
- bincode 的 padding 和 prost 的 wire format 之间没有保证不冲突——仅在当前
  字段编号下凑巧能解码出来。

正确实现应是 `SetRequest::decode(storage_data.value.as_ref())`。
课程版保留原状作为反例教学。

## Why this matters

`DataRoute::route` 是自研 raft 路径的 **唯一** 业务命令分发点。它的 bug 不会被
任何上层捕获——`KvStorage::set` 调用成功后，business view 从此和 raft view 偏离。
但因为当前运行时 `raft.run()` 被注释，这条 bug 路径不会被触发。
