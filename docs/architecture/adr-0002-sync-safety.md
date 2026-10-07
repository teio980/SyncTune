# ADR-0002: conditional synchronization and broker roots

Status: accepted

The kernel never receives an absolute path or credential. A platform adapter
must first obtain a user-selected SAF URI or WinRT StorageFolder/FutureAccessList
token, assign a persisted authorization generation, and resolve only validated
`SyncPath` segments below that root. Reparse points and aliases are skipped.

Remote creation sends `If-None-Match: *`. Existing content and delete operations
require the exact strong content ETag returned by PROPFIND. Favorite metadata is
stored in a separate `.synctune` object and uses that object's own ETag. A weak
or absent ETag is a compatibility error and stops the plan.

All content is staged and hashed before commit. The post-run baseline is saved
only after complete local and remote rescans agree. A partial scan, lost grant,
precondition failure, or cancellation leaves the old baseline and requires a
new plan.
