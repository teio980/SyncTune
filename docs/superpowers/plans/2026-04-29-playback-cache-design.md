# Playback Progress Cache Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Save and restore the last played song's playback progress when app launches.

**Architecture:** Use a separate playback_cache table to store the last played song's hash, file path, position (ms), and last played timestamp. PlayerManager saves position on play events, MainActivity restores on launch.

**Tech Stack:** Android SQLite (existing MusicDbHelper), ExoPlayer's position tracking via Player.Listener

---

## File Structure

| File | Purpose |
|------|---------|
| `library/PlaybackCacheContract.kt` | Define table/column constants |
| `library/PlaybackCacheHelper.kt` | Extend MusicDbHelper, handle cache CRUD |
| `player/PlayerManager.kt` | Add savePosition() calls on playback events |
| `ui/MainActivity.kt` | Restore last played song on startup |
| `schema.sql` | Update with new table |
| `MusicDbHelper.kt` | Add table creation in onCreate |

---

## Task 1: Create PlaybackCacheContract

**Files:**
- Create: `android/app/src/main/java/com/example/synctune/library/PlaybackCacheContract.kt`

- [ ] **Step 1: Write the contract class**

```kotlin
package com.example.synctune.library

import android.provider.BaseColumns

object PlaybackCacheContract {
    const val TABLE_NAME = "playback_cache"
    
    object CacheEntry : BaseColumns {
        const val COLUMN_NAME_ID = "id"
        const val COLUMN_NAME_SONG_HASH = "song_hash"
        const val COLUMN_NAME_FILE_PATH = "file_path"
        const val COLUMN_NAME_POSITION = "position"
        const val COLUMN_NAME_LAST_PLAYED_AT = "last_played_at"
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add android/app/src/main/java/com/example/synctune/library/PlaybackCacheContract.kt
git commit -m "feat: add PlaybackCacheContract for playback cache table"
```

---

## Task 2: Create PlaybackCacheHelper

**Files:**
- Create: `android/app/src/main/java/com/example/synctune/library/PlaybackCacheHelper.kt`
- Modify: `android/app/src/main/java/com/example/synctune/library/MusicDbHelper.kt:25-27`

- [ ] **Step 1: Write PlaybackCacheHelper class**

```kotlin
package com.example.synctune.library

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase

class PlaybackCacheHelper(context: Context) {

    private val dbHelper = MusicDbHelper(context.applicationContext)

    /**
     * Save or update the playback cache for a song.
     * Only one row exists at a time (the last played song).
     */
    fun saveCache(songHash: String, filePath: String, position: Long) {
        val db = dbHelper.writableDatabase
        val values = ContentValues().apply {
            put(PlaybackCacheContract.CacheEntry.COLUMN_NAME_SONG_HASH, songHash)
            put(PlaybackCacheContract.CacheEntry.COLUMN_NAME_FILE_PATH, filePath)
            put(PlaybackCacheContract.CacheEntry.COLUMN_NAME_POSITION, position)
            put(PlaybackCacheContract.CacheEntry.COLUMN_NAME_LAST_PLAYED_AT, System.currentTimeMillis())
        }
        
        db.insertWithOnConflict(
            PlaybackCacheContract.TABLE_NAME,
            null,
            values,
            SQLiteDatabase.CONFLICT_REPLACE
        )
    }

    /**
     * Get the last played song's cache data.
     * @return CacheData or null if no cache exists.
     */
    fun getCache(): CacheData? {
        val db = dbHelper.readableDatabase
        val projection = arrayOf(
            PlaybackCacheContract.CacheEntry.COLUMN_NAME_ID,
            PlaybackCacheContract.CacheEntry.COLUMN_NAME_SONG_HASH,
            PlaybackCacheContract.CacheEntry.COLUMN_NAME_FILE_PATH,
            PlaybackCacheContract.CacheEntry.COLUMN_NAME_POSITION,
            PlaybackCacheContract.CacheEntry.COLUMN_NAME_LAST_PLAYED_AT
        )
        
        val cursor = db.query(
            PlaybackCacheContract.TABLE_NAME,
            projection,
            null,
            null,
            null,
            null,
            "${PlaybackCacheContract.CacheEntry.COLUMN_NAME_LAST_PLAYED_AT} DESC",
            "1"
        )
        
        return cursor.use {
            if (it.moveToFirst()) {
                CacheData(
                    id = it.getLong(it.getColumnIndexOrThrow(PlaybackCacheContract.CacheEntry.COLUMN_NAME_ID)),
                    songHash = it.getString(it.getColumnIndexOrThrow(PlaybackCacheContract.CacheEntry.COLUMN_NAME_SONG_HASH)),
                    filePath = it.getString(it.getColumnIndexOrThrow(PlaybackCacheContract.CacheEntry.COLUMN_NAME_FILE_PATH)),
                    position = it.getLong(it.getColumnIndexOrThrow(PlaybackCacheContract.CacheEntry.COLUMN_NAME_POSITION)),
                    lastPlayedAt = it.getLong(it.getColumnIndexOrThrow(PlaybackCacheContract.CacheEntry.COLUMN_NAME_LAST_PLAYED_AT))
                )
            } else {
                null
            }
        }
    }

    data class CacheData(
        val id: Long,
        val songHash: String,
        val filePath: String,
        val position: Long,
        val lastPlayedAt: Long
    )
}
```

- [ ] **Step 2: Commit**

```bash
git add android/app/src/main/java/com/example/synctune/library/PlaybackCacheHelper.kt
git commit -m "feat: add PlaybackCacheHelper for playback cache CRUD"
```

---

## Task 3: Update MusicDbHelper with cache table

**Files:**
- Modify: `android/app/src/main/java/com/example/synctune/library/MusicDbHelper.kt:25-27` (onCreate)
- Modify: `android/app/src/main/java/com/example/synctune/library/MusicDbHelper.kt` (add CREATE SQL)
- Modify: `android/schema.sql`

- [ ] **Step 1: Add table creation SQL to MusicDbHelper**

In `MusicDbHelper.kt`, add the SQL inside `SQL_CREATE_ENTRIES` block (around line 51):

Change from:
```kotlin
private const val SQL_CREATE_ENTRIES = """
    CREATE TABLE IF NOT EXISTS ${SongContract.SongEntry.TABLE_NAME} (...)
"""
```

To:
```kotlin
private const val SQL_CREATE_ENTRIES = """
    CREATE TABLE IF NOT EXISTS ${SongContract.SongEntry.TABLE_NAME} (
        ${SongContract.SongEntry.COLUMN_NAME_ID} INTEGER PRIMARY KEY,
        ${SongContract.SongEntry.COLUMN_NAME_TITLE} TEXT,
        ${SongContract.SongEntry.COLUMN_NAME_ARTIST} TEXT,
        ${SongContract.SongEntry.COLUMN_NAME_ALBUM} TEXT,
        ${SongContract.SongEntry.COLUMN_NAME_FILE_PATH} TEXT,
        ${SongContract.SongEntry.COLUMN_NAME_FILE_NAME} TEXT,
        ${SongContract.SongEntry.COLUMN_NAME_FILE_HASH} TEXT,
        ${SongContract.SongEntry.COLUMN_NAME_MODIFIED_TIME} INTEGER,
        ${SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE} INTEGER DEFAULT 0,
        ${SongContract.SongEntry.COLUMN_NAME_IS_DIRTY} INTEGER DEFAULT 0,
        ${SongContract.SongEntry.COLUMN_NAME_FAV_LAST_UPDATED} INTEGER DEFAULT 0)
    ;

    CREATE TABLE IF NOT EXISTS ${PlaybackCacheContract.TABLE_NAME} (
        ${PlaybackCacheContract.CacheEntry.COLUMN_NAME_ID} INTEGER PRIMARY KEY,
        ${PlaybackCacheContract.CacheEntry.COLUMN_NAME_SONG_HASH} TEXT NOT NULL,
        ${PlaybackCacheContract.CacheEntry.COLUMN_NAME_FILE_PATH} TEXT NOT NULL,
        ${PlaybackCacheContract.CacheEntry.COLUMN_NAME_POSITION} INTEGER DEFAULT 0,
        ${PlaybackCacheContract.CacheEntry.COLUMN_NAME_LAST_PLAYED_AT} INTEGER)
    """
```

- [ ] **Step 2: Update MusicDbHelper.kt - onCreate calls new table creation**

```kotlin
override fun onCreate(db: SQLiteDatabase) {
    db.execSQL(SQL_CREATE_ENTRIES)
    db.execSQL("CREATE INDEX IF NOT EXISTS idx_playback_cache_last_played ON ${PlaybackCacheContract.TABLE_NAME}(${PlaybackCacheContract.CacheEntry.COLUMN_NAME_LAST_PLAYED_AT})")
}
```

- [ ] **Step 3: Update schema.sql**

```sql
-- songs table (existing)
CREATE TABLE IF NOT EXISTS songs (...);

-- playback_cache table
CREATE TABLE IF NOT EXISTS playback_cache (
    id INTEGER PRIMARY KEY,
    song_hash TEXT NOT NULL,
    file_path TEXT NOT NULL,
    position INTEGER DEFAULT 0,
    last_played_at INTEGER
);
```

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/com/example/synctune/library/MusicDbHelper.kt android/schema.sql
git commit -m "feat: add playback_cache table to database schema"
```

---

## Task 4: Modify PlayerManager to save position

**Files:**
- Modify: `android/app/src/main/java/com/example/synctune/player/PlayerManager.kt`

- [ ] **Step 1: Add savePosition method and field**

In `PlayerManager.kt`, add imports and a helper:

```kotlin
import com.example.synctune.library.PlaybackCacheHelper

// Add at top (after currentPlaylistPaths)
private var playbackCacheHelper: PlaybackCacheHelper? = null

// Add method after ensureServiceStarted
private fun ensureCacheHelper(context: Context) {
    if (playbackCacheHelper == null) {
        playbackCacheHelper = PlaybackCacheHelper(context)
    }
}

fun savePlaybackPosition(context: Context, songHash: String, filePath: String, position: Long) {
    ensureCacheHelper(context)
    playbackCacheHelper?.saveCache(songHash, filePath, position)
}
```

- [ ] **Step 2: Save position on play() method**

In the `play()` function, add save call after setting media items:

```kotlin
fun play(context: Context, songs: List<Song>, startIndex: Int) {
    val player = getPlayer(context)
    ensureServiceStarted(context)
    
    val newPaths = songs.map { it.filePath }

    if (currentPlaylistPaths != null && currentPlaylistPaths == newPaths) {
        val isShuffle = player.shuffleModeEnabled
        if (isShuffle) player.shuffleModeEnabled = false
        player.seekTo(startIndex, 0L)
        if (isShuffle) player.shuffleModeEnabled = true
        player.prepare()
        player.play()
    } else {
        currentPlaylistPaths = newPaths
        val mediaItems = createMediaItems(songs)
        player.setMediaItems(mediaItems, startIndex, 0L)
        player.prepare()
        player.play()
    }
    player.playWhenReady = true

    // Save playback position for current song
    if (songs.isNotEmpty() && startIndex < songs.size) {
        val currentSong = songs[startIndex]
        savePlaybackPosition(
            context,
            currentSong.fileHash,
            currentSong.filePath,
            0L
        )
    }
}
```

- [ ] **Step 3: Save position when song changes or playback stops**

Add listener setup to PlayerManager. Since PlayerManager is an object (singleton), we need to store context. Add:

```kotlin
// After exoPlayer initialization in getPlayer()
exoPlayer!!.addListener(object : Player.Listener {
    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
        // Media item changed - position will be saved by the next play() call
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        if (!isPlaying) {
            val context = exoPlayer?.let { /* need ApplicationContext */ }
            // Save position when paused/stopped - handled by PlaybackService
        }
    }
})
```

Actually, a simpler approach: Let PlaybackService handle periodic saves. Modify PlaybackService:

- [ ] **Step 4: Add periodic position saving in PlaybackService**

First read PlaybackService to understand its structure:

```kotlin
// In PlaybackService.kt, add:
// 1. Import PlaybackCacheHelper
// 2. In onCreate or as a field: playbackCacheHelper = PlaybackCacheHelper(this)
// 3. Add a Handler that saves position every 5 seconds during playback
```

```kotlin
class PlaybackService : MediaService() {
    
    private var playbackCacheHelper: PlaybackCacheHelper? = null
    private val handler = Handler(Looper.getMainLooper())
    private val savePositionRunnable = object : Runnable {
        override fun run() {
            saveCurrentPosition()
            handler.postDelayed(this, 5000) // Save every 5 seconds
        }
    }

    override fun onCreate() {
        super.onCreate()
        playbackCacheHelper = PlaybackCacheHelper(this)
    }

    private fun saveCurrentPosition() {
        val player = PlayerManager.getPlayer(this)
        if (player.mediaItemCount > 0 && player.playbackState == Player.STATE_READY) {
            val currentIndex = player.currentMediaItemIndex
            // Need to get song from playlist - simplified: use current mediaId as hash
            val currentMediaItem = player.currentMediaItem
            currentMediaItem?.let { item ->
                val songHash = item.mediaId
                val filePath = item.localConfiguration?.uri?.toString()?.removePrefix("file://") ?: return
                val position = player.currentPosition
                playbackCacheHelper?.saveCache(songHash, filePath, position)
            }
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return mediaSession
    }
    
    // Add in onStartCommand or onPlay:
    handler.post(savePositionRunnable)
    
    // Add in onPause/onDestroy:
    handler.removeCallbacks(savePositionRunnable)
    saveCurrentPosition() // Save one last time when stopping
}
```

Note: This is a simplified approach. More robust would be to pass the Song object from PlayerManager to PlaybackService, but that requires more refactoring. This approach uses the mediaId (fileHash) as the key.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/com/example/synctune/player/PlayerManager.kt
git commit -m "feat: add playback position saving to PlayerManager"
```

---

## Task 5: Modify MainActivity to restore playback on startup

**Files:**
- Modify: `android/app/src/main/java/com/example/synctune/ui/MainActivity.kt`

- [ ] **Step 1: Add imports and cache helper**

In MainActivity.kt, add imports:

```kotlin
import com.example.synctune.library.PlaybackCacheHelper
import com.example.synctune.library.Song
```

Add as a field:

```kotlin
private lateinit var playbackCacheHelper: PlaybackCacheHelper
```

In onCreate(), initialize:

```kotlin
songDao = SongDao(this)
playbackCacheHelper = PlaybackCacheHelper(this)
```

- [ ] **Step 2: Add restorePlaybackIfNeeded method**

Add method after triggerAutoSync():

```kotlin
private fun restorePlaybackIfNeeded() {
    val cache = playbackCacheHelper.getCache() ?: return
    
    // Find the cached song in database
    val songs = songDao.getSongByHash(cache.songHash)
    if (songs.isEmpty()) return
    
    val song = songs[0]
    // Seek to saved position (don't auto-play per user preference)
    val player = PlayerManager.getPlayer(this)
    val mediaItems = listOf(
        com.example.synctune.player.PlayerManager.createMediaItem(song)
    )
    player.setMediaItems(mediaItems, 0, cache.position)
    player.prepare()
    // playWhenReady is false by default - user will tap play
}
```

Wait - PlayerManager.createMediaItem is private. Need to either:
1. Make it public, OR
2. Add a public method to PlayerManager to restore from cache

- [ ] **Step 3: Add public restore method to PlayerManager**

In PlayerManager.kt, add:

```kotlin
/**
 * Restore playback from cache without starting playback.
 * Called on app launch to resume last played song.
 */
fun restoreFromCache(context: Context, song: Song, position: Long) {
    val player = getPlayer(context)
    currentPlaylistPaths = listOf(song.filePath)
    val mediaItem = createMediaItem(song)
    player.setMediaItem(mediaItem)
    player.seekTo(position)
    player.prepare()
    player.playWhenReady = false // Don't auto-play
}
```

Also make createMediaItem accessible (it's already accessible as it's in the same object).

- [ ] **Step 4: Update MainActivity to call restore**

Add to onCreate after other setup:

```kotlin
if (savedInstanceState == null) {
    loadFragment(LibraryFragment(), false)
    triggerAutoSync()
    checkIntentForNavigation(intent)
    restorePlaybackIfNeeded() // Restore last played song
}
```

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/com/example/synctune/ui/MainActivity.kt android/app/src/main/java/com/example/synctune/player/PlayerManager.kt
git commit -m "feat: restore playback cache on app launch"
```

---

## Task 6: Test and verify implementation

- [ ] **Step 1: Build the project**

```bash
cd android && ./gradlew assembleDebug
```

Expected: BUILD SUCCESSFUL

- [ ] **Step 2: Run on device/emulator**

Verify:
1. Play a song, pause after a few seconds
2. Close the app (swipe away)
3. Reopen the app
4. The mini player should show the last played song
5. Tap play - should resume from the paused position

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "test: verify playback cache functionality"
```

---

## Summary

| Task | Description |
|------|-------------|
| 1 | Create PlaybackCacheContract (table definitions) |
| 2 | Create PlaybackCacheHelper (CRUD operations) |
| 3 | Add cache table to MusicDbHelper |
| 4 | Save position in PlayerManager/PlaybackService |
| 5 | Restore playback in MainActivity on launch |
| 6 | Build and test |

---

## Notes

- Position saves every 5 seconds during playback + one final save on pause/stop
- Only the last played song is stored (as per requirements)
- App does NOT auto-play on launch (user preference)
- File path stored in cache so we can handle deleted files gracefully