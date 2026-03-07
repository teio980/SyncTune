# SyncTune User Manual

## Overview
- Local MP3 player focused on a clean, personal library.
- Android app implemented; Windows client planned.
- Cloud-ready via storage adapters; Google Drive developer mode available.

## Quick Start (Android)
- Install and open the app.
- Grant media permission when prompted (Android 13+: READ_MEDIA_AUDIO).
- Go to Library and tap “Scan Local Music” to index your songs.
- Tap any item to play; use the bottom control bar or Now Playing screen.

## Permissions
- Android 13+ uses READ_MEDIA_AUDIO instead of READ_EXTERNAL_STORAGE.
- The app requests permission when scanning; allow to proceed.

## Library
- Default layout scanned:
  - Music/Artist/Song.mp3
- Metadata read:
  - title, artist, album (ID3)
- Dedupe:
  - Uses MD5 file hash; repeat scans do not insert duplicates.
- Cleanup:
  - If a local file was deleted, it is removed from the database on next scan.

## Playback
- Bottom control bar:
  - Play/Pause, Next/Previous.
- Now Playing screen:
  - Progress seek, shuffle/loop, playlist controls.
- Playlist:
  - Built from the current Library list.

## Settings
- Cloud Sync toggle:
  - Enable or disable sync state (persisted).
- Library directory:
  - Tap “Music Library Directory” card to choose a folder (SAF).
  - The selected URI is stored for future scans.
- Developer Mode (Google Drive):
  - Enter Client ID, Client Secret, and Refresh Token.
  - Tap “Save API Credentials” to persist.
  - In-app login flow will be added later.

## Google Drive (Developer Mode)
- Purpose:
  - Use your own credentials to prepare for sync.
- Obtain credentials:
  - Create an OAuth 2.0 Client in Google Cloud Console.
  - Use an external tool/script to perform OAuth and capture a Refresh Token.
  - Paste Client ID/Secret/Refresh Token in Settings and save.
- Notes:
  - The app does not perform in-app login yet.
  - Sync logic will reconcile local vs cloud by MD5 (coming soon).

## Sync Rules (Design)
- Basis:
  - MD5 file hash ensures accurate matching and dedupe.
- Intended actions:
  - Local exists, cloud missing → Upload
  - Cloud exists, local missing → Download
  - Local delete → Delete on cloud (coming soon)
  - Both exist → Skip or update metadata
- Flow (planned):
  - Scan local → List cloud → Compare by MD5 → Upload missing → Download missing → Delete cloud for local removals

## Troubleshooting
- No music found:
  - Verify permission is granted; ensure files exist in the chosen directory.
- Scan doesn’t change:
  - Dedupe prevents duplicates; deleted files are cleaned on next scan.
- Permission prompt doesn’t show (Android 13+):
  - The app requests READ_MEDIA_AUDIO; check system settings → App permissions.
- Google Drive credentials:
  - Ensure Client ID/Secret/Refresh Token are correct; reissue if expired.

## References
- Player manager:
  - [PlayerManager.kt](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/player/PlayerManager.kt)
- Library & scan:
  - [LibraryFragment.kt](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/ui/library/LibraryFragment.kt)
- Metadata:
  - [MetadataReader.kt](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/library/MetadataReader.kt)
- Settings:
  - [SettingsFragment.kt](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/ui/settings/SettingsFragment.kt)
- Storage adapter (Drive stub):
  - [GoogleDriveAdapter.kt](file:///c:/Users/Owner/Documents/teiocode/SyncTune/android/app/src/main/java/com/example/synctune/storage/GoogleDriveAdapter.kt)

