# Release notes, one file per version: changelog/onedrop-changelog-v<semver>
#
# The file matching the *next* version is the one being written to. While
# `version` says 1.0.0 the active file is onedrop-changelog-v1.0.1, because
# 1.0.0's notes describe the release that is already going out.
#
# Publishing reads the entries in file order and embeds them into the manifest,
# so what is written here is what appears on the update screen and the downloads
# page. Nothing else regenerates them later.
#
# Dot-source it:  . scripts/changelog-lib.ps1

if (-not $script:RepoRoot) {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
}
$script:ChangelogDir = Join-Path $script:RepoRoot 'changelog'

function Get-ChangelogPath {
    param([Parameter(Mandatory)][string]$SemVer)
    if ($SemVer -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid semver: $SemVer"
    }
    return Join-Path $script:ChangelogDir "onedrop-changelog-v$SemVer"
}

# The file to write today's work into. Always resolve it rather than working it
# out by hand: the answer depends on the version file, not on which changelog
# happens to be open in the editor.
function Get-ActiveChangelogPath {
    if (-not (Get-Command Get-NextProjectVersion -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'version-lib.ps1')
    }
    return Get-ChangelogPath -SemVer (Get-NextProjectVersion)
}

# Entries for a version, grouped so the update screen reads in a sensible order:
# what is new, then what got better, then what was broken.
function Read-ChangelogEntries {
    param([Parameter(Mandatory)][string]$SemVer)

    $path = Get-ChangelogPath -SemVer $SemVer
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    $features = @()
    $improvements = @()
    $bugfixes = @()
    $security = @()

    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
        if ($line.Trim() -match '^\[(feature|bugfix|improvement|security)\]\s+(.+)$') {
            $entry = "[$($Matches[1])] $($Matches[2])"
            switch ($Matches[1]) {
                'security' { $security += $entry }
                'feature' { $features += $entry }
                'improvement' { $improvements += $entry }
                'bugfix' { $bugfixes += $entry }
            }
        }
    }

    return @($security + $features + $improvements + $bugfixes)
}

function New-ChangelogStub {
    param([Parameter(Mandatory)][string]$SemVer)

    if (-not (Test-Path -LiteralPath $script:ChangelogDir)) {
        New-Item -ItemType Directory -Path $script:ChangelogDir -Force | Out-Null
    }

    $path = Get-ChangelogPath -SemVer $SemVer
    if (Test-Path -LiteralPath $path) { return $path }

    $stub = @"
# v$SemVer

## Features


## Improvements


## Bug fixes


"@
    [System.IO.File]::WriteAllText($path, $stub, [System.Text.UTF8Encoding]::new($false))
    return $path
}

# Warns rather than throws. A release with nothing worth telling users about is
# unusual but legitimate -- a rebuild for a new platform, for instance.
function Test-ChangelogHasEntries {
    param([Parameter(Mandatory)][string]$SemVer)
    $entries = Read-ChangelogEntries -SemVer $SemVer
    if ($entries.Count -eq 0) {
        Write-Warning "changelog/onedrop-changelog-v$SemVer has no entries; the update screen will show no release notes."
        return $false
    }
    return $true
}
