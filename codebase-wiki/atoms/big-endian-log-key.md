---
type: invariant
tags: [openraft, log, encoding, ordering]
backlinks:
  - ../analysis/03-core-design.md
refs:
  - src/placement-center/src/openraft/store/log_store.rs
  - src/placement-center/src/openraft/store/mod.rs
---

# Big-Endian Log Index Key Encoding

## Rule

openraft `LogStore` 把 `_raft_logs` CF 的 key 编码为 **big-endian u64**
（log index 转 8 字节 BE bytes），这样 RocksDB 的字典序与数字序一致。

## Why

RocksDB 按 key 字典序存储；如果用 little-endian 或 to_string 编码，
`range_scan(prefix=..., start=10, end=200)` 会扫到错误的 entry：
- 字符串 `"10"` < `"2"` < `"200"`，按字符串排会乱序。
- LE u64：低位字节先排，0x100 排在 0x200 之前没问题，但跨字节边界（0x100 vs 0x99）
  会跨字节比较，仍然乱序。

big-endian 把高位字节放前面，符合"数值大小 == 字典序"——这是 RocksDB / LevelDB 类
key-value store 存数值索引的标配做法。

## Enforcement sites

- `src/placement-center/src/openraft/store/log_store.rs`：`bin(idx)` 函数把 u64 转成 BE bytes 作为 key。
- `try_get_log_entries` 里 `range_scan` 直接拿 BE bytes 作为 start/end。

## Consequences if violated

- log iterator 出错的顺序，apply 的顺序错乱 → 状态机写入错乱。
- snapshot purge 时删错 entry，可能误删未来的 log。
- 多数派复制时给 follower 的 entry 顺序不对，违反 raft 协议。

## Edge cases

- log_index = 0：`b"\x00\x00\x00\x00\x00\x00\x00\x00"`，不会和元数据 key（如
  `b"vote"`、`b"committed"`）冲突——元数据用纯字符串 key，长度通常较短，
  big-endian u64 长度恒 8 字节，碰撞概率极低。
- 但**没有显式的 namespace prefix** 把 log keys 和元数据 keys 隔开；当前实现假设
  字符串 key 不会刚好 8 字节并以 `\x00` 开头。这是脆弱假设，生产应加显式前缀。
