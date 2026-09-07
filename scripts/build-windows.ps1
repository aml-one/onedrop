<#
.SYNOPSIS
    Builds OneDrop for Windows. Flutter Windows is onedrop.exe plus DLLs and data/.
    Publishes a zip of that portable folder (the store GET / OTA file).
#>
[CmdletBinding()]
param(
    [switch]$SkipPubGet,
    [switch]$SkipBuild,
    [switch]$NoZip,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$AppDir = Join-Path $RepoRoot 'app'
. (Join-Path $RepoRoot 'scripts/version-lib.ps1')

$ReleaseDir = Join-Path $AppDir 'build/windows/x64/runner/Release'
$DistDir = Join-Path $AppDir 'dist'
$PortableDir = Join-Path $DistDir 'OneDrop'

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutterCommand) { throw 'flutter not found on PATH.' }
$flutter = $flutterCommand.Source

Sync-PubspecVersion
$version = Get-ProjectVersion
$buildDate = Get-BuildDateStamp
$label = Get-BuildLabel -SemVer $version -BuildDate $buildDate
$defines = Get-FlutterVersionDefines -SemVer $version -BuildDate $buildDate

Write-Host "OneDrop Windows build  $label"

Push-Location $AppDir
try {
    if ($Clean -and -not $SkipBuild) {
        Write-Step 'flutter clean'
        & $flutter clean
        if ($LASTEXITCODE -ne 0) { throw "flutter clean failed ($LASTEXITCODE)" }
        $SkipPubGet = $false
    }

    if (-not $SkipPubGet) {
        Write-Step 'flutter pub get'
        & $flutter pub get
        if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed ($LASTEXITCODE)" }
    }

    if ($SkipBuild) {
        if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDir 'onedrop.exe'))) {
            throw "No existing release build at $ReleaseDir."
        }
        Write-Host 'Reusing the existing release build.' -ForegroundColor Yellow
    } else {
        Write-Step "flutter build windows --release"
        & $flutter build windows --release @defines
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)" }
    }

    Write-Step 'Packaging the portable folder'
    if (Test-Path -LiteralPath $PortableDir) {
        Remove-Item -LiteralPath $PortableDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $PortableDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $ReleaseDir 'onedrop.exe') -Destination $PortableDir
    Get-ChildItem -LiteralPath $ReleaseDir -Filter '*.dll' |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $PortableDir }
    Copy-Item -LiteralPath (Join-Path $ReleaseDir 'data') -Destination $PortableDir -Recurse
    Write-VersionFileToDir -Directory $PortableDir -SemVer $version -BuildDate $buildDate

    $zipPath = Join-Path $DistDir "onedrop-windows-x64-$label.zip"
    if (-not $NoZip) {
        Write-Step 'Creating the zip'
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        $stage = Join-Path $DistDir '_zip_stage'
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        try {
            Copy-Item -LiteralPath $PortableDir -Destination (Join-Path $stage 'OneDrop') -Recurse
            Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal
        } finally {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Green
    Write-Host "  Run:  $PortableDir\onedrop.exe"
    if (-not $NoZip) { Write-Host "  Zip:  $zipPath" }
} finally {
    Pop-Location
}
