# macOS development and verification

## Toolchain

Use Flutter 3.47.6 with Dart 3.13.5 and full Xcode with its first-launch components installed. The Command Line Tools package alone cannot build the Flutter macOS runner. The deployment target is macOS 12.0; Release builds contain both Apple Silicon (`arm64`) and Intel (`x86_64`) code.

If Xcode lives outside the selected developer directory, set it for the current shell without changing the machine-wide selection:

```sh
export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer
export PATH=/path/to/flutter/bin:$PATH
xcodebuild -version
xcodebuild -checkFirstLaunchStatus
flutter doctor -v
flutter pub get
flutter run -d macos
```

The runner uses Flutter's Swift Package Manager integration. No CocoaPods plugins are required by the current dependency set. Keep `macos/Flutter/ephemeral` and Xcode build products out of source control.

## System integration

The `synctune/sync_platform` method channel implements `pickFolder`, `stateDatabasePath`, `credentialRead`, `credentialExists`, `credentialWrite`, `credentialDelete`, and `allowWindowClose`. Folder selection returns an absolute filesystem `locator`, the same path as `stableId`, and `macos-folder-v2` as `generation`; cancellation returns null. The picker resolves aliases and links at the selected root. Shared Dart code checks symlinks beneath that root and does not call Windows' `isReparsePoint` method on macOS.

The SQLite schema is shared with the other platforms. On macOS, the sqlite3 hook compiles the vendored SQLite 3.53.4 source for macOS 12: the package's default macOS prebuilt library requires macOS 13. Other platforms retain the package's precompiled libraries. See [SQLite source provenance](../third_party/sqlite3/README.md). Its database is `~/Library/Application Support/SyncTune/synctune-state-v2.sqlite`. Passwords are generic Keychain items with service `SyncTune.WebDAV.v2` and the existing SHA-256 credential identity as account; they are not synchronized through iCloud or written to SQLite. The app is non-sandboxed in Debug, Profile, and Release. HTTPS validation and the existing synchronization rules remain in the shared Dart client.

Both the window close button and Cmd+Q enter the AppKit termination delegate. Repeated requests share one pending handshake. Dart cancels the controller and waits for its active work and execution-host cleanup before acknowledging `allowWindowClose`. Native code defers termination until that acknowledgement. A channel error keeps the app open and permits retry. If no Dart controller is registered during startup or on the startup-error screen, a not-implemented reply allows quitting immediately.

## Automated checks

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build macos --debug
xcodebuild test -project macos/Runner.xcodeproj -scheme Runner \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/macos-tests CODE_SIGN_IDENTITY=-
scripts/package_macos.sh
```

The Dart tests cover platform callback ordering, duplicate close requests, retry after acknowledgement failure, picker cancellation, missing credentials, native failures, Unicode/space paths, settings persistence, symlinks, and Windows-only reparse checks. Existing engine tests exercise two-way transfers, conflict copies, deletion propagation, checkpoints, partial staging, and recovery. Native XCTest cases cover the channel results, folder and Application Support paths, failed system calls, the quit state machine, reply-before-exit ordering, and a real Keychain create/read/update/delete cycle using a disposable random account.

The package script checks the app's minimum OS and each native binary's deployment target, non-sandboxed entitlements, signature, and both architectures in the runner, Flutter frameworks, and bundled SQLite library. It opens and closes an in-memory database using the packaged SQLite library before producing the ZIP. If an ARM-only Flutter setting is enabled, reset it with `flutter config --no-enable-macos-arm64-only` before packaging.

`.github/workflows/verify.yml` preserves the Windows checks and runs the checks above on macOS, uploading the ZIP as a workflow artifact. A local run does not itself trigger or confirm a hosted GitHub Actions run.

## Interactive acceptance checks

Use a disposable music folder and WebDAV collection for these checks; avoid a production library when testing deletion or conflict behavior.

1. Select a folder containing Chinese characters and spaces, then cancel a second picker and confirm the previous selection remains.
2. Save settings and a password, quit, reopen, and confirm settings and Keychain access persist.
3. Put one distinct song on each side and sync; confirm both songs exist locally and remotely.
4. Edit the same song differently on both sides; sync and confirm both versions survive, including a conflict copy on each side.
5. Delete a previously synchronized song locally, sync, and confirm remote deletion. Repeat starting with a remote deletion.
6. Cancel a large transfer, restart sync, and confirm recovery completes without corrupted audio or lost recovery copies.
7. During a large transfer, close the window; repeat with Cmd+Q and repeated quit requests. Confirm the process exits only after cancellation. Reopen and resume.
8. Launch the extracted Release app on Apple Silicon and Intel Macs running a supported macOS version. Confirm startup initializes SQLite without an external library installation.

The local ad-hoc build is intended for direct development and local use. Distribution through Developer ID, notarization, or the Mac App Store requires a separate signing and release workflow.

## Local verification record (2026-11-08)

- Flutter 3.47.6 / Dart 3.13.5, Xcode 27.1, Apple Silicon, macOS 27.0.1.
- Dart analysis: passed. Dart tests: 57 passed, including the shared WebDAV engine tests against loopback fixtures.
- Native XCTest: 8 passed, including real Keychain read/write/update/delete.
- Debug and universal Release builds: passed. Release interface and native folder picker observed on this Mac.
- ZIP extracted into a separate directory: signature, minimum OS, non-sandboxed configuration, all required architecture slices, and bundled SQLite database creation verified again.
- Hosted GitHub Actions has been configured but not triggered from this local checkout. Intel hardware, macOS 12 hardware, and interactive tests against an external HTTPS WebDAV server have not been exercised here; use the acceptance checks above for those environments.
