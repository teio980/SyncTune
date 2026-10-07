# WebDAV contract

The adapter supports PROPFIND file metadata, streaming GET,
conditional PUT and conditional DELETE. New objects use `If-None-Match: *`;
updates use `If-Match`; 412 stops the current plan. The complete entry
descriptor is stored at `.synctune/entries/<encoded-relative-path>.xml` and
favorite metadata is stored at `.synctune/favorites/<encoded-relative-path>.xml`.
Each file object has its own strong ETag; a content update therefore carries both
the content ETag and the entry-descriptor ETag, while a favorite update uses
the favorite ETag. Missing or weak server ETags now select checksum validation
instead of blocking synchronization. A successful conditional GET may omit its
response ETag; the If-Match request still pins the observed server version.

When no strong validator is available, snapshots compute SHA-256 fingerprints
from actual file/descriptor/favorite bytes. These internal tokens occupy the
core's opaque validator slot but are never sent as HTTP ETags. Before overwrites
or deletes, the transport checks current bytes against the observed checksum.
Writes whose response omits a strong ETag are read back and checked against the
intended checksum; deletes using a checksum are checked for absence. This
ordinary WebDAV fallback has a check/write race and cannot guarantee atomic CAS
against concurrent writers. Create-only writes retain If-None-Match: *.

Before any content or metadata PUT, the adapter creates every missing parent
collection with MKCOL in root-to-leaf order. A 405 from MKCOL is accepted only
when a follow-up PROPFIND proves that the requested resource is the expected
DAV collection; a file or an unverified response is an incompatibility error.

The snapshot adapter requires the entry descriptor for every managed music
file. It rejects an unpaired live descriptor/content object, preserves a
descriptor tombstone after content deletion, and reads the independent
favorite document before exposing the remote snapshot. Ordinary WebDAV files
without SyncTune metadata require identity adoption. A manual Sync or Retry
request performs adoption and continues the same sync run; automatic scans
offer an import action without writing descriptors. Adoption checks the existing resource
size/content checksum and writes the descriptor with create-only metadata CAS; it
never happens as a side effect of a background scan.

Collections may omit their ETag because traversal and MKCOL verification do not
use directory CAS. Files and descriptors can use checksum validation. When a
snapshot finds ordinary music without a descriptor, the Sync page offers
**Import cloud music**. This explicit operation enumerates the selected cloud
root, verifies each unpaired song with conditional streaming GET and SHA-256,
and creates its identity descriptor with `If-None-Match: *`. It reads song
content without replacing or deleting it. A retry preserves existing identities
and continues with the remaining files; cancellation or changed bytes stops the
import. Retry resumes a failed import rather than switching to an ordinary
scan that would fail on the remaining unpaired files. With strong validators,
each song is hashed once during import, then its PROPFIND ETag/length are rechecked before descriptor
creation. Without a strong listing ETag, import rechecks the song checksum
before creating its descriptor. GET requests explicitly use `Accept-Encoding: identity` so content
negotiation does not select a compressed representation with a different ETag.
After import, the ordinary coordinator performs synchronization and
confirms the baseline through both post-scans.

Before a managed file enters a remote snapshot, the adapter performs a
streaming GET (conditional when PROPFIND supplies a strong ETag) and computes the
full SHA-256 and byte length. A descriptor hash is never trusted from length
alone. If the ETag or content changes during the descriptor pass, the run
stops for rescan. Explicit adoption uses the same conditional hash check
before writing create-only identity metadata.

An unfinished plan is recovered before the next remote snapshot. Recovery is
limited to journaled operations with matching root generation and remote
namespace, staged SHA-256 and byte length, and current content proven by a
server validator or checksum. A descriptor repair compares the complete prior
descriptor and then uses the latest verified descriptor ETag for its CAS;
favorite stamps are merged by Lamport/device order. Delete and preserve-both
conflict substeps use the same durable intent and checks. Any changed bytes,
identity fields, scope, or failed CAS stops the plan for rescan and never
performs an unconditional write.

HTTPS is required for configured internet endpoints. LAN WebDAV is a separate
runtime check and a loopback response is not accepted as LAN evidence.
