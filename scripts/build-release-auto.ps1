<#
.SYNOPSIS
    Full OneDrop client release: bump, build every platform, publish to Frankfurt.
#>
[CmdletBinding()]
param(
    [switch]$SkipVersionBump,
    [switch]$SkipPublish,
    [switch]$SkipAndroid,
    [switch]$SkipWindows,
    [switch]$SkipLinux,
    [switch]$SkipMacos,
    [switch]$SkipUbuntuTouch,
    [switch]$SkipCaddy,
    [switch]$SkipGraphify,
    [switch]$SkipGitPush
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $RepoRoot
. (Join-Path $PSScriptRoot 'version-lib.ps1')
. (Join-Path $PSScriptRoot 'publish-lib.ps1')

function Invoke-Step([string]$Name, [scriptblock]$Body) {
    Write-Host ""
    Write-Host "======== $Name ========" -ForegroundColor Magenta
    & $Body
}

if (-not $SkipVersionBump) {
    Invoke-Step 'Bump version' {
        $next = Invoke-ProjectVersionBump -Force
        Write-Host "version -> $next"
    }
}

$semver = Get-ProjectVersion
$label = Get-BuildLabel
Write-Host "OneDrop release $label"

if (-not $SkipCaddy) {
    Invoke-Step 'Caddy onedrop.aml.one' {
        $ssh = Get-PublishSshTarget
        $local = Join-Path $PSScriptRoot 'frankfurt-caddy-onedrop.sh'
        $remote = '/tmp/frankfurt-caddy-onedrop.sh'
        Invoke-ScpUpload -LocalPath $local -Target $ssh.Target -Port $ssh.Port -RemoteDest $remote
        Invoke-SshRemote -Target $ssh.Target -Port $ssh.Port -RemoteCommand "sed -i 's/\r$//' '$remote'; bash '$remote'"
        Invoke-SshRemote -Target $ssh.Target -Port $ssh.Port -RemoteCommand "mkdir -p /home/ambrus/www/aml/onedrop.aml.one/downloads"
    }
}

if (-not $SkipAndroid) {
    Invoke-Step 'Android APK' {
        & (Join-Path $PSScriptRoot 'build-android.ps1') -Arm64Only
        if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
    }
}

if (-not $SkipWindows) {
    Invoke-Step 'Windows zip (onedrop.exe + DLLs)' {
        & (Join-Path $PSScriptRoot 'build-windows.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
    }
}

if (-not $SkipLinux) {
    Invoke-Step 'Linux .deb via WSL' {
        & (Join-Path $PSScriptRoot 'build-onedrop-linux-wsl.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Linux build failed' }
    }
}

if (-not $SkipMacos) {
    Invoke-Step 'macOS silicon + Intel DMGs via Nova' {
        & (Join-Path $PSScriptRoot 'build-onedrop-via-macos.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'macOS build failed' }
    }
}

if (-not $SkipUbuntuTouch) {
    Invoke-Step 'Ubuntu Touch via Nova Lima' {
        & (Join-Path $PSScriptRoot 'build-onedrop-ubuntu-touch-via-nova.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Ubuntu Touch build failed' }
    }
}

if (-not $SkipPublish) {
    $pairs = @(
        @{ Skip = $SkipAndroid; Platform = 'onedropAndroid' }
        @{ Skip = $SkipWindows; Platform = 'onedropWindows' }
        @{ Skip = $SkipLinux; Platform = 'onedropLinux' }
        @{ Skip = $SkipMacos; Platform = 'onedropMacos' }
        @{ Skip = $SkipMacos; Platform = 'onedropMacosIntel' }
        @{ Skip = $SkipUbuntuTouch; Platform = 'onedropUbuntuTouch' }
    )
    foreach ($pair in $pairs) {
        if ($pair.Skip) { continue }
        Invoke-Step "Publish $($pair.Platform)" {
            & (Join-Path $PSScriptRoot 'publish-onedrop.ps1') -Latest -Platform $pair.Platform
        }
    }
}

if (-not $SkipGraphify) {
    Invoke-Step 'graphify update' {
        Set-Location $RepoRoot
        graphify update .
        if ($LASTEXITCODE -ne 0) { throw 'graphify update failed' }
    }
}

Write-Host ""
Write-Host "OneDrop $label ready." -ForegroundColor Green
if (-not $SkipGitPush) {
    Write-Host "Commit and push this repo when git remotes exist."
}
