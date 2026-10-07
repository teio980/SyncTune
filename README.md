# SyncTune

SyncTune is a Flutter desktop/mobile music-file synchronization tool. It has a
pure Dart synchronization kernel in [`packages/sync_core`](packages/sync_core),
with Flutter UI, Drift persistence, Dio/XML WebDAV transport, Android SAF and
Windows AppContainer adapters kept behind ports.

The root application opens the English music, sync, and settings shell.
Settings includes a language selector for English (default) and Simplified
Chinese. Changes apply immediately, and the private database saves the choice
for the next launch. Labels and existing status messages follow the selected
language; user folder paths and music filenames remain unchanged.
Its platform diagnostic route remains available for the AppContainer gate.
Music scanning accepts only an opaque broker root token and generation, then
returns normalized relative paths from the native SAF/FAL bridge; Dart does
not traverse user directories directly. Business synchronization remains
disabled until the complete runtime gate is accepted.

Current validation status:

- Flutter 3.47.6 / Dart 3.13.5 are available from the workspace SDK. The latest
  recorded core analysis is clean and its 32 tests pass. The final Flutter
  analysis is clean and the full Flutter suite passes 148 tests. The formal
  WebDAV recovery suite passes 13 cases; targeted app/runtime/settings/UI and
  settings race/atomicity checks pass 39 tests, and the desktop 48px audit passes.
  Cloud CI has not run.
- Final build logs report exit 0 for the Android Release APK, Windows Release
  executable, and unsigned MSIX package. These are build/package results only;
  none was installed or run in this audit. The final evidence is recorded in
  `build/review/resumed-final-android-build.log`,
  `resumed-final-windows-build.log`, and `resumed-final-msix-build.log`.
- The Android Debug build issue reported on 2026-10-07 was reproduced with
  `C:\Users\Owner\Documents\teiocode\flutter-sdk\bin\flutter.bat build apk
  --debug --no-pub`. The first errors were hosted package reads reported as
  `../../../AppData/Local/Pub/Cache/...` (the files and package configuration
  were present); the later `Matrix4`, `Vector3`, and `clock` errors were
  downstream symptoms. `flutter pub get --offline` did not change the lock
  file or package configuration, and no SDK or Pub cache files were edited.
  The existing stale Gradle daemon was stopped with
  `android\gradlew.bat --stop`; the same Flutter command then succeeded in
  56.1 seconds. A direct full `:app:assembleDebug --offline --console=plain
  --no-daemon` run also succeeded in 1m37s, with
  `:app:compileFlutterBuildDebug` executed (55 tasks: 23 executed, 32
  up-to-date). Recovery and failure evidence is in
  `build/review/android-debug-repro.log`,
  `android-gradle-debug-no-daemon.log`,
  `android-debug-after-daemon-stop.log`, and `android-gradle-stop.log`.
  This identifies stale Gradle process state as the observed trigger; the
  exact operating-system reason for that process state was not established.
- The resulting Debug APK is at
  `build/app/outputs/flutter-apk/app-debug.apk` (SHA-256
  `9CCBB85945CED9E261A2D898700A51C3B5045CDAA969064BD03E2BF0F251C108`).
  `aapt2 dump badging` reports package `com.example.synctune`, version
  `1.0.0`, `minSdkVersion:24`, and `targetSdkVersion:36`; `apksigner verify`
  passes with APK Signature Scheme v2. The APK was not installed or launched.
- The earlier static validation snapshot rebuilt the Windows executable and
  produced a signed MSIX with the existing CurrentUser development
  certificate, but did not install or launch it. Its signed package SHA-256
  was `3AC2EEA83AB798345C452159D99DC3311ADB8650A88DD5F88232E7095C5C002A`.
  The later installed-package revalidation is recorded under **Latest Windows
  gate evidence** below; remote WebDAV compatibility and end-to-end sync are
  still unverified.
- This round's commands and results were: `flutter test --no-pub` (`+148 All
  tests passed`), `flutter build windows --release --no-pub` (Windows Release
  build succeeded in 136 seconds), and, from `android`,
  `gradlew.bat app:compileReleaseKotlin --offline -x
  app:compileFlutterBuildRelease` (BUILD SUCCESSFUL in 46 seconds). The
  independent supervision run recorded `dart analyze --fatal-infos` with no
  issues and 29 targeted tests in
  `build/review/supervisor-runtime-gate-analysis.log` and
  `build/review/supervisor-runtime-gate-tests.log`; `git diff --check` also
  passed.
- Drift, WebDAV, composition, and UI review coverage exists in the repository,
  and the current Flutter test suite passes. This does not establish production
  CAS/gate acceptance or platform runtime behavior. The installed-package
  results below are limited to the explicitly listed diagnostic runs; no
  certificate import or system setting change was performed.
- Business synchronization remains disabled until real platform CAS evidence,
  native capability checks, runtime evidence, and WebDAV PROPFIND/compatibility
  checks all pass. Android conditional create/replace/delete and Windows
  conditional replace/delete remain unsupported in the current provider paths.
  The earlier static review did not include Windows AppContainer runtime
  evidence; physical Android SAF verification, an external WebDAV service, and
  ordinary WebDAV adoption/reconcile UI also remained outstanding at that
  snapshot. The composition recovery post-await target identity guard is now
  implemented and covered by root, namespace, and credential-epoch switch tests.

Run the core checks from the package directory with the Dart SDK configured by
the workspace:

```powershell
Push-Location packages\sync_core
C:\Users\Owner\Documents\teiocode\flutter-sdk\bin\cache\dart-sdk\bin\dart.exe analyze --fatal-infos
C:\Users\Owner\Documents\teiocode\flutter-sdk\bin\cache\dart-sdk\bin\dart.exe test
Pop-Location
```

The project never stores user music, remote credentials, signing private keys,
or SDK archives. Legacy Git history remains in `.git`; rebuilt source files are
uncommitted, review artifacts under `build/` are ignored, and cloud CI has not
run. Git history cleanup remains outstanding.

## Latest Windows gate evidence

The signed `SyncTune.Probe` 1.0.0.17 MSIX was installed and launched twice
from the standard AppsFolder path. Authenticode was `Valid` for `CN=SyncTune
Development` (thumbprint `084197F208644E47E54CC8F77A5B0D5D6382F766`); the
package SHA-256 is
`10A20691822AE413373E4B0AA1C8A6017C538F417E1DE24BD8F4C94134CA9569`.
PIDs `22304` and `20672` both produced complete private evidence with
`appContainer=true`, broker capabilities `ok`, WinRT HTTPS HTTP 200, and
PasswordVault/restart `ok`. The recorded transport is
`winrt_http_client`; Android retains the `dart_io_http_client` branch with
bounded waits. Production Dio/WebDAV was not validated by this probe.

Both Windows runs still report SQLite native asset loading failed, and no
FolderPicker/FutureAccessList marker exists. Therefore the production
synchronization gate remains closed; CAS, WebDAV compatibility, and dual-end
end-to-end synchronization are incomplete. Build and packaging transcripts
are `build/gate/winrt-https-stable-windows-build.log` and
`build/gate/winrt-https-stable-package.log`.

The follow-up package 1.0.0.20 restored a package-local SQLite preload and
was installed and launched once. Its complete PID 5344 record reports SQLite
private-file/restart `passed`, WinRT HTTPS HTTP 200 with `timedOut=false`, and
PasswordVault/restart `ok`; folder restore remains `none`. The production gate
deliberately rejects the WinRT transport because production Dio uses
`dart_io_http_client`. CAS, WebDAV compatibility, and dual-platform
end-to-end sync remain blocked. The prepared empty folder for manual
FolderPicker evidence is
`C:\Users\Owner\Documents\teiocode\SyncTune\build\gate\runtime-root-3505c583f40e4ebb8f995bbe6b95e430`.

## Windows WebDAV adapter delivery

The current source routes Windows production Dio and the connection checker
through `WindowsWinRtHttpAdapter`, and records the production evidence transport
as `dio_winrt_http`. Android keeps its `dart_io_http_client` path. The adapter
supports arbitrary WebDAV methods, request and response headers, explicit
`followRedirects`/`maxRedirects`, HTTPS same-origin redirect checks, bounded
64 KiB response and upload chunks, cancellation during staging/open/read, and
content-hash-verified request staging under the authorized root's
`.synctune-local` area. Small connection checks without an authorized root use
an app-private temporary file.

The targeted adapter and composition tests pass `+30`. The final Windows
release build was run with `flutter build windows --release --no-pub`; the
signed package is
`build/msix/SyncTuneProbe.msix`, identity `SyncTune.Probe` 1.0.0.22,
Authenticode `Valid` for `CN=SyncTune Development`, and SHA-256
`5FF234ADC0FE2E287E4018FEDDDF5E7721E9767EB008E6EE5DEDAACD1B777888`.
This package was not installed or launched in this round; production WebDAV
and end-to-end synchronization still require the user's functional test.


## Current formal sync implementation (2026-10-07)

The formal runtime no longer requires the Windows-only persisted diagnostic evidence gate. Each run still requires the active root token and generation, SQLite and credential services, a complete local scan, and a real WebDAV compatibility probe with strong ETag support. Android uses its SAF broker and Windows uses its AppContainer broker; neither is treated as a generic atomic CAS provider.

Local mutations now use the conservative recovery contract exposed by both brokers: verify the expected SHA-256, persist a staged journal record, move the old object into the root-scoped `.synctune-local` area under a stable operation key, publish and hash-check the new object, and keep a recoverable delete backup. A restart consumes unfinished local journal records before scanning; unknown bytes or simultaneous backup and target files remain visible and return `NeedsRescan`. The capability names are `verified_create_recovery`, `verified_backup_replace`, and `verified_backup_delete`; they do not claim provider-level atomic CAS.

New installs default to English, with Simplified Chinese available in Settings. An explicitly saved language choice is restored on the next launch. The final artifacts for this round are built but were not installed, launched, or tested against a user's WebDAV service.

## Final static delivery (2026-10-07)

The final artifacts are in `dist/`:

- `SyncTune-Android-1.0.0+2.apk` — Release APK, `versionCode=2`, SHA-256 `D931DBE3A0EEE2BF2D21E0067F7013831FD77A56F49F029E629FACC5F198EF4E`.
- `SyncTune-Windows-1.0.0.22.msix` — signed `SyncTune.Pro` MSIX, SHA-256 `5FF234ADC0FE2E287E4018FEDDDF5E7721E9767EB008E6EE5DEDAACD1B777888`, Authenticode `Valid`, signer `CN=SyncTune Development`, thumbprint `084197F208644E47E54CC8F77A5B0D5D6382F766`.

The APK was built with `flutter build apk --release --no-pub` and verified with Android APK Signature Scheme v2. The MSIX was built with `flutter build windows --release --no-pub` and `tools/package-msix.ps1 -Sign -CertificateThumbprint ...`. Neither package was installed or launched in this round.

## Android live sync fix (2026-10-07)

`dist/SyncTune-Android-1.0.0+3.apk` supersedes the Android +2 delivery. Running snapshots now take precedence over stale readiness checks. Run-scoped telemetry reports scan, hash, planning, upload/download, and final confirmation stages, current relative file, processed bytes and counts, and elapsed time. Rechecks are disabled during a run; failures retain the last stage and file. Byte progress describes file processing, not final sync confirmation. Native SAF reads now keep a scoped sequential stream instead of reopening and traversing the document for every 64 KiB chunk; handles close at EOF and when the consumer cancels.

Validation: Flutter application tests (+180), core tests (+35), application/core analysis, Release APK build, APK signature verification, and matching +2/+3 signing certificates. Package identity is `com.example.synctune`, version code 3. SHA-256: `34A7AAD936BD7CBA25DA4F516988DA073A441C399D6C0391B65AF02495A9CBE7`. No Android device was connected to ADB, so the user's actual folder/provider and WebDAV sync have not been verified on a device. The existing Windows package has not been rebuilt for this fix.
