# SyncTune

SyncTune is a manual, two-way music synchronizer for Windows, Android, and macOS. It keeps a local music folder and a folder on an HTTPS WebDAV server in sync, so you can keep the same library on multiple devices.

## Features

- Syncs `.mp3`, `.flac`, `.wav`, `.m4a`, `.aac`, `.ogg`, and `.opus` files in both directions.
- Preserves different edits made on each side by keeping both versions.
- Shows sync progress and lets you cancel and resume an interrupted sync.
- Includes a local music list with refresh and delete controls.
- Supports English and Simplified Chinese, with a theme that follows the system.

## How to use

1. Open **Settings** and choose the local music folder. On Android, grant access to the folder in the system picker.
2. Enter the complete **HTTPS WebDAV URL** for the remote music folder, plus your username and password. The folder path belongs in the URL; there is no separate remote-folder field. The target folder must already exist.
3. Select **Test connection** to check the URL and credentials. This sends a read-only request and does not change files. Then select **Save settings**.
4. Open **Sync** and select **Start sync**. On Android, allow notifications so syncing can continue when the app is in the background or the screen is locked.
5. Open **Music** to browse or refresh the local song list. To delete songs, select them and confirm. They are removed from this device immediately; songs already included in sync history are also removed from WebDAV on the next sync.

The first sync merges songs already present in both folders and does not infer deletions. If different songs share a path, the WebDAV version keeps that path and SyncTune saves the local version as a conflict copy. On later syncs, additions, edits, and deletions are synchronized between the two folders.

Use **Cancel sync** to pause and resume the same work later. Use **Force stop and reset** to abandon a stuck or interrupted run. It stops active sync work, clears pending operations, scan checkpoints, and sync history, and keeps your settings, music, and recovery copies. The next **Start sync** scans both folders from scratch and merges them like a first sync; songs deleted from only one side may be copied back from the other side. Recovery copies remain in internal storage and are excluded from normal music scans.

## Run and build

Use Flutter **3.47.6** (Dart **3.13.5**), matching CI, then run `flutter pub get`.

```sh
flutter run -d macos      # macOS 12 or newer; full Xcode required
flutter run -d windows   # Windows; Visual Studio desktop C++ tools required
flutter run -d DEVICE_ID # Android device or emulator ID from flutter devices
```

On macOS, run `scripts/package_macos.sh` to build and verify the universal Release app and create `dist/SyncTune-macos-universal.zip`. Extract the ZIP and open `SyncTune.app`, or copy it to Applications. This build uses a local ad-hoc signature; Developer ID signing and notarization are not included.

macOS stores settings and sync history in `~/Library/Application Support/SyncTune/synctune-state-v2.sqlite` and WebDAV passwords in the login Keychain. Selecting a music folder grants the non-sandboxed app normal filesystem access. Closing the window or pressing **Cmd+Q** cancels active synchronization, waits for cleanup, then quits. Start sync again after reopening to recover interrupted work.

See [macOS development and verification](docs/macos.md) for toolchain setup, native tests, and release checks.
