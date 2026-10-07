# SyncTune Windows AppContainer Gate

This document records the reproducible Windows feasibility probe. The gate is
passed only when the installed MSIX starts the Flutter UI in the AppContainer
and every runtime row below is observed from that same process.

## Package definition

`windows/msix/Package.appxmanifest` declares
`uap10:RuntimeBehavior="packagedClassicApp"` and
`uap10:TrustLevel="appContainer"`. It declares `internetClient` and `privateNetworkClientServer` for the
network probe and intentionally has no `runFullTrust` capability. The native
probe calls `GetTokenInformation(TokenIsAppContainer)` in the Flutter process,
so a Win32 launch or a full-trust package cannot satisfy this gate.

Microsoft's reference is [MSIX AppContainer apps](https://learn.microsoft.com/en-us/windows/msix/msix-container).

## Reproduction

From the repository root, use the configured Flutter SDK:

```powershell
$env:Path = 'C:\Users\Owner\Documents\teiocode\flutter-sdk\bin;' + $env:Path
flutter build windows --release --no-pub
.\tools\package-msix.ps1
```

`package-msix.ps1` writes the packaging transcript to
`build/gate/package-msix.log`. The default output is an unsigned MSIX for
headless packaging checks. A package intended for installation must be signed
explicitly with an existing code-signing certificate:

```powershell
.\tools\package-msix.ps1 -Sign -CertificateThumbprint <40-hex-thumbprint>
```

The verification workflow runs the unsigned packaging step after the Windows
release build and uploads `build/msix/SyncTuneProbe.msix`; that artifact is a
packaging check and is not an installable release until signed.

The script never creates or imports a certificate. Installation and launch are
explicit opt-ins and reject unsigned output. To reset the first run, use
`-Sign -CertificateThumbprint <thumbprint> -Install -Reinstall`; to launch
after installation, add `-Launch`. For a restart test, stop and relaunch the
installed package or run the script with `-Sign -CertificateThumbprint
<thumbprint> -Install` without `-Reinstall`; removing the package would erase
its LocalState, FutureAccessList, and Credential Locker state.

The installed package opens the English SyncTune shell. Open `Settings` →
`Open platform diagnostics` to run the retained capability probe, then use its folder
button to choose the dedicated empty test directory. The probe is a diagnostic
route; the product synchronization action remains disabled until the rows
below have been independently verified.

The app also runs the non-interactive startup probe after launch and coalesces
it with the diagnostics route. Once a marker has been created for the active
root, later launches may reuse the same package-and-root evidence while the
gate performs a live `restoreFolder` and `brokerCapabilities` check. Changing
the root or generation requires a new marker. Run
`tools/verify-runtime-evidence.ps1 -EvidenceDirectory <LocalState>` to audit
the persisted rows. A successful result proves only local AppContainer,
credential, private-storage, folder-recovery, and broker capability evidence;
the script reports remote WebDAV compatibility and end-to-end synchronization
as unverified.

If the machine requires administrator approval for the local development
publisher, inspect the public certificate first and then run the following
helper in an elevated PowerShell window:

```powershell
.\tools\install-msix-admin.ps1
```

The helper verifies that `build/msix/SyncTuneProbe.cer` has subject
`CN=SyncTune Development`, and contains no private key. Pass
`-ExpectedCertificateThumbprint <40-hex-thumbprint>` when an explicit
thumbprint check is required. It imports only that public certificate into the machine `TrustedPeople` store
and installs the package. Run it elevated under the same user profile that
will launch the probe. It does not import a root certificate, change
developer mode, or remove a package.

## Runtime evidence

Capture the following rows from the visible Flutter probe UI. Run the probe
once after a fresh install and once after closing and relaunching the same
installed package. Use the folder button during the first run and select a
directory that is safe to write to.

| Capability | Required result |
| --- | --- |
| Flutter process identity | `AppContainer: true` |
| Private SQLite | `SQLite private file: sqlite-ok; restart: ok` on the second run; the path comes from `ApplicationData.Current().LocalFolder()` |
| Network | `Network: HTTP 200` (or another successful HTTPS response) |
| Credential Locker | First run `Credential Locker: ok`, second run `Credential restart check: ok` |
| Folder picker/FutureAccessList | `Folder authorization: ok`, unique GUID marker, `Reopen: ok`, read-back `File I/O: ok` |
| FAL restart recovery | A different PID reads the original GUID marker content; no replacement file is created |

The folder marker and token use WinRT `StorageFolder`/`FileIO`; direct Win32
path writes are not used as evidence. FolderPicker and FAL operations are
awaited asynchronously so the UI STA is not blocked by `.get()`.

## Broker protocol capability gate

The production method channel is `synctune/probe`. Its
`brokerCapabilities` response is a typed compatibility input; the runtime
must stop before scheduling a plan when a required value is absent or weaker
than the plan's precondition.

| Field | Android SAF | Windows AppContainer |
| --- | --- | --- |
| `credentials` | `android_keystore_aes_gcm_app_private` | `windows_password_vault` |
| `staging` | `persistent_after_finish_root_scoped` | `persistent_after_finish_root_scoped` |
| `atomicCreate` | `unsupported_saf_provider` | `fail_if_exists_verified` |
| `conditionalReplace` | `unsupported_saf_provider` | `unsupported_appcontainer_provider` |
| `conditionalDelete` | `unsupported_saf_provider` | `unsupported_appcontainer_provider` |
| `temporaryPermission` | `not_verifiable` | `not_applicable` |

Android conditional create, replace, and delete retain the staged object and
stop; SAF providers may expose rename or copy operations without a
compare-and-swap guarantee. Windows create-only uses a provider
fail-if-exists copy followed by hash/length verification. Windows conditional
replace and delete remain disabled until a provider-backed transactional write
and conditional delete have been implemented and tested. WinRT
[`StorageFile.OpenTransactedWriteAsync`](https://learn.microsoft.com/en-us/uwp/api/windows.storage.storagefile.opentransactedwriteasync?view=winrt-26100)
and [`StorageStreamTransaction`](https://learn.microsoft.com/en-us/uwp/api/windows.storage.storagestreamtransaction?view=winrt-26100)
are future candidates, not current capability claims. The available
single-writer/share modes are documented by
[`IStorageFile2.OpenAsync`](https://learn.microsoft.com/en-us/uwp/api/windows.storage.istoragefile2.openasync?view=winrt-26100),
but still require provider-specific race evidence.

For conditional replacement to become enabled, the implementation must prove
that the selected provider can couple the expected old hash or version to the
writer transaction. A hash read followed by `CommitAsync` is still a race if a
different writer can change or replace the file between those operations. The
gate also needs verified single-writer behavior, transaction rollback/error
handling, and post-commit identity plus hash/length checks under a competing
writer test. `StorageStreamTransaction` supplies a transactional stream and a
`CommitAsync` operation, but its contract does not itself expose a
compare-with-expected-hash precondition.

Conditional deletion needs a provider primitive that compares the expected
file identity/version as part of deletion. Hash-then-`DeleteAsync` is unsafe:
another writer can replace the directory entry after the hash and before the
delete. An exclusive read or writer handle alone does not establish a
compare-and-delete contract for every provider. Until those provider semantics
and race tests exist, the compatibility response must keep
`conditionalDelete` unsupported and the runtime must stop the plan.

### Provider API feasibility review (2026-10-07)

The current gate was checked against the primary Android and Windows API
contracts. Android's [`DocumentsContract.Document` flags](https://developer.android.com/reference/android/provider/DocumentsContract.Document)
advertise operations such as write, delete, rename, copy, and move; they do
not carry an expected content hash, version, or compare token.
[`DocumentsProvider.createDocument`](https://developer.android.com/reference/android/provider/DocumentsProvider#createDocument(java.lang.String,java.lang.String,java.lang.String))
creates a document and returns a newly generated document ID, while
[`deleteDocument`](https://developer.android.com/reference/android/provider/DocumentsProvider#deleteDocument(java.lang.String))
accepts only a document ID;
neither operation has an expected-version precondition. The stream API is also
provider-defined: Android documents that `ContentResolver.openOutputStream`
mode behavior can differ by provider, including whether `w` truncates
([`ContentResolver.openOutputStream`](https://developer.android.com/reference/android/content/ContentResolver#openOutputStream(android.net.Uri,java.lang.String))).
The raw descriptor contract also permits an exclusive `r` or `w` open to be a
pipe or socket, while `rw` only implies a seekable file when the provider can
provide one; it is not a generic interprocess file lock
([`ContentResolver.openFileDescriptor`](https://developer.android.com/reference/android/content/ContentResolver#openFileDescriptor(android.net.Uri,java.lang.String))).
Consequently, generic API 24+ SAF has no verifiable conditional create,
replace, or delete primitive. A future Android capability would need a
provider-specific compare-and-create, compare-and-replace, and
compare-and-delete contract (or a provider transaction that holds the
identity check through commit), plus competing-writer evidence. URI grants,
document IDs, and a hash read alone do not supply that contract.

Windows has a useful candidate for a provider-specific replacement
implementation: [`StorageFile.OpenTransactedWriteAsync`](https://learn.microsoft.com/en-us/uwp/api/windows.storage.storagefile.opentransactedwriteasync?view=winrt-26100)
returns a [`StorageStreamTransaction`](https://learn.microsoft.com/en-us/uwp/api/windows.storage.storagestreamtransaction?view=winrt-26100),
whose `CommitAsync` saves the transaction stream to the underlying file. A
local provider could be tested with this sequence: open the target transaction
with `StorageOpenOptions::AllowOnlyReaders`, determine whether the transaction
stream exposes the target's pre-transaction bytes, hash those bytes while the
transaction remains open, compare the expected hash and length, copy the
staged bytes into that same transaction, and commit. The API reference does
not promise that the transaction stream is a snapshot of the old file or that
opening it excludes every provider writer, so this is an experiment to prove,
not an implementation we can currently claim. It would still require evidence
that the selected provider holds the required writer exclusion and that a
competing rename, replacement, or writer cannot change the target between the
check and `CommitAsync`.

The generic Windows contract does not complete that proof. [`StorageOpenOptions`](https://learn.microsoft.com/en-us/uwp/api/windows.storage.storageopenoptions?view=winrt-14393)
only specifies `AllowOnlyReaders` or `AllowReadersAndWriters`; it has no
expected hash/version field. `StorageStreamTransaction.CommitAsync` is
documented as saving the stream, not as comparing an expected identity, and
[`MoveAndReplaceAsync`](https://learn.microsoft.com/en-us/uwp/api/windows.storage.istoragefile.moveandreplaceasync?view=winrt-22000)
is unconditional. `DeleteAsync` likewise has no expected hash/version
argument, so the transaction candidate cannot implement conditional delete.
The only currently verified Windows mutation is create-only through
`CreateFileAsync(..., CreationCollisionOption::FailIfExists)`. The broker's
root token/generation checks can reject a changed authorization before and
after each asynchronous step, but they do not turn a hash check plus a later
provider operation into CAS.

This review does not constitute runtime acceptance. The AppContainer runtime
rows remain pending, and both platforms continue to report conditional
replace/delete as unsupported. Enabling Windows replacement would require a
provider-scoped implementation and a headless competing-writer test proving
hash check, writer exclusion, commit identity, post-commit hash/length, and
root-generation checks. Enabling delete would additionally require a
provider-scoped compare-and-delete primitive; hash-then-`DeleteAsync` remains
forbidden.

The standard Android SAF document flags advertise create, delete, rename, and
move support, but do not provide a compare-and-swap condition tied to an
expected content version. See the [`DocumentsContract.Document` flags](https://developer.android.com/reference/android/provider/DocumentsContract.Document).
Therefore SAF file I/O and persisted access can pass runtime checks while
conditional synchronization remains disabled.

Staging handles are opaque UUIDs for files under the selected root's
`.synctune-local` directory. After process restart, `openStaged`, `verifyStaged`,
and `commitStaged` resolve the durable handle through the active root token and
generation. The in-memory write session is not treated as durable.

Credential calls are `credentialSave`, `credentialRead`, and `credentialDelete`
with normalized service/account keys. Android encrypts each record with an
Android Keystore AES-GCM key and app-private storage; Windows uses
`PasswordVault`. Secrets are returned only for an explicit read and are not
included in diagnostics or error evidence.

The diagnostic `pickFolder` route is restricted to the current active root. It
does not call `FutureAccessList.Add` and cannot create a second root grant.
`restoreFolder` accepts a private marker only when its token still matches the
active root token; stale diagnostic records cannot revive an old root.

## Current run record

### Android SAF runtime subset

This is evidence from the isolated `Medium_Phone` AVD (Android API 36), using
the emulator's external-storage DocumentsProvider and a dedicated empty test
folder. It does not cover physical-device providers.

| Check | Result | Evidence |
| --- | --- | --- |
| Release APK install and launch | PASS | Installed `app-release.apk` on `emulator-5556`; Chinese SyncTune shell launched |
| SAF directory authorization | PASS | Selected `SyncTuneTest`; settings displayed the persisted tree URI and authorized state |
| Process restart recovery | PASS | Force-stopped and relaunched; process changed from PID `28873` to `31241`, and the selected root was restored |
| Folder marker cross-process recovery | PASS | Follow-up probe ran with a different PID and returned `Folder restart recovery: ok` and `Folder restart file I/O: ok` |
| Folder restart marker implementation | PASS | Probe now persists the provider-returned tree-scoped document URI; legacy name-only records do not claim recovery when a provider hides the marker |

This establishes Android API 36 emulator recovery only. Other Android versions
and physical SAF providers remain unverified. The CAS capability rows above
remain unsupported, so full synchronization stays disabled.

### Windows AppContainer run

| Check | Result | Evidence |
| --- | --- | --- |
| Native Windows runner compile | PASS | `MSBuild ... synctune.vcxproj /t:ClCompile`; `probe_channel.cpp` compiled with 0 warnings and 0 errors |
| Dart analysis | PASS | `dart analyze --fatal-infos`; `No issues found!` in the current validation round |
| Flutter Windows release build | PASS | `flutter build windows --release --no-pub`; output `build/windows/x64/runner/Release/synctune.exe` in 136 seconds |
| Flutter full test suite | PASS | `flutter test --no-pub`; `+148 All tests passed` in the current validation round |
| Android native Kotlin compile | PASS | From `android`, `gradlew.bat app:compileReleaseKotlin --offline -x app:compileFlutterBuildRelease`; `BUILD SUCCESSFUL` in 46 seconds |
| Android release APK build and emulator run | PASS | `flutter build apk --release --no-pub`; installed and exercised on the isolated Android API 36 AVD above |
| Unsigned MSIX packaging | PASS | Default `tools/package-msix.ps1` created `build/msix/SyncTuneProbe.msix` with `MakeAppx`; no signing, certificate import, installation, or launch was performed in this headless check; transcript in `build/gate/package-msix.log` |
| Signed MSIX packaging | PASS | `tools/package-msix.ps1 -Sign -CertificateThumbprint 084197F208644E47E54CC8F77A5B0D5D6382F766`; Authenticode verification passed for `CN=SyncTune Development`. SHA-256: `3AC2EEA83AB798345C452159D99DC3311ADB8650A88DD5F88232E7095C5C002A`. No certificate import or installation was performed by this audit. |
| Current package installation | PENDING USER ADMIN ACTION | `SyncTune.Probe` 1.0.0.9 is not present in `Get-AppxPackage`; only the older `SyncTune.PlatformProbe` 1.0.0.8 package is installed. The old package's `synctune-probe-results.json` uses a previous schema and is not accepted as current evidence. |
| Development registration fallback | PENDING DEVELOPER MODE | `tools/register-msix.ps1` returned `0x80073CFF`; full transcript in `build/gate/register-msix.log`; this machine has no developer license/sideloading policy |
| AppContainer runtime rows | NOT YET OBSERVED | The current package is not installed; `processInfo`, FAL restart, credential restart, and capability evidence for `SyncTune.Probe` remain uncollected. The old package's legacy evidence is rejected. |

The remaining Windows runtime gate therefore requires an installed AppContainer run to
capture `appContainer: true`, private database restart recovery, credential
restart recovery, the single active FAL root after picker/restore, and the
exact `brokerCapabilities` response. Static builds and contract tests do not
substitute for those OS permission rows.

The package-install blocker is an environment trust prerequisite, not a
runtime feasibility result. The user has agreed to run the existing
administrator helper; completion has not yet been observed. Do not mark this
gate passed until the exact runtime rows above are captured from the installed
AppContainer process. Conditional replace/delete CAS and remote WebDAV
compatibility remain separate production conditions.

## Latest installed-package revalidation (2026-10-07)

The historical pending-install text above is superseded by the following
real run. The user completed the existing administrator helper; the package was
then updated per-user with the already trusted development certificate. The
current installed identity is `SyncTune.Probe_1.0.0.17_x64__c6rm0w713zsqa`,
version `1.0.0.17`, status `Ok`. The signed MSIX was verified as `Valid` for
`CN=SyncTune Development`, thumbprint
`084197F208644E47E54CC8F77A5B0D5D6382F766`, SHA-256
`10A20691822AE413373E4B0AA1C8A6017C538F417E1DE24BD8F4C94134CA9569`.

Two standard AppsFolder launches of that exact PFN completed the noninteractive
probe and remained alive during the observation window:

| Process | AppContainer | HTTPS probe | Credentials | SQLite | Folder recovery |
| --- | --- | --- | --- | --- | --- |
| PID 22304 | `true` | `passed`, HTTP 200, `winrt_http_client` | `ok`, restart `ok` | `failed` | `none` |
| PID 20672 | `true` | `passed`, HTTP 200, `winrt_http_client` | `ok`, restart `ok` | `failed` | `none` |

The JSON files are the package-private LocalState records
`synctune-probe-results-22304.json` and
`synctune-probe-results-20672.json`. The SQLite error is unchanged and
actionable: Dart native assets cannot resolve
`package:sqlite3/src/ffi/libsqlite3.g.dart`; there is no available native
asset and the process lookup contains no `sqlite3_initialize` symbol. The
package does contain `sqlite3.dll` and `NativeAssetsManifest.json`, so this is
an AppContainer native-assets loading failure rather than a missing payload.

The .10/.11 preload experiment made SQLite report `passed`; those versions
also showed an Event 1000 crash (`ntdll.dll`, `0xc0000008`). Removing the
preload in .12/.13 did not remove that crash, so the observations do not
establish a preload cause. A filtered diagnostic stack from .15 symbolized
with the matching Flutter engine PDB as
`dart::bin::ClientSocket::ConnectComplete+0x38` at
`eventhandler_win.cc:947`, through `WS2_32` and
`flutter_windows.dll`. The probe therefore uses the Windows WinRT HTTP
adapter for this AppContainer capability check; Android retains its Dart HTTP
branch, and production Dio/WebDAV transport is a separate unverified
condition. The .17 runs produced no new Event 1000 records.

No FolderPicker/FutureAccessList marker has been created in this revalidation,
so root-token recovery, cross-PID folder access, CAS, remote WebDAV
compatibility, and end-to-end synchronization remain unverified. The
production synchronization gate stays closed while SQLite is failed and the
folder evidence is absent. The build and package transcripts are
`build/gate/winrt-https-stable-windows-build.log` and
`build/gate/winrt-https-stable-package.log`.

## SQLite preload revalidation (2026-10-07, package 1.0.0.20)

The package-local preload runs only after `GetCurrentPackagePath` confirms a
packaged process. It calls `LoadPackagedLibrary(L"sqlite3.dll", 0)`, verifies
the exported `sqlite3_initialize` symbol, and keeps the module loaded for the
process lifetime. Unpackaged development keeps the normal Flutter loader
path. The release build and signed package transcripts are
`build/gate/sqlite-preload-winrt-final-build-v2.log` and
`build/gate/sqlite-preload-winrt-final-package.log`.

Installed package `SyncTune.Probe_1.0.0.20_x64__c6rm0w713zsqa` was `Ok`.
PID `5344` produced `synctune-probe-results-5344.json` with AppContainer
`true`, SQLite `passed`/`restartCheck=true`, WinRT HTTPS HTTP 200
`passed`/`timedOut=false`, and PasswordVault `ok`/restart `ok`. Folder restore
was `none`; no FolderPicker/FutureAccessList marker exists. Broker conditional
replace/delete remained unsupported.

This is the first packaged run in which SQLite passed. The production gate
still requires `dart_io_http_client`, so the recorded WinRT diagnostic
transport cannot satisfy production Dio. CAS, remote WebDAV compatibility,
and end-to-end synchronization remain blocked. The prepared empty folder for
the required manual picker step is
`C:\Users\Owner\Documents\teiocode\SyncTune\build\gate\runtime-root-3505c583f40e4ebb8f995bbe6b95e430`.

## Production transport source check (2026-10-07)

The old `.20` runtime record above is historical WinRT-only evidence. Current
Windows production Dio and the settings connection checker use
`WindowsWinRtHttpAdapter`, and the startup diagnostic records
`transport=dio_winrt_http`; Android continues to use its Dart HTTP adapter.
The adapter carries WebDAV methods, headers, strong `If-Match` values, Dio
redirect bounds, bounded upload/download chunks, cancellation, and authorized
root `.synctune-local` staging with full SHA-256 verification. The native
broker keeps a response reader for the whole response and rejects HTTP or
cross-origin redirects.

The targeted adapter/composition run passed `+30`. The final release package
was built and signed without installation or launch:

| Item | Result |
| --- | --- |
| Release build | `flutter build windows --release --no-pub` passed |
| Package | `SyncTune.Probe` 1.0.0.22 at `build/msix/SyncTuneProbe.msix` |
| Signature | `Valid`, `CN=SyncTune Development`, thumbprint `084197F208644E47E54CC8F77A5B0D5D6382F766` |
| SHA-256 | `5FF234ADC0FE2E287E4018FEDDDF5E7721E9767EB008E6EE5DEDAACD1B777888` |

This build result does not claim the AppContainer runtime gate or WebDAV
end-to-end synchronization passed. The existing broker reports provider-level
conditional replace/delete CAS as unsupported; that is a project capability
boundary, not a claim that the user architecture requires a generic local
provider CAS API. The implemented local path verifies the expected hash before
mutation, preserves the old version in `.synctune-local`, persists and
verifies each stage, and keeps deletes recoverable.


## Current formal sync and recovery status (2026-10-07)

The Windows-only persisted runtime evidence is an audit facility, not a formal Android/Windows synchronization prerequisite. The production runtime uses live root and generation validation, database and credential checks, complete scans, and a real WebDAV strong-ETag compatibility check. Android follows its SAF path and is not evaluated by Windows PFN/AppContainer rules.

Both brokers now report explicitly named recovery capabilities: `verified_create_recovery`, `verified_backup_replace`, and `verified_backup_delete`. Before local scanning, `LocalPlanRecovery` replays unfinished SQLite journal phases. Each local replacement or deletion verifies the expected bytes, keeps a stable-key backup in `.synctune-local`, verifies the result, and preserves unknown or conflicting content for a rescan. Android uses a provider-visible keyed move marker before moving a SAF document; Windows uses a root-scoped keyed backup. These names intentionally do not claim atomic provider CAS.

## Final static delivery (2026-10-07)

The final signed package is `dist/SyncTune-Windows-1.0.0.22.msix`, SHA-256
`5FF234ADC0FE2E287E4018FEDDDF5E7721E9767EB008E6EE5DEDAACD1B777888`,
Authenticode `Valid`, signer `CN=SyncTune Development`, thumbprint
`084197F208644E47E54CC8F77A5B0D5D6382F766`. It was built after the recovery
changes and was not installed or launched. Android delivery is
`dist/SyncTune-Android-1.0.0+2.apk`; user functional testing remains required.
