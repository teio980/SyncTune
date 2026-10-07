# Sync core protocol

`SyncRoot(id, generation)` identifies one broker grant generation. Every local
and remote snapshot carries that generation and a completeness state. Entries
carry a stable ID, normalized relative path, kind, size, SHA-256, revision, and
an independent `(favorite, lamport, deviceId)` stamp.

The local and remote commit ports carry the complete source `SyncEntry`, so an
adapter can persist the stable ID, content version, and favorite metadata with
the bytes. Local writes use an explicit `LocalCreateOnly` or
`LocalMatchSha256` condition; remote content writes use `If-None-Match: *` or
a strong ETag. A missing condition is a compatibility error, never an
unconditional overwrite.

Operation IDs include `planId`, generation, operation kind, path, stable IDs,
content hashes, favorite stamp, and conditional precondition. They are stable
for recovery of one plan but change when content or precondition changes.

A journal sequence is `staged → committed` or `staged → failed`. The staged
object is verified against the planned SHA-256 before a remote or local commit.
A staged object recovered after restart is re-opened and verified again for
both hash and length before it can be committed.
A successful commit whose journal append was interrupted must be reconciled by
rescan and content/hash comparison; it is never blindly repeated or skipped by
path alone.

`SyncPlanCodec` stores every operation, source/other entry, independent
content/metadata/favorite conditions, local condition, generation and remote
namespace. `PlanStore` writes that payload before staging. On restart the
coordinator loads only an unfinished plan for the same grant generation and
remote namespace, then compares current complete snapshots and ETags before
reusing it; a changed source supersedes the old plan and creates a new one.

For a concurrent file edit, the planner chooses a deterministic primary entry
and gives the other entry a deterministic collision-safe identity and path.
The conflict executor persists separate staging handles and completion records
for each copy/replace step, including the merged favorite update on a local
primary. On restart, the coordinator checks complete local and remote snapshots
against those records; if a write landed but its completion append did not, it
records the observed effect and resumes at the next step. It rejects states
that do not match the plan. The plan remains unconfirmed until a subsequent
complete snapshot proves both copies and their independent metadata are equal
on both sides.

Local catalog records use opaque persisted UUID identities. They retain
remote identities across renames and durable tombstones across complete scans;
the active broker root remains the only source of file I/O.
