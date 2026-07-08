# Sync Progress Details Design

## Problem

The Sync screen already has a progress card, but full WebDAV sync only emits detailed WorkManager progress during downloads. Users need to see what sync is doing while it runs: metadata checks, uploads, downloads, remote metadata updates, favourite sync, and completion.

## Goal

When the user starts Sync Now, the existing progress card should show clear, live sync details for each phase without changing WebDAV connection setup or the bidirectional sync rules.

## Current UI

`SyncFragment` already binds these views from `fragment_sync.xml`:

- `card_progress`
- `tv_progress_status`
- `tv_progress_file`
- `progress_bar`
- `tv_progress_count`
- `tv_progress_size`

`SyncFragment.observeSyncProgress` already reads these WorkManager progress keys:

- `step_message`
- `file_name`
- `current`
- `total`
- `current_size`
- `total_size`

## Current Worker Behavior

`SyncWorker.updateProgress(...)` already emits the right shape of progress data. The gap is that `SyncWorker` only calls it during the download loop. Other phases do useful work but do not emit progress updates.

## Proposed Behavior

Keep the current progress card and progress key format. Add progress events to the existing sync phases:

1. `Fetching remote metadata...`
   - Indeterminate progress.
   - Empty file name.
2. `Uploading...`
   - Determinate count: current dirty file / total dirty files.
   - Current file name.
   - Size text based on local file length when available.
3. `Updating remote metadata...`
   - Indeterminate or single-step progress.
   - Empty file name.
4. `Checking cloud files...`
   - Indeterminate progress while listing remote files.
5. `Downloading...`
   - Preserve existing per-file download progress.
6. `Syncing favourites...`
   - Indeterminate or single-step progress.
   - Empty file name.
7. `Sync complete`
   - Final progress update before success broadcast.

## Scope

In scope:

- Add progress emissions inside `SyncWorker`.
- Reuse `SyncFragment`'s existing progress UI.
- Optionally add small string resources for stage names if needed.

Out of scope:

- New Sync Details page.
- RecyclerView per-file history.
- WebDAV connection changes.
- Upload/download decision logic changes.
- Favourite merge logic changes.
- Cloud deletion behavior changes.

## Data Flow

```text
Sync Now
  -> SyncManager.startSyncNow()
  -> WorkManager starts SyncWorker
  -> SyncWorker emits progress at each phase
  -> SyncFragment observes WorkInfo progress
  -> Existing progress card displays phase, file, count, and size
```

## Error Handling

- If a phase fails and the worker returns failure, keep the existing failed toast behavior.
- Do not add per-file failure recovery in this change.
- If a count or file size is unknown, emit `total = 0` or `total_size = "0"` so the existing UI shows an indeterminate progress bar.

## Testing and Verification

- Add or update unit-level tests only where practical in this environment.
- Verify with static search that progress keys remain consistent between worker and fragment.
- Verify Android build/test locally when Gradle is available:
  - `./gradlew :app:testDebugUnitTest`
  - `./gradlew :app:assembleDebug`

## Acceptance Criteria

- Sync Now shows visible status for metadata, upload, download, favourite sync, and completion phases.
- Upload phase shows the current filename and file count.
- Download phase keeps existing file progress behavior.
- Sync UI remains on the existing progress card.
- WebDAV helper connection setup is unchanged.
- SyncWorker upload/download/favourite semantics are unchanged except for additional progress events.
