# Sync OneDrop to Nova and build Ubuntu Touch arm64 via Lima (messageme-ut).
param(
    [string]$MacHost = $(if ($env:ONEDROP_UT_HOST) { $env:ONEDROP_UT_HOST } elseif ($env:ONEDROP_MAC_HOST) { $env:ONEDROP_MAC_HOST } else { 'nova' }),
    [string]$RemoteRepo = $(if ($env:ONEDROP_UT_DEST) { $env:ONEDROP_UT_DEST } else { '/Users/ambrus/src/onedrop-ut-current' })
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'version-lib.ps1')

function Get-OpenSshBin {
    param([Parameter(Mandatory)][ValidateSet('ssh', 'scp')][string]$Name)
    $system = Join-Path $env:WINDIR "System32/OpenSSH/$Name.exe"
    if (Test-Path -LiteralPath $system) { return $system }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { throw "$Name not found on PATH." }
    return $command.Source
}

$semver = Get-ProjectVersion
$buildDate = Get-BuildDateStamp
$dist = Join-Path $root 'app/dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null

$ssh = Get-OpenSshBin -Name ssh
$scp = Get-OpenSshBin -Name scp
if ($MacHost -eq 'nova') {
    $resolved = ((wsl.exe -d Ubuntu -- bash -lc "getent hosts nova | awk '{print `$1}'") -replace "`0", '').Trim()
    if ($resolved -match '^\d+\.\d+\.\d+\.\d+$') {
        $MacHost = "ambrus@$resolved"
        Write-Host "Resolved nova to $MacHost" -ForegroundColor DarkGray
    }
}

$wslRoot = (& wsl.exe -d Ubuntu wslpath -a ($root -replace '\\', '/')).Trim()
if ($LASTEXITCODE -ne 0 -or -not $wslRoot) {
    throw 'WSL path conversion failed for OneDrop Ubuntu Touch sync.'
}

Write-Host "Syncing OneDrop to ${MacHost}:${RemoteRepo} ..." -ForegroundColor Cyan
$syncCmd = @"
set -euo pipefail
cd '$wslRoot'
find scripts -name '*.sh' -print0 | xargs -0 sed -i 's/\r`$//'
chmod +x scripts/_sync-ut-to-nova.sh scripts/_run-ut-on-nova.sh scripts/package-ubuntu-touch.sh scripts/build-onedrop-linux.sh
ONEDROP_UT_HOST='$MacHost' ONEDROP_UT_DEST='$RemoteRepo' ./scripts/_sync-ut-to-nova.sh
"@
$syncCmd = ($syncCmd -replace "`r`n", "`n").Trim()
& wsl.exe -d Ubuntu -- bash -c $syncCmd
if ($LASTEXITCODE -ne 0) { throw 'OneDrop sync to Nova failed.' }

$helperBody = @'
#!/bin/bash
set -euo pipefail
REPO_DIR="${ONEDROP_REPO_DIR:-$HOME/src/onedrop-ut-current}"
exec bash "$REPO_DIR/scripts/_run-ut-on-nova.sh" "${1:-ubuntu-touch}"
'@
$helperB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($helperBody.Replace("`r`n", "`n")))
& $ssh -o StrictHostKeyChecking=accept-new $MacHost "mkdir -p ~/bin '$RemoteRepo'; echo $helperB64 | base64 -d > ~/bin/onedrop-ut-build; chmod +x ~/bin/onedrop-ut-build"
if ($LASTEXITCODE -ne 0) { throw 'Could not install onedrop-ut-build on Nova.' }

Write-Host "Building OneDrop Ubuntu Touch on Nova (Lima messageme-ut) ..." -ForegroundColor Cyan
& $ssh -o StrictHostKeyChecking=accept-new $MacHost "ONEDROP_REPO_DIR='$RemoteRepo' ~/bin/onedrop-ut-build ubuntu-touch"
if ($LASTEXITCODE -ne 0) { throw 'OneDrop Ubuntu Touch build on Nova failed.' }

$nameExact = "onedrop-ubuntu-touch-arm64-v$semver-$buildDate.tar.gz"
$nameAny = "onedrop-ubuntu-touch-arm64-v$semver-*.tar.gz"
& $scp -o StrictHostKeyChecking=accept-new "${MacHost}:${RemoteRepo}/app/dist/$nameExact" $dist
if ($LASTEXITCODE -ne 0) {
    Write-Host "Exact-date UT tarball missing; copying any v$semver artifact…" -ForegroundColor Yellow
    & $scp -o StrictHostKeyChecking=accept-new "${MacHost}:${RemoteRepo}/app/dist/$nameAny" $dist
    if ($LASTEXITCODE -ne 0) { throw "Could not copy Ubuntu Touch artifact from Nova." }
}
$artifactItem = Get-ChildItem -LiteralPath $dist -Filter $nameAny |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if (-not $artifactItem) { throw "Missing local Ubuntu Touch artifact for v$semver" }
Write-Host "OneDrop Ubuntu Touch artifact: $($artifactItem.FullName)" -ForegroundColor Green
