[CmdletBinding()]
param(
    [string]$FlutterSdkPath,
    [switch]$BuildAndroid,
    [switch]$BuildWindows
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FlutterRoot {
    param([string]$RequestedPath)

    $candidates = @()
    if ($RequestedPath) {
        $candidates += $RequestedPath
    }
    if ($env:FLUTTER_ROOT) {
        $candidates += $env:FLUTTER_ROOT
    }
    $command = Get-Command flutter.bat -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command flutter -ErrorAction SilentlyContinue
    }
    if ($command -and $command.Source) {
        $candidates += (Split-Path -Parent (Split-Path -Parent $command.Source))
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate) {
            continue
        }
        $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue
        if (-not $resolved) {
            continue
        }
        $root = $resolved.Path
        if ((Split-Path -Leaf $root) -ieq 'bin') {
            $root = Split-Path -Parent $root
        }
        if (Test-Path -LiteralPath (Join-Path $root 'bin/flutter.bat')) {
            return $root
        }
    }

    throw 'Flutter SDK not found. Pass -FlutterSdkPath or set FLUTTER_ROOT.'
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    Write-Host ("`n> {0} {1}" -f $FilePath, ($Arguments -join ' '))
    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $FilePath $($Arguments -join ' ')"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$ExpectedFlutterVersion = '3.47.6'
$ExpectedDartVersion = '3.13.5'
$flutterRoot = Resolve-FlutterRoot -RequestedPath $FlutterSdkPath
$flutter = Join-Path $flutterRoot 'bin/flutter.bat'
$dart = Join-Path $flutterRoot 'bin/cache/dart-sdk/bin/dart.exe'

if (-not (Test-Path -LiteralPath $dart)) {
    throw "Dart SDK is missing under Flutter SDK: $flutterRoot. Run the official Flutter SDK setup first."
}

$versionJson = (& $flutter --version --machine | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to query Flutter version.'
}
$version = $versionJson | ConvertFrom-Json
if ($version.frameworkVersion -ne $ExpectedFlutterVersion) {
    throw "Expected Flutter $ExpectedFlutterVersion but found $($version.frameworkVersion)."
}
if ($version.dartSdkVersion -ne $ExpectedDartVersion) {
    throw "Expected Dart $ExpectedDartVersion but found $($version.dartSdkVersion)."
}
Write-Host "Using Flutter $($version.frameworkVersion) / Dart $($version.dartSdkVersion) from $flutterRoot"

Push-Location $repoRoot
try {
    Push-Location (Join-Path $repoRoot 'packages/sync_core')
    try {
        Invoke-Checked -FilePath $dart -Arguments @('pub', 'get', '--enforce-lockfile')
        Invoke-Checked -FilePath $dart -Arguments @('analyze', '--fatal-infos')
        Invoke-Checked -FilePath $dart -Arguments @('test')
    }
    finally {
        Pop-Location
    }

    Invoke-Checked -FilePath $flutter -Arguments @('pub', 'get', '--enforce-lockfile')
    Invoke-Checked -FilePath $flutter -Arguments @('analyze', '--fatal-infos')
    Invoke-Checked -FilePath $flutter -Arguments @('test')

    if ($BuildAndroid) {
        Invoke-Checked -FilePath $flutter -Arguments @('build', 'apk', '--release', '--no-pub')
    }
    if ($BuildWindows) {
        Invoke-Checked -FilePath $flutter -Arguments @('build', 'windows', '--release', '--no-pub')
    }
}
finally {
    Pop-Location
}

Write-Host "`nVerification completed successfully."
