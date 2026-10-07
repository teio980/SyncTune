# SyncTune Plan Conformance Audit (Final Review)

Date: 2026-10-07

This review covered `lib/app/`, `lib/infrastructure/composition/`,
`lib/infrastructure/runtime/`, `lib/main.dart`, and their formal tests. This
review handled app/composition and runtime-evidence fixes; the root chat independently supplied
the final core/data/platform test and build evidence. Verification was limited
to files, tests, and local build/package checks: no current MSIX was installed
or launched, and no certificate import, system trust change, or external
message was performed.

## Requirements Met or Supported by Implementation Evidence

- The app layer is split into shell, music, sync, settings, and ViewModel
  modules. The Material 3 theme uses the `#4F46E5` seed and supports light,
  dark, and system modes, with system as the default.
- Shared spacing, corner radius, and minimum interaction size tokens are
  centralized. The theme explicitly provides 48px hit targets for FilledButton,
  OutlinedButton, TextButton, and IconButton. Formal widget regressions cover
  Windows and Android target platforms, 200% text scaling, and layouts at
  320/599/600/999/1000px.
- Production composition binds a real Drift database, catalog UUIDs,
  favorites Lamport/device state, WebDAV client leases, a credential broker,
  PlanStore, JournalStore, and the baseline.
- WebDAV passwords are written only to the platform credential broker. The
  database stores nonsecret fields, a versioned credential pointer, and epochs.
  A failed save preserves the previous pointer and secret.
- A slow `load()` cannot overwrite a newer save with an old namespace or
  credential epoch. An explicitly empty pointer no longer falls back to a
  legacy secret. Formal composition tests cover both cases.
- The configured client fails closed after credentials are explicitly cleared;
  legacy records with a missing pointer can still recover. Each actual database
  commit in a queued save publishes its corresponding namespace/credential
  epoch. A later failed save cannot hide an already durable configuration.
  The composition remote wrapper forwards `RemotePlanRecovery`, checking root,
  generation, namespace, and credential epoch both before and after recovery
  awaits. Formal regressions reject stale recovery when those three target
  categories change during a delayed remote request.
- Credential cleanup failure does not roll back a committed database pointer.
  The settings warning port displays a cleanup warning explaining that the
  current settings remain active.
- Root, configuration epoch, and credential epoch participate in runtime target
  identity. Changes cancel the previous run. The runtime supports startup,
  resume, manual, retry, and foreground scheduling every 15 minutes. Manual
  requests are combined without overlapping runs, and disposal waits for
  in-flight runs and checks to finish.
- Composition passes initialization errors to the shell, which displays them
  at the top of the interface. Database or sync service initialization failures
  therefore produce a visible explanation for the disabled state.
- The core/data work completed the recovery helper, favorite-stall path, and
  formal WebDAV recovery. All 13 fault recovery cases in
  `test/webdav_recovery_test.dart` passed.

## Outstanding Requirements

- The production sync gate remains closed by default. It opens only after real
  runtime evidence, native capabilities, and WebDAV PROPFIND/probes all pass.
  This review did not unlock production using an injected fake gate.
- The production composition now injects `PersistedRuntimeEvidenceGate` by
  default. It reads same-package evidence, binds folder marker/token/generation
  to the active root, checks the live `restoreFolder` and `brokerCapabilities`
  responses, and rejects a changed root during asynchronous verification. The
  startup probe runs automatically with a single-flight guard; its evidence
  may be reused across launches for the same root after a restart has already
  been proven. This remains a local evidence gate and does not evaluate remote
  WebDAV compatibility by itself.
- Android conditional create/replace/delete still report an unsupported SAF
  provider. Windows conditional replace/delete still report an unsupported
  AppContainer provider. Capability strings or a single PROPFIND result cannot
  establish availability.
- Real Windows AppContainer runtime evidence remains unverified. This review
  did not launch an app or device for another check. The Android APK, Windows
  Release executable, and unsigned MSIX were only built or packaged, without
  installation or execution, so they do not establish platform runtime
  acceptance.
- This round rebuilt the Windows executable and created a signed MSIX with the
  existing CurrentUser development certificate (thumbprint
  `084197F208644E47E54CC8F77A5B0D5D6382F766`; SHA-256
  `3AC2EEA83AB798345C452159D99DC3311ADB8650A88DD5F88232E7095C5C002A`.
  Signature verification passed;
  the package was not installed or launched, and no certificate or system
  trust store was changed. `tools/verify-runtime-evidence.ps1` was run against
  the installed package's LocalState and returned `blocked` because no startup
  evidence files exist. The script reports local evidence separately and keeps
  remote compatibility and end-to-end synchronization unverified.
- The user workflow for adopting or reconciling ordinary external WebDAV files
  remains incomplete. The current adapter requires SyncTune identity metadata;
  background scans do not implicitly adopt unauthorized ordinary files.

## Verification During This Review

The historical final supervision logs recorded `No issues found!` in
`build/review/resumed-final-flutter-analysis.log`, `+112 All tests passed!` in
`build/review/resumed-final-flutter-tests.log`, no issues in
`build/review/resumed-final-core-analysis.log`, and `+32 All tests passed!` in
`build/review/resumed-final-core-tests.log`. The independent formal regression
in `test/webdav_recovery_test.dart` recorded `+13 All tests passed!`. The targeted
composition/runtime/settings/UI and race/atomicity group, including the new
post-await guard cases, recorded `+39 All tests passed!`. The desktop Windows
48px audit recorded `+1`.

The current full Flutter run supersedes the historical `+112` count with
`+148 All tests passed`. The independent current supervision run recorded
clean analysis and 29 targeted tests in
`build/review/supervisor-runtime-gate-analysis.log` and
`build/review/supervisor-runtime-gate-tests.log`.

Platform build logs also completed with exit code 0:

- `build/review/resumed-final-android-build.log` produced a 56.4MB Release APK.
- `build/review/resumed-final-windows-build.log` produced the Windows Release
  executable.
- `build/review/resumed-final-msix-build.log` produced an unsigned MSIX.

These three results establish build/package success only. There is no
installation or execution evidence from this review. No app, emulator, or
device was launched, and cloud CI has not run.

The current validation round also ran `flutter test --no-pub` with `+148 All
tests passed`, `flutter build windows --release --no-pub` with a successful
Windows Release build in 136 seconds, and (from `android`)
`gradlew.bat app:compileReleaseKotlin --offline -x
app:compileFlutterBuildRelease` with `BUILD SUCCESSFUL` in 46 seconds. The
signed MSIX was verified with `Get-AuthenticodeSignature` as `Valid`; its
certificate subject is `CN=SyncTune Development`, thumbprint
`084197F208644E47E54CC8F77A5B0D5D6382F766`, and SHA-256 is
`3AC2EEA83AB798345C452159D99DC3311ADB8650A88DD5F88232E7095C5C002A`.
The signing command was
`tools/package-msix.ps1 -Sign -CertificateThumbprint 084197F208644E47E54CC8F77A5B0D5D6382F766`.
The supervisor's independent analysis and 29-test run are recorded in
`build/review/supervisor-runtime-gate-analysis.log` and
`build/review/supervisor-runtime-gate-tests.log`; `git diff --check` passed.
These current-round results were executed in the task and are recorded here;
no separate full-suite log was manufactured.

The Android Debug build failure reported on 2026-10-07 was reproduced with the
workspace Flutter SDK. Its first errors were hosted package reads reported as
`../../../AppData/Local/Pub/Cache/...`; the package files existed and a direct
Dart package-resolution smoke compile passed. `flutter pub get --offline`
left both `pubspec.lock` and `.dart_tool/package_config.json` unchanged, and
the workspace debug kernel cache was isolated without changing the result.
The later `Matrix4`, `Vector3`, and `clock` diagnostics were therefore
downstream symptoms of the Gradle Flutter compile process. The current stale
Gradle daemon was stopped with `android\\gradlew.bat --stop` (one daemon),
after which the ordinary command
`C:\\Users\\Owner\\Documents\\teiocode\\flutter-sdk\\bin\\flutter.bat
build apk --debug --no-pub` succeeded in 56.1 seconds. A direct full
`android\\gradlew.bat :app:assembleDebug --offline --console=plain
--no-daemon` run succeeded in 1m37s; `:app:compileFlutterBuildDebug` ran and
the final result was `BUILD SUCCESSFUL` with 55 tasks (23 executed, 32
up-to-date). These results identify stale Gradle process state as the observed
trigger, without proving the exact OS-level cause. Evidence is retained in
`build/review/android-debug-repro.log`,
`build/review/android-gradle-debug-no-daemon.log`,
`build/review/android-debug-after-daemon-stop.log`, and
`build/review/android-gradle-stop.log`.

The resulting APK is `build/app/outputs/flutter-apk/app-debug.apk`, SHA-256
`9CCBB85945CED9E261A2D898700A51C3B5045CDAA969064BD03E2BF0F251C108`.
`aapt2 dump badging` verified package `com.example.synctune`, version `1.0.0`,
and `minSdkVersion:24`; `apksigner verify` passed with v2 signing. This is a
build and package result only: the APK was not installed or launched, and it
does not establish Android SAF runtime behavior or dual-platform sync delivery.

At the earlier pre-install snapshot, `SyncTune.Probe` 1.0.0.9 was not present
in `Get-AppxPackage`; only the older `SyncTune.PlatformProbe` 1.0.0.8 was
installed, and its legacy evidence file was not accepted. That snapshot's
Windows rows were pending. Conditional replace/delete CAS, remote WebDAV
compatibility, end-to-end synchronization, and full dual-platform delivery
remain incomplete. No destructive project cleanup or Git history rewrite was
performed.

These results establish passing static analysis, formal Flutter/core tests,
recovery regressions, and the build pipeline for the reviewed source. Full
plan conformance remains incomplete: production gate/CAS conditions remain
closed, and real platform runtime evidence, the ordinary WebDAV
adoption/reconciliation UI, Git history cleanup, and cloud CI remain pending.

## Current Windows gate revalidation (2026-10-07)

The pending-install statements above are historical. The exact package tested
in this revalidation was `SyncTune.Probe_1.0.0.17_x64__c6rm0w713zsqa`, installed
with status `Ok`. Its MSIX Authenticode signature was `Valid` for
`CN=SyncTune Development` (thumbprint
`084197F208644E47E54CC8F77A5B0D5D6382F766`), with SHA-256
`10A20691822AE413373E4B0AA1C8A6017C538F417E1DE24BD8F4C94134CA9569`.

Two standard AppsFolder launches of that PFN produced complete private
LocalState records for PIDs `22304` and `20672`. Both reported
`process.appContainer=true`, broker capability status `ok`, WinRT HTTPS status
`passed` with HTTP 200, transport `winrt_http_client`, and PasswordVault
status `ok`. The restart credential check was `ok` on both records. Both
reported `folderRestore.status=none`, because no FolderPicker/FutureAccessList
marker was created. Both reported SQLite `failed` with the native asset
resolution error for `sqlite3_initialize`; the package contains the DLL and
native-assets manifest, so this remains a runtime loader failure rather than
a missing package payload. No new Event 1000 was observed during the .17
observation window.

The .15 filtered crash stack was symbolized with the matching Flutter engine
PDB as `dart::bin::ClientSocket::ConnectComplete+0x38` at
`eventhandler_win.cc:947`, through the Windows socket completion path. The
probe therefore records the Windows capability result as a WinRT diagnostic
transport. Android keeps its Dart HTTP branch with bounded connection,
response, and drain waits. This evidence does not validate production Dio,
WebDAV conditional requests, or end-to-end synchronization.

The production gate remains closed: SQLite native asset loading is failed,
the single-root FolderPicker/FutureAccessList recovery evidence is absent,
and local conditional replace/delete CAS remains unsupported. No further
synchronization implementation was advanced from this blocked prerequisite.
The relevant build and package transcripts are
`build/gate/winrt-https-stable-windows-build.log` and
`build/gate/winrt-https-stable-package.log`; the two private evidence records
are `synctune-probe-results-22304.json` and
`synctune-probe-results-20672.json` under the installed package LocalState.

## Final Windows preload revalidation (2026-10-07)

The package-local SQLite preload is restricted to packaged processes. It uses
`LoadPackagedLibrary(L"sqlite3.dll", 0)`, verifies `sqlite3_initialize`, and
keeps the module resident without using the absolute build-machine path from
`native_assets.json` or modifying the SDK. Build and package transcripts are
`build/gate/sqlite-preload-winrt-final-build-v2.log` and
`build/gate/sqlite-preload-winrt-final-package.log`.

Installed package `SyncTune.Probe_1.0.0.20_x64__c6rm0w713zsqa` was `Ok`.
PID `5344` produced a complete record with AppContainer `true`, SQLite
`passed`/`restartCheck=true`, WinRT HTTPS HTTP 200 with
`transport=winrt_http_client` and `timedOut=false`, and PasswordVault
`status=ok`/restart `ok`. `folderRestore.status=none`; no picker marker was
created. Broker conditional replace/delete remained
`unsupported_appcontainer_provider`.

The transport guard rejects this WinRT-only result for production because the
current Dio WebDAV path is `dart_io_http_client`. The Windows-only validator
also intentionally rejects Android's `appContainer=false` process shape;
Android needs its own SAF token/generation/PID evidence path before a
dual-platform runtime claim can be made. Production Dio/WebDAV behavior,
FolderPicker/FutureAccessList recovery, CAS, and end-to-end synchronization
remain unverified, so the production gate is still blocked.

## Windows production transport delivery (2026-10-07)

The source now uses `WindowsWinRtHttpAdapter` for Windows production Dio and
for the settings connection check; startup evidence uses the distinct
`dio_winrt_http` transport value. Android retains `dart_io_http_client`.
The adapter passes arbitrary WebDAV methods and headers, preserves Dio's
redirect policy, rejects HTTP or cross-origin redirects, stages large request
bodies through the authorized root's `.synctune-local` broker area, hashes the
complete staged body, and reads responses in bounded 64 KiB chunks. Cancellation
is checked during source iteration, broker staging, native open, and response
reads; failed staging is cleaned up. Small rootless connection checks use a
private temporary file.

After the targeted adapter/composition tests passed `+30`, the final command
`flutter build windows --release --no-pub` produced the Release executable.
`tools/package-msix.ps1 -Sign -CertificateThumbprint
084197F208644E47E54CC8F77A5B0D5D6382F766` produced and signed
`build/msix/SyncTuneProbe.msix` with identity `SyncTune.Probe` 1.0.0.22.
Authenticode verification was `Valid` for `CN=SyncTune Development`; the
package SHA-256 is
`5FF234ADC0FE2E287E4018FEDDDF5E7721E9767EB008E6EE5DEDAACD1B777888`.
The package was not installed or launched in this round. These static and
contract results do not establish remote WebDAV compatibility, local provider
capabilities, or end-to-end synchronization.

The local conditional-CAS gate remains a separate conservative project guard.
`LocalCondition`/`LocalMatchSha256` express an expected-content precondition;
they do not promise provider-level atomic compare-and-swap. The user-specified
strong conditional requirement applies to remote WebDAV `ETag`/`If-Match`.
The local commit path now verifies the expected hash, preserves the old
version in `.synctune-local`, persists each stage, verifies after commit, and
retains recoverable deletes/conflict copies. `_ProductionCapabilityCheck`
checks the explicitly named recovery capabilities; it does not claim
provider-level atomic CAS.

## Formal local recovery implementation (2026-10-07)

Formal startup no longer treats `PersistedRuntimeEvidenceGate` as a required Windows or Android sync dependency. The runtime checks the live root token and generation, database and credential services, complete scans, and real remote WebDAV compatibility. The diagnostic evidence remains available for platform audits only.

`LocalPlanRecovery` runs before a recovered plan's local scan. It consumes the SQLite journal's root, relative path, old condition, staged key, new hash, length, and phase. Broker operations are idempotent: a matching published object is acknowledged, a keyed backup is restored or reused, and an unknown target or simultaneous backup/target is retained as a visible conflict and returns `NeedsRescan`. Android persists a keyed move marker before SAF move and Windows uses the same stable backup key. The implementation provides verified backup/recovery semantics, not generic provider atomic compare-and-swap.

The final package build for this round is intentionally a static delivery; installation, GUI folder selection, and WebDAV end-to-end behavior remain for the user's functional test.

## Final static delivery (2026-10-07)

`dist/SyncTune-Android-1.0.0+2.apk` has SHA-256
`D931DBE3A0EEE2BF2D21E0067F7013831FD77A56F49F029E629FACC5F198EF4E` and
APK v2 verification passed. `dist/SyncTune-Windows-1.0.0.22.msix` has SHA-256
`5FF234ADC0FE2E287E4018FEDDDF5E7721E9767EB008E6EE5DEDAACD1B777888` and
Authenticode `Valid` for `CN=SyncTune Development`, thumbprint
`084197F208644E47E54CC8F77A5B0D5D6382F766`. Both were built without
installation, launch, GUI authorization, or WebDAV functional testing.
