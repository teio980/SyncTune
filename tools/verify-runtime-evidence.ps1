[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'

function Get-Field {
  param(
    [AllowNull()][object]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Value) { return $null }
  $property = $Value.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Test-Text {
  param([AllowNull()][object]$Value)
  return $null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)
}

if (-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
  Write-Output (@{
      status = 'blocked'
      reason = "Evidence directory does not exist: $EvidenceDirectory"
    } | ConvertTo-Json -Depth 6)
  exit 1
}

$files = @(Get-ChildItem -LiteralPath $EvidenceDirectory -Filter 'synctune-probe-results-*.json' -File)
$records = @()
foreach ($file in $files) {
  try {
    $records += [pscustomobject]@{
      File = $file
      Data = (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json)
    }
  } catch {
    # Malformed evidence is ignored and reported by the missing-row result.
  }
}

$startupRecords = @($records | Where-Object { $null -ne (Get-Field $_.Data 'startup') })
$currentRecord = $startupRecords |
  Sort-Object { $_.File.LastWriteTimeUtc } -Descending |
  Select-Object -First 1
$reasons = [System.Collections.Generic.List[string]]::new()
$runtimePassed = $false
$capabilityPassed = $false
$currentPid = $null
$packageFamily = $null
$packageVersion = $null
$rootToken = $null
$rootGeneration = $null
$capabilitySummary = [ordered]@{}
$productionTransportPassed = $false
$requiredProductionTransport = 'dart_io_http_client'

if ($null -eq $currentRecord) {
  $reasons.Add('No startup evidence file was found.')
} else {
  $startup = Get-Field $currentRecord.Data 'startup'
  $process = Get-Field $startup 'process'
  if ((Get-Field $currentRecord.Data 'schema') -ne 1) {
    $reasons.Add('Current evidence schema is not version 1.')
  }
  $currentPid = [string](Get-Field $process 'pid')
  $packageFamily = [string](Get-Field $process 'packageFamily')
  $packageVersion = [string](Get-Field $process 'packageVersion')
  if ((Get-Field $process 'platform') -eq 'windows') {
    $requiredProductionTransport = 'dio_winrt_http'
  }
  if (-not (Test-Text $currentPid) -or -not (Test-Text $packageFamily) -or -not (Test-Text $packageVersion)) {
    $reasons.Add('Current process identity is incomplete.')
  }
  if ((Get-Field $process 'appContainer') -ne 'true') {
    $reasons.Add('Current startup process is not AppContainer=true.')
  }
  $expectedName = "synctune-probe-results-$currentPid.json"
  if ($currentRecord.File.Name -ne $expectedName) {
    $reasons.Add("Latest startup file does not match its PID: $($currentRecord.File.Name).")
  }
  $sqlite = Get-Field $startup 'sqlite'
  if ((Get-Field $sqlite 'status') -ne 'passed' -or (Get-Field $sqlite 'restartCheck') -ne $true) {
    $reasons.Add('SQLite private restart evidence is incomplete.')
  }
  $https = Get-Field $startup 'https'
  $httpStatus = [int](Get-Field $https 'httpStatus')
  if ((Get-Field $https 'status') -ne 'passed' -or $httpStatus -lt 200 -or $httpStatus -ge 300) {
    $reasons.Add('HTTPS probe evidence is incomplete.')
  }
  $productionTransportPassed = (Get-Field $https 'transport') -eq $requiredProductionTransport
  if (-not $productionTransportPassed) {
    $reasons.Add("HTTPS evidence transport does not match production transport '$requiredProductionTransport'.")
  }
  $credential = Get-Field $startup 'credential'
  if ((Get-Field $credential 'status') -ne 'ok' -or
      (Get-Field $credential 'restartCheck') -ne 'ok' -or
      (Get-Field $credential 'appContainer') -ne 'true') {
    $reasons.Add('Credential Locker restart evidence is incomplete.')
  }
  $restore = Get-Field $startup 'folderRestore'
  $rootToken = [string](Get-Field $restore 'token')
  $rootGeneration = [string](Get-Field $restore 'generation')
  $restoredMarker = [string](Get-Field $restore 'marker')
  $restoredContent = [string](Get-Field $restore 'restoredContent')
  if (-not (Test-Text $rootToken) -or -not (Test-Text $rootGeneration) -or
      -not (Test-Text $restoredMarker) -or -not (Test-Text $restoredContent)) {
    $reasons.Add('Current folder restore evidence has no complete root or marker identity.')
  }
  if ((Get-Field $restore 'status') -ne 'ok' -or
      (Get-Field $restore 'fileIo') -ne 'ok' -or
      [string](Get-Field $restore 'restoredPid') -ne $currentPid) {
    $reasons.Add('FAL restart and file I/O evidence is incomplete.')
  }
  $capabilities = Get-Field $startup 'brokerCapabilities'
  foreach ($field in @('platform', 'credentials', 'staging', 'atomicCreate',
      'conditionalReplace', 'conditionalDelete', 'temporaryPermission')) {
    $capabilitySummary[$field] = Get-Field $capabilities $field
  }
  if ((Get-Field $capabilities 'status') -ne 'ok') {
    $reasons.Add('No successful brokerCapabilities response was recorded.')
  }

  $matchingPick = $records | Where-Object {
    $recordSchema = Get-Field $_.Data 'schema'
    $recordStartup = Get-Field $_.Data 'startup'
    $recordProcess = Get-Field $recordStartup 'process'
    $pick = Get-Field $_.Data 'folderPick'
    $recordSchema -eq 1 -and
      (Get-Field $recordProcess 'appContainer') -eq 'true' -and
      [string](Get-Field $recordProcess 'packageFamily') -eq $packageFamily -and
      (Test-Text (Get-Field $recordProcess 'packageVersion')) -and
      (Get-Field $pick 'status') -eq 'ok' -and
      (Get-Field $pick 'reopen') -eq 'ok' -and
      (Get-Field $pick 'fileIo') -eq 'ok' -and
      [string](Get-Field $pick 'token') -eq $rootToken -and
      [string](Get-Field $pick 'generation') -eq $rootGeneration -and
      [string](Get-Field $pick 'marker') -eq $restoredMarker -and
      [string](Get-Field $pick 'markerContent') -eq $restoredContent -and
      (Test-Text (Get-Field $pick 'token')) -and
      (Test-Text (Get-Field $pick 'marker')) -and
      (Test-Text (Get-Field $pick 'markerContent'))
  }
  if (@($matchingPick).Count -eq 0) {
    $reasons.Add('No successful FolderPicker/FutureAccessList marker record was found.')
  }
  $differentPid = @($matchingPick | Where-Object {
      [string](Get-Field (Get-Field (Get-Field $_.Data 'startup') 'process') 'pid') -ne $currentPid
    }).Count -gt 0
  if (-not $differentPid) {
    $reasons.Add('The marker was not read by a different process PID.')
  }
  $runtimePassed =
    (Get-Field $currentRecord.Data 'schema') -eq 1 -and
    (Get-Field $process 'appContainer') -eq 'true' -and
    (Test-Text $currentPid) -and
    (Test-Text $packageFamily) -and
    (Test-Text $packageVersion) -and
    $currentRecord.File.Name -eq "synctune-probe-results-$currentPid.json" -and
    (Get-Field $sqlite 'status') -eq 'passed' -and
    (Get-Field $sqlite 'restartCheck') -eq $true -and
    (Get-Field $https 'status') -eq 'passed' -and
    $httpStatus -ge 200 -and $httpStatus -lt 300 -and
    $productionTransportPassed -and
    (Get-Field $credential 'status') -eq 'ok' -and
    (Get-Field $credential 'restartCheck') -eq 'ok' -and
    (Get-Field $credential 'appContainer') -eq 'true' -and
    (Get-Field $restore 'status') -eq 'ok' -and
    (Get-Field $restore 'fileIo') -eq 'ok' -and
    [string](Get-Field $restore 'restoredPid') -eq $currentPid -and
    (Test-Text $rootToken) -and
    (Test-Text $rootGeneration) -and
    (Test-Text $restoredMarker) -and
    (Test-Text $restoredContent) -and
    (Get-Field $capabilities 'status') -eq 'ok' -and
    @($matchingPick).Count -gt 0 -and $differentPid

  $capabilityPassed =
    (Get-Field $capabilities 'status') -eq 'ok' -and
    (Get-Field $capabilities 'atomicCreate') -eq 'fail_if_exists_verified' -and
    (Get-Field $capabilities 'conditionalReplace') -eq 'provider_compare_and_swap' -and
    (Get-Field $capabilities 'conditionalDelete') -eq 'provider_compare_and_delete'
  if (-not $capabilityPassed) {
    $reasons.Add('Broker conditional replace/delete capabilities are not production-safe.')
  }
}

$result = [ordered]@{
  status = if ($runtimePassed -and $capabilityPassed) {
    'local-evidence-passed-remote-unverified'
  } else { 'blocked' }
  runtimeEvidencePassed = $runtimePassed
  brokerCapabilitiesPassed = $capabilityPassed
  productionTransportPassed = $productionTransportPassed
  requiredProductionTransport = $requiredProductionTransport
  localSyncRequirementsPassed = $runtimePassed -and $capabilityPassed -and $productionTransportPassed
  remoteCompatibilityEvaluated = $false
  endToEndSyncPassed = $false
  evidenceDirectory = (Resolve-Path -LiteralPath $EvidenceDirectory).Path
  currentPid = $currentPid
  packageFamily = $packageFamily
  packageVersion = $packageVersion
  brokerCapabilities = $capabilitySummary
  reasons = @($reasons)
}
Write-Output ($result | ConvertTo-Json -Depth 8)
if (-not $result.localSyncRequirementsPassed) { exit 1 }
