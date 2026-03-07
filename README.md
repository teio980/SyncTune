# SyncTune

Personal, modular music player with cloud-ready sync — no central server.

SyncTune focuses on local MP3 playback and a clean library model while preparing the path for cloud synchronization via storage adapters (Google Drive first, NAS/WebDAV next). Android is implemented; Windows is planned.

---

## ✨ Features

Implemented
- Local MP3 playback (ExoPlayer): play/pause/seek/next/previous
- Playlist support; shuffle/loop via Player controls
- Library scan for Music directory; ID3 metadata parsing (title, artist, album)
- SQLite library with fields: id, title, artist, album, file_path, file_hash (MD5), modified_time
- MD5-based dedupe; repeat scans do not insert duplicates
- DB cleanup for locally removed files (library stays consistent)
- Sync Settings page:
  - Enable Cloud Sync toggle (persisted) [link](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/sync/SyncManager.kt)
  - Local directory picker via SAF (persisted) [link](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/ui/settings/SettingsFragment.kt)
  - Google Drive “Developer Mode” credentials input (Client ID/Secret/Refresh Token) [link](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/res/layout/fragment_settings.xml)

Coming Soon
- In-app OAuth login for Google Drive (no manual credentials)
- Background sync (WorkManager): upload/download reconciliation
- Cloud deletion linkage when local files are removed
- Conflict resolution UI (filename vs MD5) and user choices
- NAS/WebDAV adapter, Windows client (Electron + React)

---

## 🚀 Getting Started (Android)

Requirements
- Android Studio, SDK 34
- Gradle 8.2; JDK 17 compatible

Open & Run
- Open folder: `SyncTune/android`
- Let Gradle sync dependencies
- Run on emulator/device

Key modules
```
app
 ├── ui
 ├── player
 ├── library
 ├── sync
 └── storage
```

References
- Player manager: [PlayerManager.kt](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/player/PlayerManager.kt)
- Library & scan: [LibraryFragment.kt](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/ui/library/LibraryFragment.kt)
- Metadata reader: [MetadataReader.kt](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/library/MetadataReader.kt)
- SQLite schema & DAO: [schema.sql](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/schema.sql), [SongDao.kt](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/library/SongDao.kt)
- Settings: [SettingsFragment.kt](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/ui/settings/SettingsFragment.kt)

---

## ⚙️ Sync Settings

Cloud Sync toggle
- Enable/Disable sync state stored via SharedPreferences [link](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/sync/SyncManager.kt)

Local library directory
- Choose with Storage Access Framework (persisted URI) [link](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/ui/settings/SettingsFragment.kt)

Google Drive (Developer Mode)
- Manual input of Client ID / Client Secret / Refresh Token
- Saved via SyncManager getters/setters
- Drive client wiring stub: [GoogleDriveAdapter.kt](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/storage/GoogleDriveAdapter.kt)

OAuth Login (coming soon)
- App-led OAuth flow to obtain and refresh tokens without manual entry

---

## � Sync Rules (design)

Comparison basis
- MD5 file hash ensures dedupe and accurate matching

Intended actions
| Situation                            | Action   |
| ------------------------------------ | -------- |
| Local file exists, cloud missing     | Upload   |
| Cloud file exists, local missing     | Download |
| Local delete                         | Delete on cloud (coming soon) |
| Both exist                           | Skip/Update metadata |

Flow (planned)
```
Scan local → List cloud → Compare by MD5
Upload missing → Download missing → Delete cloud for local removals
```

---

## 📂 Folder Structure & Metadata

Default layout scanned
```
Music/
  Artist/
    Song.mp3
```

ID3 parse for title/artist/album. Missing title falls back to filename.

---

## 🗄 Database Model

Songs table fields
```
id
title
artist
album
file_path
file_hash
modified_time
```

`file_hash` drives sync and dedupe.

---

## 🏗 Architecture

Modular design
```
UI
Library
Player
Sync
Storage Adapter (Google Drive, WebDAV next)
```

Adapter pattern allows adding providers without changing core.

---

## � Windows (planned)

Electron + React preferred, Python + Qt optional.

Modules mirror Android: player, library, sync, storage.

---

## 🛣 Roadmap

- Google Drive OAuth login (no manual credentials)
- Background sync & scheduling (WorkManager)
- Cloud deletion linkage on local removal
- Conflict resolution UI, merge strategies
- NAS/WebDAV storage adapter
- Windows client

---

## 📄 License

Open source, intended for personal music library synchronization.
