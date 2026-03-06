# SyncTune

SyncTune is a cross-platform music player designed to keep your local music library synchronized across devices.

It automatically syncs MP3 files with cloud storage, allowing you to maintain a consistent music library between Android and Windows without relying on a centralized server.

The system is built with a modular architecture that supports multiple storage providers. Currently, Google Drive synchronization is implemented, with NAS (WebDAV) planned for future releases.

---

## ✨ Features

* 🎵 Local MP3 music player
* 🔄 Automatic cloud synchronization
* ☁️ Google Drive integration
* 📱 Android + Windows support
* 🧩 Modular storage provider architecture
* 🔍 Automatic music library scanning
* 🗂 ID3 metadata parsing (title, artist, album)
* 📦 SQLite-based music library database
* ⚡ Hash-based duplicate detection (MD5)

---

## 🚀 How It Works

SyncTune keeps your music library consistent across devices.

Synchronization rules:

| Situation                            | Action   |
| ------------------------------------ | -------- |
| Local file exists but cloud does not | Upload   |
| Cloud file exists but local does not | Download |
| Both exist                           | Skip     |

The system compares files using **MD5 hash values** to avoid duplicates.

Example sync flow:

Local Scan → Cloud File List → Compare Hash → Upload / Download

---

## 🏗 Architecture Overview

The application is composed of several core modules:

Music Player
Handles playback functionality including play, pause, seek, playlist, shuffle, and repeat.

Library Manager
Scans the local music folder and extracts metadata from MP3 files.

Sync Engine
Responsible for synchronization logic between local storage and cloud providers.

Storage Adapter
Provides a unified interface for different storage providers.

```
Music Player
      │
Library Manager
      │
   Sync Engine
      │
 Storage Adapter
      │
 Google Drive
```

The architecture allows additional storage providers to be added without modifying the core system.

---

## ☁️ Storage Providers

Current provider:

* Google Drive

Planned providers:

* NAS (WebDAV)
* OneDrive
* Dropbox

Storage providers are implemented using an **Adapter Pattern**.

Example interface:

```
StorageAdapter
 ├── listFiles()
 ├── uploadFile()
 ├── downloadFile()
 └── deleteFile()
```

---

## 📱 Platforms

SyncTune supports multiple platforms.

### Android

Technology stack:

* Kotlin
* MVVM architecture
* ExoPlayer for audio playback
* WorkManager for background synchronization
* SQLite for local music library

App modules:

```
app
 ├── ui
 ├── player
 ├── library
 ├── sync
 └── storage
```

Synchronization runs periodically in the background.

---

### Windows

Planned desktop implementation.

Recommended stack:

Option A:
Electron + React

Option B:
Python + Qt

Modules:

```
player
library
sync
storage
```

---

## 📂 Music Folder Structure

SyncTune scans a local music folder such as:

```
Music/
    Artist/
        Song.mp3
```

Metadata such as **title, artist, and album** are extracted from ID3 tags.

---

## 🗄 Database Schema

Local music metadata is stored using SQLite.

Songs table:

```
id
title
artist
album
file_path
file_hash
modified_time
```

The `file_hash` field is used for synchronization comparison.

---

## 🔄 Synchronization Algorithm

Simplified logic:

```
localSongs = scanLocal()

cloudSongs = listCloud()

for song in localSongs:
    if song.hash not in cloudSongs:
        upload(song)

for song in cloudSongs:
    if song.hash not in localSongs:
        download(song)
```

This ensures both devices maintain identical music libraries.

---

## ⚙️ Sync Settings UI

Users can choose their synchronization provider from the app interface.

Example:

```
Sync Settings

Provider:
[ Google Drive ▼ ]

Status:
Connected

[ Sync Now ]
```

The UI is designed to allow additional providers in the future.

---

## 📌 Project Goals

SyncTune aims to provide:

* A simple personal music synchronization system
* Full control over your music files
* No dependency on streaming services
* Cross-device music library consistency

---

## 🛣 Roadmap

Planned features:

* NAS (WebDAV) support
* Lyrics support
* Album artwork fetching
* Playback progress synchronization
* Playlist cloud sync
* Multi-device conflict handling

---

## 🤝 Contributing

Contributions are welcome.

Possible contribution areas:

* Desktop client implementation
* Additional cloud storage adapters
* UI improvements
* Performance optimization

---

## 📄 License

This project is open source and intended for personal music library synchronization.
