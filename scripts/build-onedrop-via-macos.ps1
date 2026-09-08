# Sync One Drop to a configured macOS host, build Intel + Apple Silicon DMGs, copy them to onedrop/dist.
param(
    [string]$MacHost = $(if ($env:ONEDROP_MAC_HOST) { $env:ONEDROP_MAC_HOST } elseif ($env:ONEAUTH_MAC_HOST) { $env:ONEAUTH_MAC_HOST } else { 'ambrus@192.168.31.230' }),
    [string]$MacRoot = $(if ($env:ONEDROP_MAC_ROOT) { $env:ONEDROP_MAC_ROOT } else { '~/src/onedrop-macos' }),
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$assets = Join-Path (Split-Path $root -Parent) 'global-assets'

function Get-OpenSshBin {
    param([Parameter(Mandatory)][ValidateSet('ssh', 'scp')][string]$Name)
    $system = Join-Path $env:WINDIR "System32/OpenSSH/$Name.exe"
    if (Test-Path -LiteralPath $system) { return $system }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { throw "$Name not found on PATH." }
    return $command.Source
}

if (-not $MacHost) {
    throw 'Set ONEDROP_MAC_HOST or pass -MacHost (default: ambrus@192.168.31.230).'
}
if ($MacHost -eq 'nova') {
    $MacHost = 'ambrus@192.168.31.230'
    Write-Host "Nova is ambrus@192.168.31.230" -ForegroundColor DarkGray
}
if ($MacRoot -notmatch '^[A-Za-z0-9_./~-]+$') {
    throw 'ONEDROP_MAC_ROOT may contain only letters, numbers, _, ., /, -, and ~.'
}
if (-not (Test-Path -LiteralPath (Join-Path $assets 'packages/aml_ui/pubspec.yaml'))) {
    throw "Missing aml_ui at $assets\packages\aml_ui (needed by One Drop)."
}

$semver = (Get-Content -LiteralPath (Join-Path $root 'version') -Raw).Trim()
if ($semver -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid OneDrop version: $semver" }
$buildDate = [DateTime]::UtcNow.ToString('yyMMdd')
$sourceArchive = Join-Path $env:TEMP 'onedrop-macos-src.tgz'
$uiArchive = Join-Path $env:TEMP 'onedrop-macos-amlui.tgz'
$remoteSrc = '/tmp/onedrop-macos-src.tgz'
$remoteUi = '/tmp/onedrop-macos-amlui.tgz'
$dist = Join-Path $root 'app/dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null

try {
    $wslRoot = ((wsl.exe -d Ubuntu wslpath -a ($root -replace '\\', '/')) -replace "`0", '').Trim()
    $wslSrc = ((wsl.exe -d Ubuntu wslpath -a ($sourceArchive -replace '\\', '/')) -replace "`0", '').Trim()
    $wslUi = ((wsl.exe -d Ubuntu wslpath -a ($uiArchive -replace '\\', '/')) -replace "`0", '').Trim()
    $wslPackages = ((wsl.exe -d Ubuntu wslpath -a ((Join-Path $assets 'packages') -replace '\\', '/')) -replace "`0", '').Trim()
    if (-not $wslRoot -or -not $wslSrc -or -not $wslUi) {
        throw 'WSL path conversion failed for the macOS source archives.'
    }
    $pack = @"
set -euo pipefail
cd '$wslRoot'
tar -czf '$wslSrc' \
  --ignore-failed-read \
  --exclude=app/.dart_tool \
  --exclude=app/build \
  --exclude=app/dist \
  --exclude=app/android/.gradle \
  --exclude=app/android/app/build \
  --exclude=app/windows/flutter/ephemeral \
  --exclude=app/linux/flutter/ephemeral \
  --exclude=app/macos/Flutter/ephemeral \
  --exclude=.plugin_symlinks \
  app packages version scripts
cd '$wslPackages'
tar -czf '$wslUi' --exclude=aml_ui/.dart_tool --exclude=aml_ui/build aml_ui
"@
    $pack = ($pack -replace "`r`n", "`n").Trim()
    & wsl.exe -d Ubuntu -- bash -lc $pack
    if ($LASTEXITCODE -ne 0) { throw 'Could not package One Drop macOS sources.' }

    $wslDist = ((wsl.exe -d Ubuntu wslpath -a ($dist -replace '\\', '/')) -replace "`0", '').Trim()
    $sshHost = if ($MacHost -match 'nova|192\.168\.31\.(130|230)') { 'ambrus@192.168.31.230' } else { $MacHost }
    Write-Host "Uploading sources to ${sshHost} via WSL ssh..." -ForegroundColor Cyan
    & wsl.exe -d Ubuntu -- scp -o StrictHostKeyChecking=accept-new $wslSrc "${sshHost}:${remoteSrc}"
    if ($LASTEXITCODE -ne 0) { throw 'One Drop source upload to macOS failed.' }
    & wsl.exe -d Ubuntu -- scp -o StrictHostKeyChecking=accept-new $wslUi "${sshHost}:${remoteUi}"
    if ($LASTEXITCODE -ne 0) { throw 'aml_ui upload to macOS failed.' }

    $cleanCommand = if ($Clean) { 'rm -rf ~/src/onedrop-macos/app/build' } else { ':' }
    $remoteOneLiner = "set -euo pipefail; mkdir -p ~/src/onedrop-macos ~/src/global-assets/packages; $cleanCommand; tar xzf /tmp/onedrop-macos-src.tgz -C ~/src/onedrop-macos; tar xzf /tmp/onedrop-macos-amlui.tgz -C ~/src/global-assets/packages; sed -i '' 's/\r`$//' ~/src/onedrop-macos/scripts/build-onedrop-macos.sh || true; chmod +x ~/src/onedrop-macos/scripts/build-onedrop-macos.sh; cd ~/src/onedrop-macos; ./scripts/build-onedrop-macos.sh"
    $remoteOneLiner = $remoteOneLiner.Replace("`r`n", "`n").Replace("`r", "")
    & wsl.exe -d Ubuntu -- ssh -o StrictHostKeyChecking=accept-new $sshHost $remoteOneLiner
    if ($LASTEXITCODE -ne 0) { throw 'One Drop macOS build failed.' }

    $patternExact = "onedrop-macos-*-v$semver-$buildDate.dmg"
    $patternAny = "onedrop-macos-*-v$semver-*.dmg"
    $remoteDist = '~/src/onedrop-macos/app/dist'
    & wsl.exe -d Ubuntu -- bash -lc "mkdir -p '$wslDist'; scp -o StrictHostKeyChecking=accept-new '${sshHost}:${remoteDist}/$patternExact' '$wslDist/' || scp -o StrictHostKeyChecking=accept-new '${sshHost}:${remoteDist}/$patternAny' '$wslDist/'"
    if ($LASTEXITCODE -ne 0) { throw 'Could not copy the One Drop macOS disk images.' }
    $artifacts = Get-ChildItem -LiteralPath $dist -Filter $patternAny |
        Sort-Object LastWriteTime -Descending
    $silicon = $artifacts | Where-Object { $_.Name -like 'onedrop-macos-silicon-*' } | Select-Object -First 1
    $intel = $artifacts | Where-Object { $_.Name -like 'onedrop-macos-intel-*' } | Select-Object -First 1
    if (-not $silicon -or -not $intel) {
        throw "Need both silicon and intel DMGs under $dist. Found: $($artifacts.Name -join ', ')"
    }
    Write-Host "One Drop Apple Silicon DMG: $($silicon.FullName)" -ForegroundColor Green
    Write-Host "One Drop Intel DMG: $($intel.FullName)" -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $sourceArchive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $uiArchive -Force -ErrorAction SilentlyContinue
}
