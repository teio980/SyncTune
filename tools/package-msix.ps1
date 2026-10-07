[CmdletBinding()]
param(
  [switch]$Install,
  [switch]$Launch,
  [switch]$Reinstall,
  [switch]$SkipInstall,
  [switch]$SkipLaunch,
  [switch]$Sign,
  [string]$CertificateThumbprint
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$release = Join-Path $repo 'build\windows\x64\runner\Release'
$stage = Join-Path $repo 'build\msix-stage'
$outputDir = Join-Path $repo 'build\msix'
$package = Join-Path $outputDir 'SyncTuneProbe.msix'
$gateDir = Join-Path $repo 'build\gate'
$log = Join-Path $gateDir 'package-msix.log'
$installEnabled = $Install -and -not $SkipInstall
$launchEnabled = $Launch -and -not $SkipLaunch

if ($Reinstall -and -not $installEnabled) {
  throw '-Reinstall requires explicit -Install.'
}
if ($launchEnabled -and -not $installEnabled) {
  throw '-Launch requires explicit -Install.'
}
if ($CertificateThumbprint -and -not $Sign) {
  throw '-CertificateThumbprint requires explicit -Sign.'
}
if ($installEnabled -and -not $Sign) {
  throw '-Install requires an explicitly signed package. Use -Sign -CertificateThumbprint <thumbprint>.'
}

function Resolve-WindowsSdkTool {
  param([Parameter(Mandatory = $true)][string]$Name)

  $fromPath = Get-Command $Name -ErrorAction SilentlyContinue
  if ($fromPath -and $fromPath.Source) {
    return $fromPath.Source
  }

  $roots = @()
  if ($env:WindowsSdkDir) {
    $roots += $env:WindowsSdkDir
  }
  $registryRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
  )
  foreach ($registryRoot in $registryRoots) {
    $installedRoot = (Get-ItemProperty -LiteralPath $registryRoot `
      -Name KitsRoot10 -ErrorAction SilentlyContinue).KitsRoot10
    if ($installedRoot) {
      $roots += $installedRoot
    }
  }
  if ($env:ProgramFiles) {
    $roots += (Join-Path $env:ProgramFiles 'Windows Kits\10')
  }
  if (${env:ProgramFiles(x86)}) {
    $roots += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10')
  }

  foreach ($root in ($roots | Select-Object -Unique)) {
    $binRoot = Join-Path $root 'bin'
    if (-not (Test-Path -LiteralPath $binRoot)) {
      continue
    }
    $versions = @(Get-ChildItem -LiteralPath $binRoot -Directory `
      -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
    foreach ($version in $versions) {
      $candidate = Join-Path $version.FullName "x64\$Name"
      if (Test-Path -LiteralPath $candidate) {
        return $candidate
      }
    }
  }
  throw "$Name was not found in an installed Windows SDK."
}

New-Item -ItemType Directory -Force -Path $gateDir, $outputDir | Out-Null
Start-Transcript -Path $log -Force | Out-Null
try {
  if (-not (Test-Path (Join-Path $release 'synctune.exe'))) {
    throw "Release build is missing: $release\synctune.exe"
  }

  $repoRoot = [IO.Path]::GetFullPath($repo).TrimEnd('\') + '\'
  $stageFull = [IO.Path]::GetFullPath($stage)
  if (-not $stageFull.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or
      $stageFull -eq $repo.TrimEnd('\')) {
    throw "Refusing to remove stage outside the workspace: $stageFull"
  }
  if (Test-Path -LiteralPath $stage) {
    $stageItem = Get-Item -LiteralPath $stage -Force
    if ($stageItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
      throw "Refusing to remove a reparse-point stage directory: $stageFull"
    }
    Remove-Item -LiteralPath $stage -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Get-ChildItem -LiteralPath $release | Copy-Item -Destination $stage -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $repo 'windows\msix\Package.appxmanifest') `
    -Destination (Join-Path $stage 'AppxManifest.xml') -Force
  New-Item -ItemType Directory -Force -Path (Join-Path $stage 'Assets') | Out-Null
  Copy-Item -LiteralPath (Join-Path $repo 'windows\msix\Assets\app_icon.png') `
    -Destination (Join-Path $stage 'Assets\app_icon.png') -Force

  $makeAppx = Resolve-WindowsSdkTool -Name 'MakeAppx.exe'
  & $makeAppx pack /d $stage /p $package /o
  if ($LASTEXITCODE -ne 0) { throw "MakeAppx failed with exit code $LASTEXITCODE" }

  if ($Sign) {
    $signTool = Resolve-WindowsSdkTool -Name 'SignTool.exe'
    if ($CertificateThumbprint -notmatch '^[0-9A-Fa-f]{40}$') {
      throw 'CertificateThumbprint must be a 40-character SHA-1 thumbprint when -Sign is used.'
    }
    $cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$CertificateThumbprint" `
      -ErrorAction SilentlyContinue
    if (-not $cert) {
      throw "Signing certificate $CertificateThumbprint was not found in CurrentUser\My."
    }
    if ($cert.Subject -ne 'CN=SyncTune Development' -or
        $cert.NotAfter -lt (Get-Date) -or -not $cert.HasPrivateKey) {
      throw 'The existing signing certificate has the wrong subject, is expired, or has no private key.'
    }
    $cer = Join-Path $outputDir 'SyncTuneProbe.cer'
    Export-Certificate -Cert $cert -FilePath $cer -Force | Out-Null
    & $signTool sign /fd SHA256 /sha1 $cert.Thumbprint $package
    if ($LASTEXITCODE -ne 0) { throw "SignTool failed with exit code $LASTEXITCODE" }
  }

  if ($installEnabled) {
    $installedBefore = Get-AppxPackage -Name 'SyncTune.Probe' -ErrorAction SilentlyContinue
    if ($installedBefore -and $Reinstall) {
      # Reinstall deliberately clears package-local state. Use this only for
      # resetting a probe before its first run; restart tests must omit it.
      $installedBefore | Remove-AppxPackage
      $installedBefore = $null
    }
    if (-not $installedBefore) {
      Add-AppxPackage -Path $package
    } else {
      # Updating in place preserves LocalState, FutureAccessList, and the
      # Credential Locker entry needed for restart verification.
      Add-AppxPackage -Path $package -ForceUpdateFromAnyVersion
    }
    $installed = Get-AppxPackage -Name 'SyncTune.Probe'
    if (-not $installed) { throw 'Add-AppxPackage returned without an installed package.' }
    Write-Host "Installed package family: $($installed.PackageFamilyName)"
    if ($launchEnabled) {
      Start-Process "shell:AppsFolder\$($installed.PackageFamilyName)!App"
      Start-Sleep -Seconds 4
      Write-Host "Launch requested for: $($installed.PackageFullName)"
    }
  }
  Write-Host "MSIX: $package"
  Write-Host "Log: $log"
}
finally {
  Stop-Transcript | Out-Null
}
