# SyncTune

SyncTune is a manual, two-way music synchronizer for Windows and Android. It keeps a local music folder and a folder on an HTTPS WebDAV server in sync, so you can keep the same library on multiple devices.

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
