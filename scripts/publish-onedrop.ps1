<#
.SYNOPSIS
    Publishes a built OneDrop artifact to Frankfurt and verifies the result.

.DESCRIPTION
    Uploads the file, merges it into the OTA manifest, then checks the published
    manifests and the live downloads page. The verification is part of the
    publish rather than a separate step somebody might forget, because a
    half-finished publish breaks the update check for every installed client and
    announces itself nowhere.

    Never run this without the user having asked for a publish in the current
    conversation; see .cursor/rules/client-release.mdc.

.EXAMPLE
    ./scripts/publish-onedrop.ps1 -FilePath app/dist/onedrop-windows-x64-v1.0.1-260812.zip -Platform onedropWindows

.EXAMPLE
    ./scripts/publish-onedrop.ps1 -Latest -Platform onedropAndroid
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, ParameterSetName = 'Path')]
    [string]$FilePath,

    [Parameter(Mandatory, ParameterSetName = 'Latest')]
    [switch]$Latest,

    [Parameter(Mandatory)]
    [ValidateSet(
        'onedropAndroid', 'onedropWindows', 'onedropMacos',
        'onedropMacosIntel', 'onedropLinux', 'onedropUbuntuTouch'
    )]
    [string]$Platform,

    [string]$SshTarget,
    [int]$SshPort,
    [string]$RemoteReleasesDir = '/home/ambrus/www/aml/onedrop.aml.one/downloads',
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'publish-lib.ps1')

$RepoRoot = Split-Path $PSScriptRoot -Parent

if ($Latest) {
    # Matches the artifact by its platform's own naming pattern, so asking for
    # an Android publish can never pick up the Windows zip that was built beside
    # it a minute earlier.
    $prefix = switch ($Platform) {
        'onedropAndroid' { 'onedrop-android-' }
        'onedropWindows' { 'onedrop-windows-' }
        'onedropMacos' { 'onedrop-macos-silicon-' }
        'onedropMacosIntel' { 'onedrop-macos-intel-' }
        'onedropLinux' { 'onedrop-linux-' }
        'onedropUbuntuTouch' { 'onedrop-ubuntu-touch-' }
    }
    $candidate = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'app/dist') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($prefix) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        throw "No $Platform artifact in app/dist. Build it first."
    }
    $FilePath = $candidate.FullName
    Write-Host "Publishing the newest $Platform artifact: $($candidate.Name)" -ForegroundColor Cyan
}

$fileName = Split-Path -Leaf $FilePath
if (-not $PSCmdlet.ShouldProcess("$fileName -> $RemoteReleasesDir", 'Publish to Frankfurt')) {
    return
}

$publishArgs = @{
    FilePath          = $FilePath
    Platform          = $Platform
    RemoteReleasesDir = $RemoteReleasesDir
}
if ($SshTarget) { $publishArgs.SshTarget = $SshTarget }
if ($SshPort) { $publishArgs.SshPort = $SshPort }
if ($SkipVerify) { $publishArgs.SkipVerify = $true }

Publish-ClientRelease @publishArgs

if ($SkipVerify) {
    Write-Host 'Skipped live HTTPS verify (DNS or cert not ready).' -ForegroundColor Yellow
    return
}

Write-Host ''
$verifyArgs = @{ Remote = $true; RemoteReleasesDir = $RemoteReleasesDir }
if ($SshTarget) { $verifyArgs.SshTarget = $SshTarget }
if ($SshPort) { $verifyArgs.SshPort = $SshPort }
& (Join-Path $PSScriptRoot 'verify-release-manifests.ps1') @verifyArgs
