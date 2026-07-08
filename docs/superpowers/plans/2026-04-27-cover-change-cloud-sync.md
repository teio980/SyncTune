# Cover Change Cloud Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every successful cover change marks the song dirty and enqueues cloud upload when sync is enabled.

**Architecture:** Keep the change localized to Android `LibraryFragment.updateSongCover`. Use the existing `CoverEditor`, `SongDao`, `SyncManager`, and `SyncWorker` pipeline; only make dirty-state persistence independent from metadata re-read success.

**Tech Stack:** Android Kotlin, coroutines, SQLite DAO, WorkManager sync trigger.

---

## File Structure

- Modify: `android/app/src/main/java/com/example/synctune/ui/library/LibraryFragment.kt`
  - Responsibility: UI flow for cover editing, persistence of updated song state, and immediate sync trigger.
- No new production files.
- No unrelated WebDAV, `SyncWorker`, schema, or desktop changes.

## Task 1: Make Cover Update Dirty Marking Reliable

**Files:**
- Modify: `android/app/src/main/java/com/example/synctune/ui/library/LibraryFragment.kt:137-163`

- [ ] **Step 1: Inspect the current cover update method**

Read `LibraryFragment.updateSongCover` and confirm it currently updates the database only inside `if (updatedSong != null)`.

Expected current shape:

```kotlin
val updatedSong = metadataReader.readMetadata(ctx, Uri.parse(s.filePath))
if (updatedSong != null) {
    val finalSong = updatedSong.copy(
        id = s.id,
        isFavourite = s.isFavourite,
        isDirty = true,
        modifiedTime = System.currentTimeMillis()
    )
    songDao.updateSong(finalSong)
}
```

- [ ] **Step 2: Replace metadata-dependent dirty marking with fallback-first logic**

In `LibraryFragment.kt`, replace the `if (result.isSuccess)` block inside `updateSongCover` with this implementation:

```kotlin
if (result.isSuccess) {
    val changedAt = System.currentTimeMillis()
    val fallbackDirtySong = s.copy(
        isDirty = true,
        modifiedTime = changedAt
    )

    val updatedSong = metadataReader.readMetadata(ctx, Uri.parse(s.filePath))
    val finalSong = updatedSong?.copy(
        id = s.id,
        isFavourite = s.isFavourite,
        isDirty = true,
        modifiedTime = changedAt,
        favLastUpdated = s.favLastUpdated
    ) ?: fallbackDirtySong

    songDao.updateSong(finalSong)

    withContext(Dispatchers.Main) {
        songAdapter.setSelectionMode(false)
        refresh()
        Toast.makeText(ctx, "Cover Updated Successfully", Toast.LENGTH_SHORT).show()
        if (syncManager.isSyncEnabled()) {
            syncManager.startImmediateSync("UPLOAD")
        }
    }
} else {
    withContext(Dispatchers.Main) {
        val error = result.exceptionOrNull()?.message ?: "Unknown error"
        Toast.makeText(ctx, "Error: $error", Toast.LENGTH_LONG).show()
    }
}
```

Why this exact code:
- `fallbackDirtySong` guarantees the existing row is marked dirty even when `MetadataReader.readMetadata` returns null.
- `changedAt` is captured once so the dirty row and refreshed metadata path share one timestamp.
- `favLastUpdated = s.favLastUpdated` preserves favourite conflict-resolution metadata when metadata re-read succeeds.
- The existing `startImmediateSync("UPLOAD")` trigger remains after `songDao.updateSong(finalSong)`.

- [ ] **Step 3: Run Kotlin diagnostics for the modified file**

Run diagnostics on:

```text
android/app/src/main/java/com/example/synctune/ui/library/LibraryFragment.kt
```

Expected: no new Kotlin errors.

- [ ] **Step 4: Build the Android app**

Run from `android`:

```powershell
.\gradlew.bat :app:assembleDebug
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Manual verification path**

On a device/emulator with WebDAV configured and sync enabled:

1. Pick one existing song.
2. Edit its cover from the library UI.
3. Confirm the success toast appears.
4. Confirm WorkManager runs `immediate_sync`.
5. Confirm `SyncWorker` uploads the changed audio file.
6. Confirm the song row is no longer dirty after upload success.

If metadata re-read is difficult to force-fail manually, validate the fallback path by temporarily making `metadataReader.readMetadata(ctx, Uri.parse(s.filePath))` return null in a local throwaway branch, changing a cover, and confirming the row is still updated from `fallbackDirtySong`. Revert that temporary local test change before committing or shipping.

## Self-Review

- Spec coverage: The plan covers the required behavior: successful cover writes always persist `isDirty = true`, update `modifiedTime`, preserve metadata when available, and enqueue `startImmediateSync("UPLOAD")` only after persistence.
- Placeholder scan: No incomplete placeholder markers are present.
- Type consistency: The plan uses existing `Song` fields (`isDirty`, `modifiedTime`, `isFavourite`, `favLastUpdated`) and existing methods (`metadataReader.readMetadata`, `songDao.updateSong`, `syncManager.startImmediateSync`).
