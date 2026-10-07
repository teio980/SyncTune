# SyncTune

SyncTune is a Flutter desktop/mobile music-file synchronization tool. It has a
pure Dart synchronization kernel in [`packages/sync_core`](packages/sync_core),
with Flutter UI, Drift persistence, Dio/XML WebDAV transport, Android SAF and
Windows AppContainer adapters kept behind ports.

The root application now opens the Chinese music, sync, and settings shell.
Its platform diagnostic route remains available for the AppContainer gate.
Music scanning accepts only an opaque broker root token and generation, then
returns normalized relative paths from the native SAF/FAL bridge; Dart does
not traverse user directories directly. Business synchronization remains
disabled until the complete runtime gate is accepted.

Current validation status:

- Flutter 3.47.6 / Dart 3.13.5 are available from the workspace SDK. The latest
  recorded core analysis is clean and its 32 tests pass. The final Flutter
  analysis is clean and the full Flutter suite passes 112 tests. The formal
  WebDAV recovery suite passes 13 cases; targeted app/runtime/settings/UI and
  settings race/atomicity checks pass 39 tests, and the desktop 48px audit passes.
  Cloud CI has not run.
- Final build logs report exit 0 for the Android Release APK, Windows Release
  executable, and unsigned MSIX package. These are build/package results only;
  none was installed or run in this audit. The final evidence is recorded in
  `build/review/resumed-final-android-build.log`,
  `resumed-final-windows-build.log`, and `resumed-final-msix-build.log`.
- Drift, WebDAV, composition, and UI review coverage exists in the repository,
  and the current Flutter test suite passes. This does not establish production
  CAS/gate acceptance or platform runtime behavior. No application, emulator, or
  device was started or installed in this audit; no package installation,
  certificate change, or system setting change was performed.
- Business synchronization remains disabled until real platform CAS evidence,
  native capability checks, runtime evidence, and WebDAV PROPFIND/compatibility
  checks all pass. Android conditional create/replace/delete and Windows
  conditional replace/delete remain unsupported in the current provider paths.
  Windows AppContainer runtime evidence, physical Android SAF verification, an
  external WebDAV service, and ordinary WebDAV adoption/reconcile UI remain
  outstanding. The composition recovery post-await target identity guard is now
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

