# OneDrop versioning.
#
# The repo-root `version` file holds semver and nothing else. Everything else --
# the pubspec version, the build number the OTA manifest compares, the dart
# defines compiled into the binary, the artifact filenames -- is derived from it
# here, so there is one place to change and no second copy to drift.
#
#   version file    1.0.0
#   build number    10000            major * 10000 + minor * 100 + patch
#   display label   v1.0.0-260812    v<semver>-<yyMMdd>
#
# Dot-source it:  . scripts/version-lib.ps1

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:VersionFile = Join-Path $script:RepoRoot 'version'
$script:PubspecPath = Join-Path $script:RepoRoot 'app/pubspec.yaml'
$script:DartDefinesPath = Join-Path $script:RepoRoot 'app/dart_defines.json'
$script:ServerPackageJson = Join-Path $script:RepoRoot 'server/package.json'
$script:ReleaseBumpLockFile = Join-Path $script:RepoRoot '.release-bump-lock'

function Test-IsWindowsHost {
    # Windows PowerShell 5.1 predates $IsWindows; treat a missing flag as NT.
    if ($null -ne $IsWindows) { return [bool]$IsWindows }
    return $env:OS -eq 'Windows_NT'
}

function Read-PlainTextFile {
    param([Parameter(Mandatory)][string]$Path)
    # Read bytes rather than Get-Content so a stray UTF-8 BOM, which some
    # editors add silently, does not end up inside the version string.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $offset = 3
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset).Trim()
}

function Get-ProjectVersion {
    if (-not (Test-Path -LiteralPath $script:VersionFile)) {
        throw "Missing version file: $script:VersionFile"
    }
    $raw = Read-PlainTextFile -Path $script:VersionFile
    if ($raw -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid version in $script:VersionFile : '$raw' (expected major.minor.patch)"
    }
    return $raw
}

function Get-BuildDateStamp {
    param([datetime]$Now = (Get-Date))
    return $Now.ToString('yyMMdd')
}

function Get-BuildNumber {
    param([string]$SemVer)
    if (-not $SemVer) { $SemVer = Get-ProjectVersion }
    $parts = $SemVer -split '\.'
    if ($parts.Count -ne 3) { throw "Invalid semver: $SemVer" }
    # Minor and patch are limited to two digits each. 1.0.100 would compute to
    # the same number as 1.1.0, and the client would silently offer a downgrade.
    if ([int]$parts[1] -gt 99 -or [int]$parts[2] -gt 99) {
        throw "Version $SemVer cannot be encoded: minor and patch must be under 100."
    }
    return ([int]$parts[0] * 10000) + ([int]$parts[1] * 100) + [int]$parts[2]
}

function Get-BuildLabel {
    param(
        [string]$SemVer,
        [string]$BuildDate
    )
    if (-not $SemVer) { $SemVer = Get-ProjectVersion }
    if (-not $BuildDate) { $BuildDate = Get-BuildDateStamp }
    return "v$SemVer-$BuildDate"
}

function Sync-PubspecVersion {
    param([string]$SemVer)
    if (-not $SemVer) { $SemVer = Get-ProjectVersion }
    if (-not (Test-Path -LiteralPath $script:PubspecPath)) {
        throw "Missing pubspec: $script:PubspecPath"
    }
    $buildNumber = Get-BuildNumber -SemVer $SemVer
    $lines = Get-Content -LiteralPath $script:PubspecPath -Encoding UTF8
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*version:\s*') {
            $lines[$i] = "version: $SemVer+$buildNumber"
            $found = $true
            break
        }
    }
    if (-not $found) { throw "No version: line in $script:PubspecPath" }
    [System.IO.File]::WriteAllLines($script:PubspecPath, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Sync-DartDefinesFile {
    param(
        [string]$SemVer,
        [string]$BuildDate
    )
    if (-not $SemVer) { $SemVer = Get-ProjectVersion }
    if (-not $BuildDate) { $BuildDate = Get-BuildDateStamp }
    # For `flutter run --dart-define-from-file`, so a locally run debug build
    # reports the same version a release build would.
    $payload = (@{
        APP_VERSION    = $SemVer
        APP_BUILD_DATE = $BuildDate
    } | ConvertTo-Json -Compress) + "`n"
    [System.IO.File]::WriteAllText($script:DartDefinesPath, $payload, [System.Text.UTF8Encoding]::new($false))
}

function Get-FlutterVersionDefines {
    param(
        [string]$SemVer,
        [string]$BuildDate
    )
    if (-not $SemVer) { $SemVer = Get-ProjectVersion }
    if (-not $BuildDate) { $BuildDate = Get-BuildDateStamp }
    # Every build has to pass these. Without them kAppVersion falls back to its
    # compile-time default and the published artifact claims to be 1.0.0.
    return @(
        "--dart-define=APP_VERSION=$SemVer",
        "--dart-define=APP_BUILD_DATE=$BuildDate"
    )
}

function Set-ProjectVersion {
    param([Parameter(Mandatory)][string]$SemVer)
    if ($SemVer -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid semver: $SemVer"
    }
    [System.IO.File]::WriteAllText($script:VersionFile, $SemVer, [System.Text.UTF8Encoding]::new($false))
    Sync-PubspecVersion -SemVer $SemVer
    Sync-DartDefinesFile -SemVer $SemVer
}

function Get-NextProjectVersion {
    param([string]$SemVer)
    if (-not $SemVer) { $SemVer = Get-ProjectVersion }
    $parts = $SemVer -split '\.'
    if ($parts.Count -ne 3) { throw "Invalid semver: $SemVer" }
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    $patch = [int]$parts[2]

    # One digit per part: 1.0.9 → 1.1.0, never 1.0.10. Two-digit leftovers also roll.
    if ($patch -ge 9) {
        $patch = 0
        $minor++
        if ($minor -ge 10) {
            $minor = 0
            $major++
        }
    } else {
        $patch++
    }

    return "$major.$minor.$patch"
}

function Bump-ProjectVersion {
    $next = Get-NextProjectVersion -SemVer (Get-ProjectVersion)
    Set-ProjectVersion -SemVer $next

    # The changelog for the release *after* this one becomes the active file the
    # moment the version moves, so there is always somewhere to write.
    . (Join-Path $PSScriptRoot 'changelog-lib.ps1')
    New-ChangelogStub -SemVer (Get-NextProjectVersion -SemVer $next) | Out-Null

    return $next
}

# --- The same-day bump lock -------------------------------------------------
#
# Used only when Invoke-ProjectVersionBump is called *without* -Force. The
# Windows/Ubuntu release orchestrators always pass -Force on publish so every
# published build advances semver (in-app updaters compare build numbers).
# Reuse the current version only with orchestrator -SkipBump: an explicit ask,
# a retry of a never-published build, or a phone sideload via build-onedrop.ps1
# (which does not bump at all).

function Get-ReleaseBumpLock {
    if (-not (Test-Path -LiteralPath $script:ReleaseBumpLockFile)) { return $null }
    try {
        return Get-Content -LiteralPath $script:ReleaseBumpLockFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Set-ReleaseBumpLock {
    param(
        [Parameter(Mandatory)][string]$SemVer,
        [Parameter(Mandatory)][string]$BuildDate
    )
    $payload = @{
        version   = $SemVer
        buildDate = $BuildDate
        bumpedAt  = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($script:ReleaseBumpLockFile, $payload, [System.Text.UTF8Encoding]::new($false))
}

function Clear-ReleaseBumpLock {
    if (Test-Path -LiteralPath $script:ReleaseBumpLockFile) {
        Remove-Item -LiteralPath $script:ReleaseBumpLockFile -Force
    }
}

function Test-ReleaseBumpLockedForToday {
    param([string]$BuildDate)
    if (-not $BuildDate) { $BuildDate = Get-BuildDateStamp }
    $lock = Get-ReleaseBumpLock
    if (-not $lock) { return $false }
    return ($lock.buildDate -eq $BuildDate -and $lock.version -eq (Get-ProjectVersion))
}

function Test-VersionFullyPublished {
    param([Parameter(Mandatory)][string]$SemVer)

    $manifestPath = Join-Path $script:RepoRoot 'data/releases/version.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $false }

    $doc = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # Android and Windows are the two that always ship. If both are published at
    # this version, the release is done and the lock has served its purpose.
    foreach ($key in @('onedropAndroid', 'onedropWindows')) {
        $block = $doc.$key
        if (-not $block -or [string]$block.version -ne $SemVer) { return $false }
    }
    return $true
}

function Invoke-ProjectVersionBump {
    param([switch]$Force)

    $buildDate = Get-BuildDateStamp
    $current = Get-ProjectVersion

    if (Test-VersionFullyPublished -SemVer $current) {
        Clear-ReleaseBumpLock
    }

    if (-not $Force -and (Test-ReleaseBumpLockedForToday -BuildDate $buildDate)) {
        Write-Host "  version -> $current (already bumped today; reusing it)" -ForegroundColor Yellow
        Sync-PubspecVersion -SemVer $current
        Sync-DartDefinesFile -SemVer $current -BuildDate $buildDate
        return $current
    }

    $next = Bump-ProjectVersion
    Set-ReleaseBumpLock -SemVer $next -BuildDate $buildDate
    return $next
}

function Write-VersionFileToDir {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$SemVer,
        [string]$BuildDate
    )
    # A plain label inside the portable folder, for support questions. The app
    # itself reads the compiled-in defines, never this file.
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $label = Get-BuildLabel -SemVer $SemVer -BuildDate $BuildDate
    [System.IO.File]::WriteAllText(
        (Join-Path $Directory 'VERSION.txt'),
        "$label`n",
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-ServerVersion {
    if (-not (Test-Path -LiteralPath $script:ServerPackageJson)) {
        throw "Missing server/package.json: $script:ServerPackageJson"
    }
    foreach ($line in Get-Content -LiteralPath $script:ServerPackageJson) {
        if ($line -match '^\s*"version"\s*:\s*"(\d+\.\d+\.\d+)"') { return $Matches[1] }
    }
    throw "No semver version field in $script:ServerPackageJson"
}

function Set-ServerPackageVersion {
    param([Parameter(Mandatory)][string]$SemVer)
    if ($SemVer -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid semver: $SemVer" }
    $lines = Get-Content -LiteralPath $script:ServerPackageJson
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*"version"\s*:\s*') {
            $lines[$i] = "  `"version`": `"$SemVer`","
            $found = $true
            break
        }
    }
    if (-not $found) { throw "No version field in $script:ServerPackageJson" }
    [System.IO.File]::WriteAllText(
        $script:ServerPackageJson,
        (($lines -join "`n") + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
}
