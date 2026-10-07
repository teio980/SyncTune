# WebDAV contract

The adapter must support PROPFIND file metadata with a strong ETag, streaming GET,
conditional PUT and conditional DELETE. New objects use `If-None-Match: *`;
updates use `If-Match`; 412 stops the current plan. The complete entry
descriptor is stored at `.synctune/entries/<encoded-relative-path>.xml` and
favorite metadata is stored at `.synctune/favorites/<encoded-relative-path>.xml`.
Each file object has its own strong ETag; a content update therefore carries both
the content ETag and the entry-descriptor ETag, while a favorite update uses
the favorite ETag. A missing or weak precondition is a compatibility error.

Before any content or metadata PUT, the adapter creates every missing parent
collection with MKCOL in root-to-leaf order. A 405 from MKCOL is accepted only
when a follow-up PROPFIND proves that the requested resource is the expected
DAV collection; a file or an unverified response is an incompatibility error.

The snapshot adapter requires the entry descriptor for every managed music
file. It rejects an unpaired live descriptor/content object, preserves a
descriptor tombstone after content deletion, and reads the independent
favorite document before exposing the remote snapshot. Ordinary WebDAV files
without SyncTune metadata are reported as incompatible until an explicit
identity adoption flow is invoked. Adoption checks the existing resource
size/strong ETag and writes the descriptor with create-only metadata CAS; it
never happens as a side effect of a background scan.

Collections may omit their ETag because traversal and MKCOL verification do not
use directory CAS. Files and descriptors still require strong ETags. When a
snapshot finds ordinary music without a descriptor, the Sync page offers
**Import cloud music**. This explicit operation enumerates the selected cloud
root, verifies each unpaired song with conditional streaming GET and SHA-256,
and creates its identity descriptor with `If-None-Match: *`. It reads song
content without replacing or deleting it. A retry preserves existing identities
and continues with the remaining files; cancellation or changed bytes stops the
import. After import, the ordinary coordinator performs synchronization and
confirms the baseline through both post-scans.

Before a managed file enters a remote snapshot, the adapter performs a
conditional streaming GET against the PROPFIND strong ETag and computes the
full SHA-256 and byte length. A descriptor hash is never trusted from length
alone. If the ETag or content changes during the descriptor pass, the run
stops for rescan. Explicit adoption uses the same conditional hash check
before writing create-only identity metadata.

An unfinished plan is recovered before the next remote snapshot. Recovery is
limited to journaled operations with matching root generation and remote
namespace, staged SHA-256 and byte length, and current content proven by a
strong-ETag conditional GET. A descriptor repair compares the complete prior
descriptor and then uses the latest verified descriptor ETag for its CAS;
favorite stamps are merged by Lamport/device order. Delete and preserve-both
conflict substeps use the same durable intent and checks. Any changed bytes,
identity fields, scope, or failed CAS stops the plan for rescan and never
performs an unconditional write.

HTTPS is required for configured internet endpoints. LAN WebDAV is a separate
runtime check and a loopback response is not accepted as LAN evidence.
