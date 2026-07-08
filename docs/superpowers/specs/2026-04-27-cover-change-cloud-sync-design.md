# Cover Change Cloud Sync Design

## Problem

Changing a song cover should automatically re-upload the changed audio file to cloud storage. The current Android flow attempts to do this from `LibraryFragment.updateSongCover`, but the dirty marking is tied to successfully re-reading metadata after the cover write. If metadata re-read fails, the cover can be written locally without reliably marking the song dirty for upload.

## Goal

After a cover write succeeds, SyncTune must always mark that song as requiring upload and enqueue an immediate cloud sync when sync is enabled.

## Current Flow

1. `LibraryFragment.startCoverEdit` launches the image picker.
2. `LibraryFragment.updateSongCover` calls `CoverEditor.updateCover`.
3. `CoverEditor.updateCover` writes artwork into the audio file through a temporary-file write-back flow.
4. `LibraryFragment.updateSongCover` re-reads metadata using `MetadataReader.readMetadata`.
5. Only if metadata re-read succeeds does it call `songDao.updateSong(finalSong)` with `isDirty = true`.
6. The UI thread calls `syncManager.startImmediateSync("UPLOAD")` when sync is enabled.

## Proposed Behavior

Treat successful cover writing as the source of truth for upload eligibility.

After `CoverEditor.updateCover` returns success:

1. Build a fallback dirty song from the original `Song` immediately:
   - preserve `id`, `filePath`, `fileName`, `fileHash`, favourite state, and favourite timestamp;
   - set `isDirty = true`;
   - set `modifiedTime = System.currentTimeMillis()`.
2. Attempt metadata re-read.
3. If metadata re-read succeeds, merge refreshed title/artist/album/hash/path/name with the preserved identity and dirty fields.
4. If metadata re-read fails, persist the fallback dirty song so sync still sees the file as changed.
5. If sync is enabled, enqueue `syncManager.startImmediateSync("UPLOAD")` after the database update.

## Files to Change

- `android/app/src/main/java/com/example/synctune/ui/library/LibraryFragment.kt`
  - Update `updateSongCover` so dirty marking does not depend on `MetadataReader.readMetadata` returning non-null.
  - Keep the existing `SyncManager.startImmediateSync("UPLOAD")` trigger, but make sure it runs after the dirty state is persisted.

## Data Flow

```text
User selects cover
  -> LibraryFragment.updateSongCover
  -> CoverEditor.updateCover writes artwork to file
  -> LibraryFragment persists dirty Song row regardless of metadata re-read result
  -> SyncManager.startImmediateSync("UPLOAD") enqueues SyncWorker
  -> SyncWorker uploads songs where isDirty = true
  -> SyncWorker clears isDirty after upload success
```

## Error Handling

- If cover writing fails, keep current behavior: show an error and do not enqueue upload.
- If metadata re-read fails after cover writing succeeds, show success for cover update and still enqueue upload using the fallback dirty row.
- If sync is disabled or WebDAV is not configured, do not enqueue immediate sync; the song remains dirty for the next sync-enabled run.

## Testing

Manual and build validation:

1. Change a cover with sync enabled and WebDAV configured; verify the row becomes `isDirty = true` before upload.
2. Verify `SyncWorker` uploads the changed file and clears `isDirty` after success.
3. Simulate metadata re-read failure and verify dirty marking still happens.
4. Run Android compilation/type checks for the modified module.

## Scope

This design only changes the Android cover-update trigger path. It does not alter WebDAV upload behavior, cloud metadata reconciliation, Google Drive support, desktop behavior, or favourite syncing.
