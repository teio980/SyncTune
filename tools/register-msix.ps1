[CmdletBinding()]
param(
  [string]$Manifest = (Join-Path $PSScriptRoot '..\build\msix-stage\AppxManifest.xml')
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logDirectory = Join-Path $repo 'build\gate'
$log = Join-Path $logDirectory 'register-msix.log'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
Start-Transcript -Path $log -Force | Out-Null
try {
  Add-AppxPackage -Register (Resolve-Path -LiteralPath $Manifest).Path `
    -ErrorAction Stop
  Write-Host 'Registration succeeded.'
} catch {
  Write-Error $_
  exit 1
} finally {
  Stop-Transcript | Out-Null
}
