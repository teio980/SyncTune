Build the SyncTune Desktop application core logic using:

Kotlin + Compose Multiplatform Desktop

The application is a local music player with cross-device favourite sync via WebDAV.

Focus on:

music library management

incremental scanning

favourite synchronization

user-selectable music folders

Do NOT focus on UI styling.

1. Project Architecture

Create a modular architecture.

core/
 ├── model/
 │     Song.kt
 │
 ├── database/
 │     DatabaseManager.kt
 │     SongDao.kt
 │
 ├── scanner/
 │     MusicScanner.kt
 │
 ├── metadata/
 │     MetadataReader.kt
 │
 ├── hash/
 │     HashUtil.kt
 │
 ├── settings/
 │     SettingsManager.kt
 │
 ├── sync/
 │     WebDavClient.kt
 │     FavouriteSyncManager.kt
 │
 ├── library/
 │     MusicLibraryManager.kt
2. Song Data Model

Create the Song entity compatible with the Android version.

data class Song(
    val fileHash: String,
    var filePath: String,
    var fileName: String,
    var title: String?,
    var artist: String?,
    var album: String?,
    var duration: Long,
    var modifiedTime: Long,
    var isFavourite: Boolean
)

Rules:

fileHash must be UNIQUE

filePath indexed

modifiedTime stores filesystem timestamp

3. Database (SQLite)

Use SQLite JDBC.

Table structure:

songs

Columns:

fileHash TEXT PRIMARY KEY
filePath TEXT
fileName TEXT
title TEXT
artist TEXT
album TEXT
duration INTEGER
modifiedTime INTEGER
isFavourite INTEGER

Indexes:

CREATE INDEX idx_song_path ON songs(filePath);
CREATE INDEX idx_song_hash ON songs(fileHash);

Implement DAO methods:

insertSong(song)
updateMetadata(hash, modifiedTime)
updatePath(hash, newPath, newName)
deleteByPath(path)

getAllSongs()
getSongByPath(path)
getSongByHash(hash)

getFavouriteHashes()
updateFavourite(hash, value)
4. User Selectable Music Folders

Users must be able to choose where their music is stored.

Create SettingsManager.

Settings file example:

settings.json

Example:

{
 "musicFolders": [
   "D:/Music",
   "E:/Downloads/Songs"
 ],
 "webdavUrl": "",
 "webdavUser": "",
 "webdavPassword": ""
}

Functions required:

getMusicFolders()
addMusicFolder(path)
removeMusicFolder(path)
saveSettings()
loadSettings()
5. Folder Picker UI Requirement

Users must be able to choose folders using system folder picker.

Example Compose Desktop:

FileDialog
JFileChooser

When user selects a folder:

settingsManager.addMusicFolder(path)

Then trigger:

musicScanner.scanMusic(folders)
6. Smart Incremental Scanner

Implement:

MusicScanner.scanMusic(folders: List<String>)

Supported formats:

.mp3
.flac
.m4a
.wav
Step 1 Scan Files

Recursively scan all user selected folders.

Step 2 Build DB Map

Load DB songs.

dbSongsByPath = Map<String, Song>
Step 3 Process Files

For every local file:

Case A Path Exists
dbSong = dbSongsByPath[path]

Check:

localFile.lastModified > dbSong.modifiedTime + 2000

If true:

re-read metadata

update DB

songDao.updateMetadata(...)
Case B Path Not Found

Compute hash.

hash = HashUtil.computeHash(file)
Case B1 Hash Exists

File moved or renamed.

Update:

songDao.updatePath(hash,newPath,newFileName)
Case B2 Hash Not Found

New song.

Steps:

read metadata
compute hash
insert song
Step 4 Cleanup Missing Files

After scan:

Detect DB records whose file paths no longer exist.

Return list:

missingSongs

UI may ask user whether to remove them.

7. Hash Strategy

Create:

HashUtil.computeHash(file)

Use:

MD5

But optimize:

first 8KB of file
+
file size

This avoids hashing entire large audio files.

8. Metadata Reader

Create:

MetadataReader.readMetadata(file)

Use library:

jaudiotagger

Extract:

title
artist
album
duration

Fallback:

title = filename
9. WebDAV Sync Protocol

Only sync favourites.

Remote file:

favourites.json

Example:

{
 "hash_1": true,
 "hash_2": true
}
10. Pull Sync

Before scan:

download favourites.json

Steps:

parse JSON
extract hashes
update database

SQL:

UPDATE songs
SET isFavourite=1
WHERE fileHash IN (...)
11. Push Sync

Triggered when:

user clicks favourite
or manual sync

Steps:

query DB favourite songs
extract hashes
generate JSON
upload via WebDAV PUT
12. WebDAV Client

Create:

WebDavClient.kt

Use:

OkHttp

Support:

GET
PUT
PROPFIND

Functions:

downloadFile()
uploadFile()
fileExists()
13. Music Library Manager

Create central manager:

MusicLibraryManager.kt

Responsibilities:

load settings
scan folders
sync favourites
refresh UI

Example workflow:

1 load folders
2 pull favourites
3 scan music
4 update library
14. UI Requirements

Main UI must include:

Library

Song list

Display:

cover
title
artist
duration
Scan Status

Show:

Currently scanning: filename
progress bar
Folder Manager

UI must allow:

Add Folder
Remove Folder
Rescan Library
WebDAV Settings

Fields:

URL
Username
Password

Button:

Test Connection
Sync Button

Action order:

download favourites.json
update database
refresh UI
15. Sorting

Song list must support sorting by:

modifiedTime DESC

Newest songs appear first.

16. Code Quality Rules

Code must follow:

Kotlin idiomatic

coroutine based scanning

no UI thread blocking

modular design

production quality

Expected Output

Generate complete Kotlin code for:

SongDao.kt
MusicScanner.kt
HashUtil.kt
MetadataReader.kt
SettingsManager.kt
WebDavClient.kt
FavouriteSyncManager.kt
MusicLibraryManager.kt

All code must compile.