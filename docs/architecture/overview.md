# SyncTune architecture

The application is a modular monolith with MVVM boundaries. `sync_core` is
pure Dart and owns identity, scan states, three-way planning, journal-aware
execution, and baseline commit rules. Flutter Riverpod exposes view models to
Material 3 screens; screens do not call Drift, Dio, WinRT, or Android APIs.

`Drift` stores device identity, authorized-root generations, baselines,
tombstones, favorite Lamport stamps, operation journals, and WebDAV metadata.
`Dio` plus `XML` implements WebDAV PROPFIND/GET/PUT/DELETE and parses strong
ETags. The transport refuses a server without the required conditional
semantics. Android uses SAF persisted URI permissions; Windows uses brokered
StorageFolder/FutureAccessList handles. Both adapters return opaque root
handles and skip reparse/symlink escapes.

Platform services stay behind the broker ports in
`lib/infrastructure/platform`: music bytes and staged objects use only an
opaque root token, generation, relative path, and opaque staging key. The
credential port uses native Android Keystore AES-GCM or Windows PasswordVault;
credentials are never stored in the sync database or diagnostics. Native
`brokerCapabilities` values are part of the compatibility gate: a plan that
needs conditional replacement or deletion is stopped when the provider does
not expose a verified compare-and-swap primitive.

A run is `scan → plan → stage/hash → conditional commit → rescan → baseline
commit`. Partial or unauthorized scans cannot schedule deletion. A generation
change stops the run and resets the baseline relationship. A 412, cancellation,
missing strong ETag, or staging hash mismatch stops the stale plan and requires
a fresh scan. Journal records identify the plan, root generation, stable entry,
content hash, staging key, and precondition, so a later run cannot skip new
content at the same path.

The UI has music, sync, and settings modules. Widths below 600 use bottom
navigation, 600–999 use a navigation rail, and 1000 or wider use an expanded
rail with a virtualized table. The color seed is `#4F46E5`; light, dark, and
system modes share the same Material 3 tokens. The product is a file sync tool,
not a player or playlist editor.
