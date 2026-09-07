<#
.SYNOPSIS
    Checks that the published OneDrop OTA manifests are sound.
#>
[CmdletBinding()]
param(
    [switch]$Remote,
    [string]$SshTarget,
    [int]$SshPort,
    [string]$RemoteReleasesDir = '/home/ambrus/www/aml/onedrop.aml.one/downloads'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'publish-lib.ps1')

$localDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'data/releases'
if (Test-Path -LiteralPath (Join-Path $localDir 'version.json')) {
    Write-Host 'Validating local seed manifests...' -ForegroundColor Cyan
    Assert-ReleaseManifestsValid -Dir $localDir
}

if (-not $Remote) {
    Write-Host 'Manifests OK (local only; pass -Remote to check the published copy)' -ForegroundColor Green
    exit 0
}

$sshArgs = @{}
if ($SshTarget) { $sshArgs.SshTarget = $SshTarget }
if ($SshPort) { $sshArgs.SshPort = $SshPort }
$ssh = Get-PublishSshTarget @sshArgs

Write-Host "Validating published manifests on $($ssh.Target)..." -ForegroundColor Cyan
Assert-RemoteReleaseManifestsValid -Target $ssh.Target -Port $ssh.Port -RemoteReleasesDir $RemoteReleasesDir

Write-Host 'Fetching the manifests as a client would...' -ForegroundColor Cyan
Assert-DownloadsPageLive

Write-Host 'Manifests OK' -ForegroundColor Green
