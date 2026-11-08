# SQLite amalgamation for macOS 12

This directory vendors the unmodified SQLite 3.53.4 amalgamation (`sqlite3.c`), matching the version bundled by Dart package sqlite3 3.7.0. SQLite is in the public domain; the original notice is retained at the top of the source.

Source: https://sqlite.org/2026/sqlite-amalgamation-3530400.zip

Archive SHA3-256: `628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`

Source SHA-256: `b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189`

Only macOS uses this source, through the sqlite3 package's documented `source: source` hook. Windows and Android keep the package's default precompiled libraries. The package's default SQLite compilation options are retained, with an explicit macOS 12 deployment flag and optimization enabled.

Both the package's precompiled macOS library and Flutter 3.47.6's default native-asset target specify macOS 13. Compiling from source with a final `-mmacos-version-min=12.0` flag ensures the bundled SQLite binary supports SyncTune's macOS 12 target. The release verification script checks each Mach-O slice's minimum OS to catch regressions.

When upgrading SQLite, update the Dart dependency and this source together, verify the upstream archive checksum, and rerun the Dart tests and universal bundle checks.
