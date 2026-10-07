# Core limits and adapter obligations

The core planner pauses immediately when a root grant is unauthorized or its
persisted generation changes. Partial scans may transfer edits but cannot infer
or schedule deletion. A complete scan turns a baseline-only absence into a
persistent tombstone operation; adapters must retain tombstones in Drift so a
later scan does not forget the deletion.

`MatchEtag` accepts only a quoted strong entity tag. Entry metadata and
favorite metadata use separate objects and separate ETags. A present object
with no required metadata ETag is a compatibility stop, not an unconditional
write. The journal stores both conditions so recovery cannot silently reuse a
content ETag for a metadata write.

Concurrent content conflicts are represented as `conflict` operations carrying
both entries, a deterministic preserve-both path, and the side that owns the
primary bytes. The executor stages and hashes both streams, writes the
secondary copy to the collision-safe path on both stores, then commits the
primary path with its conditional version. A failed substep returns
`NeedsRescan`; the original bytes remain available for reconciliation. Each
stage and materialization step has its own journal key. After restart, complete
snapshots can recover a missing completion marker when the expected effect is
already present, avoiding duplicate copies. The operation is considered
confirmed only after both complete post-scans agree.
Directories likewise remain metadata-only until an adapter provides safe
non-recursive create/delete operations.

If a content commit succeeds and the durable journal append fails, the executor
returns `NeedsRescan` instead of retrying the stale plan. The adapter must
rescan and compare hashes/ETags before deciding whether to append a recovered
commit record. A local commit should also use its expected source hash and
conditional version so edits after the scan are never overwritten.
