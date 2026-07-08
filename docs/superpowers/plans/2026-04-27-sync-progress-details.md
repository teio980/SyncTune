# Sync Progress Details Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show detailed sync status in the existing Android Sync progress card during every major WebDAV sync phase.

**Architecture:** Reuse the existing WorkManager progress channel and `SyncFragment` progress card. Add progress emissions inside `SyncWorker` only; do not change WebDAV connection setup, upload/download selection logic, or favourite merge semantics.

**Tech Stack:** Android Kotlin, WorkManager `setProgress`, `workDataOf`, Material progress card in `fragment_sync.xml`.

---

## File Structure

- Modify: `android/app/src/main/java/com/example/synctune/sync/SyncWorker.kt`
  - Responsibility: emit phase and per-file progress using the existing progress keys.
- No layout changes required in `android/app/src/main/res/layout/fragment_sync.xml`.
- No `SyncFragment.kt` changes required unless implementation discovers a display bug.
- No WebDAVHelper, SyncManager, DAO, or connection setting changes.

## Task 1: Emit Progress for SyncWorker Phases

**Files:**
- Modify: `android/app/src/main/java/com/example/synctune/sync/SyncWorker.kt:46-105`
- Reference only: `android/app/src/main/java/com/example/synctune/ui/sync/SyncFragment.kt:143-193`

- [ ] **Step 1: Write the failing static test for required progress stages**

Create `android/app/src/test/java/com/example/synctune/sync/SyncProgressDetailsTest.kt`:

```kotlin
package com.example.synctune.sync

import org.junit.Assert.assertTrue
import org.junit.Test

class SyncProgressDetailsTest {
    @Test
    fun syncWorkerDefinesUserVisibleProgressStages() {
        val stages = listOf(
            "Fetching remote metadata...",
            "Uploading...",
            "Updating remote metadata...",
            "Checking cloud files...",
            "Downloading...",
            "Syncing favourites...",
            "Sync complete"
        )

        stages.forEach { stage ->
            assertTrue("Missing stage: $stage", SyncProgressStages.ALL.contains(stage))
        }
    }
}
```

- [ ] **Step 2: Run the test and verify it fails because `SyncProgressStages` does not exist**

Run from `android` when Gradle is available:

```powershell
.\gradlew.bat :app:testDebugUnitTest --tests "com.example.synctune.sync.SyncProgressDetailsTest"
```

Expected failure:

```text
Unresolved reference: SyncProgressStages
```

If this workspace still lacks `android/gradlew.bat`, record the command as blocked and continue with static verification after implementation.

- [ ] **Step 3: Add progress stage constants**

Create `android/app/src/main/java/com/example/synctune/sync/SyncProgressStages.kt`:

```kotlin
package com.example.synctune.sync

object SyncProgressStages {
    const val FETCHING_REMOTE_METADATA = "Fetching remote metadata..."
    const val UPLOADING = "Uploading..."
    const val UPDATING_REMOTE_METADATA = "Updating remote metadata..."
    const val CHECKING_CLOUD_FILES = "Checking cloud files..."
    const val DOWNLOADING = "Downloading..."
    const val SYNCING_FAVOURITES = "Syncing favourites..."
    const val SYNC_COMPLETE = "Sync complete"

    val ALL = listOf(
        FETCHING_REMOTE_METADATA,
        UPLOADING,
        UPDATING_REMOTE_METADATA,
        CHECKING_CLOUD_FILES,
        DOWNLOADING,
        SYNCING_FAVOURITES,
        SYNC_COMPLETE
    )
}
```

- [ ] **Step 4: Emit phase progress around existing SyncWorker operations**

In `android/app/src/main/java/com/example/synctune/sync/SyncWorker.kt`, update only progress calls inside `doWork()`.

Replace the beginning of the `try` block with:

```kotlin
try {
    updateProgress(SyncProgressStages.FETCHING_REMOTE_METADATA, "", 0, 0, "0", "0")
    val remoteMetadata = fetchRemoteMetadata(webDAV)

    val allSongs = songDao.getAllSongsSorted()
    val dirtySongs = allSongs.filter { song ->
        song.isDirty || song.modifiedTime > remoteMetadata.optLong(song.fileName, 0L)
    }

    dirtySongs.forEachIndexed { index, song ->
        DocumentFile.fromSingleUri(applicationContext, Uri.parse(song.filePath))?.let { file ->
            val totalSizeMb = String.format(Locale.US, "%.1f", file.length() / (1024.0 * 1024.0))
            updateProgress(
                SyncProgressStages.UPLOADING,
                song.fileName,
                index + 1,
                dirtySongs.size,
                totalSizeMb,
                totalSizeMb
            )
            if (webDAV.uploadFile(applicationContext, file).isSuccess) {
                val serverTime = System.currentTimeMillis()
                songDao.updateSong(song.copy(isDirty = false, modifiedTime = serverTime))
                remoteMetadata.put(song.fileName, serverTime)
            }
        }
    }
    if (dirtySongs.isNotEmpty()) {
        updateProgress(SyncProgressStages.UPDATING_REMOTE_METADATA, "", 1, 1, "0", "0")
        uploadRemoteMetadata(webDAV, remoteMetadata)
    }

    updateProgress(SyncProgressStages.CHECKING_CLOUD_FILES, "", 0, 0, "0", "0")
    val remoteResult = webDAV.listRemoteFiles()
```

Then update the existing download progress call from:

```kotlin
updateProgress("Downloading...", remote.name, index+1, toDownload.size, currentMb, totalSizeMb)
```

to:

```kotlin
updateProgress(SyncProgressStages.DOWNLOADING, remote.name, index + 1, toDownload.size, currentMb, totalSizeMb)
```

Before `syncFavouritesWithLWW(webDAV)`, add:

```kotlin
updateProgress(SyncProgressStages.SYNCING_FAVOURITES, "", 1, 1, "0", "0")
```

Before `applicationContext.sendBroadcast(Intent(ACTION_SYNC_COMPLETED))`, add:

```kotlin
updateProgress(SyncProgressStages.SYNC_COMPLETE, "", 1, 1, "0", "0")
```

Do not alter the upload predicate, download predicate, WebDAV helper calls, favourite merge code, or metadata file names.

- [ ] **Step 5: Run the targeted test and build**

Run from `android` when Gradle is available:

```powershell
.\gradlew.bat :app:testDebugUnitTest --tests "com.example.synctune.sync.SyncProgressDetailsTest"
.\gradlew.bat :app:assembleDebug
```

Expected:

```text
BUILD SUCCESSFUL
```

If Gradle remains unavailable in this workspace, run static verification instead:

```powershell
git diff --check -- android/app/src/main/java/com/example/synctune/sync/SyncWorker.kt android/app/src/main/java/com/example/synctune/sync/SyncProgressStages.kt android/app/src/test/java/com/example/synctune/sync/SyncProgressDetailsTest.kt
```

Expected: no whitespace errors.

- [ ] **Step 6: Static acceptance checks**

Search changed source for these exact strings:

```text
Fetching remote metadata...
Uploading...
Updating remote metadata...
Checking cloud files...
Downloading...
Syncing favourites...
Sync complete
```

Expected: all strings exist in `SyncProgressStages.kt`; `SyncWorker.kt` references `SyncProgressStages` for progress calls.

Also confirm these strings remain unchanged in `SyncFragment.kt`:

```text
step_message
file_name
current
total
current_size
total_size
```

Expected: `SyncFragment` still reads the same progress keys.

## Self-Review

- Spec coverage: The plan adds progress for metadata, upload, remote metadata update, cloud listing, download, favourites, and completion while reusing the existing card.
- Placeholder scan: No incomplete placeholder markers are present.
- Type consistency: `SyncProgressStages` is an object in the `com.example.synctune.sync` package, directly usable by `SyncWorker` and the unit test without extra imports.
