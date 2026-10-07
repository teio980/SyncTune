#requires -RunAsAdministrator
[CmdletBinding()]
param(
  [string]$Package = (Join-Path $PSScriptRoot '..\build\msix\SyncTuneProbe.msix'),
  [string]$Certificate = (Join-Path $PSScriptRoot '..\build\msix\SyncTuneProbe.cer'),
  [string]$ExpectedCertificateThumbprint
)

$ErrorActionPreference = 'Stop'
$packagePath = (Resolve-Path -LiteralPath $Package).Path
$certificatePath = (Resolve-Path -LiteralPath $Certificate).Path
$publicCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
  $certificatePath)
if ($ExpectedCertificateThumbprint -and
    $publicCert.Thumbprint -ne $ExpectedCertificateThumbprint) {
  throw "Unexpected publisher certificate thumbprint: $($publicCert.Thumbprint)"
}
if ($publicCert.Subject -ne 'CN=SyncTune Development') {
  throw "Unexpected publisher certificate subject: $($publicCert.Subject)"
}
if ($publicCert.HasPrivateKey) {
  throw 'Refusing a certificate file that contains a private key.'
}

Import-Certificate -FilePath $certificatePath `
  -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
$installed = Get-AppxPackage -Name 'SyncTune.Probe' -ErrorAction SilentlyContinue
if ($installed) {
  Add-AppxPackage -Path $packagePath -ForceUpdateFromAnyVersion
} else {
  Add-AppxPackage -Path $packagePath
}
$installed = Get-AppxPackage -Name 'SyncTune.Probe'
Write-Host "Installed package family: $($installed.PackageFamilyName)"
Write-Host "Publisher certificate thumbprint: $($publicCert.Thumbprint)"
