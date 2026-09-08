# Publishing a built artifact to Frankfurt and merging it into the OTA manifest.
#
# The order matters and is not negotiable: upload the file first, then merge the
# manifest that points at it. Doing it the other way round leaves a window where
# every client that checks for updates is told about a build that is not there
# yet, downloads a 404, and reports a failed update.
#
# Dot-source it:  . scripts/publish-lib.ps1

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'version-lib.ps1')
. (Join-Path $PSScriptRoot 'changelog-lib.ps1')

$script:DefaultRemoteReleasesDir = '/home/ambrus/www/aml/onedrop.aml.one/downloads'
$script:DefaultSshHost = 'ambrus@frankfurt.aml.one'
$script:DefaultSshPort = 717
# Store clients (and this host) fetch OTA via the aml.one path. The dedicated
# onedrop.aml.one hostname is Caddy-ready, but DNS is not always present.
$script:DownloadsUrl = 'https://aml.one/onedrop-ota'
$script:DownloadsPageUrl = 'https://aml.one/onedrop-ota'

$script:PlatformKeys = @(
    'onedropAndroid',
    'onedropWindows',
    'onedropMacos',
    'onedropMacosIntel',
    'onedropLinux',
    'onedropUbuntuTouch'
)

# Artifact names are the contract between the builders, the publisher and the
# manifest. Checking them here means a mislabelled build is caught before it is
# uploaded rather than after a client has downloaded it.
$script:ArtifactPatterns = @{
    onedropAndroid     = '^onedrop-android-(arm64|universal)-v\d+\.\d+\.\d+-\d{6}\.apk$'
    onedropWindows     = '^onedrop-windows-x64-v\d+\.\d+\.\d+-\d{6}\.zip$'
    onedropMacos       = '^onedrop-macos-silicon-v\d+\.\d+\.\d+-\d{6}\.dmg$'
    onedropMacosIntel  = '^onedrop-macos-intel-v\d+\.\d+\.\d+-\d{6}\.dmg$'
    onedropLinux       = '^onedrop-linux-x64-v\d+\.\d+\.\d+-\d{6}\.deb$'
    onedropUbuntuTouch = '^onedrop-ubuntu-touch-arm64-v\d+\.\d+\.\d+-\d{6}\.tar\.gz$'
}

function Get-OpenSshBin {
    param([Parameter(Mandatory)][ValidateSet('ssh', 'scp')][string]$Name)

    # Prefer Windows' own OpenSSH over anything a shell alias or a Git-for-
    # Windows copy might resolve to, because those disagree about path quoting.
    if (Test-IsWindowsHost) {
        $system = Join-Path $env:WINDIR "System32/OpenSSH/$Name.exe"
        if (Test-Path -LiteralPath $system) { return $system }
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { throw "$Name not found on PATH." }
    return $command.Source
}

function Get-PublishSshTarget {
    param(
        [string]$SshTarget = $env:ONEDROP_SSH,
        # 0 means "unset": callers often pass an unbound [int]$SshPort which is 0
        # in PowerShell, and that must not override the real default (717).
        [int]$SshPort = 0
    )
    if (-not $SshTarget) { $SshTarget = $script:DefaultSshHost }
    if ($SshPort -le 0) {
        $SshPort = if ($env:ONEDROP_SSH_PORT -and [int]$env:ONEDROP_SSH_PORT -gt 0) {
            [int]$env:ONEDROP_SSH_PORT
        } else {
            $script:DefaultSshPort
        }
    }
    return @{ Target = $SshTarget; Port = $SshPort }
}

function Invoke-ScpUpload {
    param(
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$RemoteDest
    )

    $localResolved = (Resolve-Path -LiteralPath $LocalPath).ProviderPath
    # Quoting the remote side keeps Windows scp from reading the colon in
    # user@host:path as a drive letter.
    $remoteSpec = if ($RemoteDest -match '^\w+@') { $RemoteDest } else { "${Target}:`"${RemoteDest}`"" }

    & (Get-OpenSshBin -Name scp) -P $Port -o StrictHostKeyChecking=accept-new $localResolved $remoteSpec
    if ($LASTEXITCODE -ne 0) { throw "scp failed ($LASTEXITCODE)" }
}

function Invoke-SshRemote {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$RemoteCommand
    )
    # PowerShell here-strings are CRLF on Windows. Bash then sees `exit 1\r` and
    # dies with "numeric argument required", so strip CR before the call.
    $command = $RemoteCommand -replace "`r`n", "`n" -replace "`r", ""
    & (Get-OpenSshBin -Name ssh) -p $Port -o StrictHostKeyChecking=accept-new $Target $command
    if ($LASTEXITCODE -ne 0) { throw "ssh failed ($LASTEXITCODE)" }
}

function Invoke-RemoteBashScript {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$ScriptBody
    )

    # Fed over stdin rather than passed as an argument, so a multi-line script
    # does not have to survive two levels of shell quoting.
    #
    # LF endings are not cosmetic here: a CRLF in the body makes bash read
    # `set -euo pipefail\r` and fail with an unhelpful error about a command
    # named `pipefail\r`.
    $text = ($ScriptBody -replace "`r`n", "`n").TrimEnd() + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-OpenSshBin -Name ssh
    $startInfo.Arguments = "-p $Port -o StrictHostKeyChecking=accept-new $Target bash -s"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdin = $process.StandardInput.BaseStream
        $stdin.Write($bytes, 0, $bytes.Length)
        $stdin.Flush()
        $process.StandardInput.Close()

        $out = $process.StandardOutput.ReadToEnd()
        $err = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        if ($out) { Write-Host $out }
        if ($err) { Write-Host $err -ForegroundColor Yellow }
        if ($process.ExitCode -ne 0) {
            throw "Remote script failed (exit $($process.ExitCode))."
        }
    } finally {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-ReleaseFromFilename {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Platform
    )

    if (-not $script:ArtifactPatterns.ContainsKey($Platform)) {
        throw "Unknown platform key '$Platform'. OneDrop publishes only: $($script:PlatformKeys -join ', ')"
    }
    if ($FileName -notmatch $script:ArtifactPatterns[$Platform]) {
        throw "'$FileName' is not a valid $Platform artifact name. Expected $($script:ArtifactPatterns[$Platform])"
    }

    $null = $FileName -match 'v(\d+\.\d+\.\d+)-(\d{6})\.'
    $semver = $Matches[1]
    $buildDate = $Matches[2]

    if ($semver -eq '1.0.0' -and (Get-ProjectVersion) -ne '1.0.0') {
        throw "'$FileName' says v1.0.0, which is what a build without the version defines produces. Rebuild through the scripts."
    }

    return @{
        version     = $semver
        buildNumber = Get-BuildNumber -SemVer $semver
        label       = "v$semver-$buildDate"
        publishedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Invoke-ReleaseManifestPython {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Quiet
    )
    $script = Join-Path $PSScriptRoot 'release-manifest.py'
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Missing release manifest script: $script"
    }
    $python = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
    if ($Quiet) { & $python $script @Arguments | Out-Null } else { & $python $script @Arguments }
    if ($LASTEXITCODE -ne 0) { throw "release-manifest.py failed ($LASTEXITCODE)" }
}

function New-ReleaseEntryJson {
    param([Parameter(Mandatory)][hashtable]$Entry)

    $payload = [ordered]@{
        platform    = [string]$Entry.platform
        version     = [string]$Entry.version
        buildNumber = [int]$Entry.buildNumber
        label       = [string]$Entry.label
        file        = [string]$Entry.file
        sizeBytes   = [long]$Entry.sizeBytes
        sha256      = [string]$Entry.sha256
        publishedAt = [string]$Entry.publishedAt
    }
    if ($Entry.changelog) {
        # [object[]] so a one-line changelog stays a JSON array. ConvertTo-Json
        # flattens a single-element array to a bare string otherwise, which then
        # fails validation on the far side.
        $payload.changelog = [object[]]@($Entry.changelog)
    }

    # The entry is round-tripped through Python rather than written by
    # ConvertTo-Json directly, so what lands on disk is the same shape the
    # manifest merger will read back.
    $temp = [System.IO.Path]::GetTempFileName()
    try {
        $json = ($payload | ConvertTo-Json -Compress -Depth 6)
        $env:ENTRY_B64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
        Invoke-ReleaseManifestPython -Arguments @('write-entry-b64', $temp) -Quiet
        Invoke-ReleaseManifestPython -Arguments @('validate-entry', $temp) -Quiet
        return $temp
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        Remove-Item Env:ENTRY_B64 -ErrorAction SilentlyContinue
    }
}

function Merge-LocalReleaseManifest {
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [string]$Dir = (Join-Path $script:RepoRoot 'data/releases')
    )
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $entryPath = New-ReleaseEntryJson -Entry $Entry
    try {
        Invoke-ReleaseManifestPython -Arguments @('merge', $Dir, $entryPath)
    } finally {
        Remove-Item -LiteralPath $entryPath -Force -ErrorAction SilentlyContinue
    }
}

function Merge-RemoteReleaseManifest {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$RemoteReleasesDir,
        [Parameter(Mandatory)][string]$EntryJsonPath
    )

    $remoteDir = $RemoteReleasesDir.TrimEnd('/')
    $remotePy = '/tmp/onedrop-release-manifest.py'
    $remoteEntry = '/tmp/onedrop-release-entry.json'

    Invoke-SshRemote -Target $Target -Port $Port -RemoteCommand "mkdir -p '$remoteDir'"
    Invoke-ScpUpload -LocalPath (Join-Path $PSScriptRoot 'release-manifest.py') `
        -Target $Target -Port $Port -RemoteDest $remotePy
    Invoke-ScpUpload -LocalPath $EntryJsonPath -Target $Target -Port $Port -RemoteDest $remoteEntry
    # Merge and validate in one command: a merge that leaves the manifest
    # invalid must fail the publish, not be discovered later.
    Invoke-SshRemote -Target $Target -Port $Port -RemoteCommand `
        "python3 '$remotePy' merge '$remoteDir' '$remoteEntry' && python3 '$remotePy' validate '$remoteDir' --artifacts"
}

function Assert-ReleaseManifestsValid {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [switch]$Artifacts
    )
    $arguments = @('validate', $Dir)
    if ($Artifacts) { $arguments += '--artifacts' }
    Invoke-ReleaseManifestPython -Arguments $arguments
}

function Assert-RemoteReleaseManifestsValid {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$RemoteReleasesDir
    )
    $remotePy = '/tmp/onedrop-release-manifest.py'
    Invoke-ScpUpload -LocalPath (Join-Path $PSScriptRoot 'release-manifest.py') `
        -Target $Target -Port $Port -RemoteDest $remotePy
    # --artifacts re-hashes every published file on the server. That is the
    # check that catches a truncated upload, so it is never skipped.
    Invoke-SshRemote -Target $Target -Port $Port -RemoteCommand `
        "python3 '$remotePy' validate '$RemoteReleasesDir' --artifacts"
}

function Assert-DownloadsPageLive {
    param(
        [string]$ManifestUrl = $script:DownloadsUrl,
        [string]$PageUrl = $script:DownloadsPageUrl
    )
    # OTA clients read version.json / releases.json. There is no family hub HTML
    # page for OneDrop yet, so skip the HTML branding check.
    [void]$PageUrl
    Invoke-ReleaseManifestPython -Arguments @('check-manifests', $ManifestUrl)
}

function Publish-ClientRelease {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][ValidateSet(
            'onedropAndroid', 'onedropWindows', 'onedropMacos',
            'onedropMacosIntel', 'onedropLinux', 'onedropUbuntuTouch'
        )][string]$Platform,
        [string]$RemoteReleasesDir = $script:DefaultRemoteReleasesDir,
        [string]$SshTarget,
        [int]$SshPort,
        [switch]$SkipVerify
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "File not found: $FilePath"
    }

    $ssh = Get-PublishSshTarget -SshTarget $SshTarget -SshPort $SshPort
    $fileName = Split-Path -Leaf $FilePath
    $meta = Read-ReleaseFromFilename -FileName $fileName -Platform $Platform
    $info = Get-Item -LiteralPath $FilePath

    $entry = @{
        platform    = $Platform
        version     = $meta.version
        buildNumber = $meta.buildNumber
        label       = $meta.label
        file        = $fileName
        sizeBytes   = [long]$info.Length
        sha256      = Get-FileSha256Hex -Path $FilePath
        publishedAt = $meta.publishedAt
    }

    $changelog = Read-ChangelogEntries -SemVer $meta.version
    if ($changelog.Count -gt 0) {
        $entry.changelog = [string[]]$changelog
    } else {
        Write-Warning "No changelog entries for v$($meta.version); the update screen will show none."
    }

    $sizeMb = [math]::Round($info.Length / 1MB, 1)
    Write-Host "Uploading $fileName ($sizeMb MB) -> $($ssh.Target):$RemoteReleasesDir" -ForegroundColor Cyan

    $remoteDir = $RemoteReleasesDir.TrimEnd('/')
    Invoke-SshRemote -Target $ssh.Target -Port $ssh.Port -RemoteCommand "mkdir -p '$remoteDir'"

    # Uploaded under a temporary name and moved into place, so a client cannot
    # fetch a half-written file the moment the manifest starts pointing at it.
    Invoke-ScpUpload -LocalPath $FilePath -Target $ssh.Target -Port $ssh.Port `
        -RemoteDest "$remoteDir/$fileName.uploading"
    Invoke-SshRemote -Target $ssh.Target -Port $ssh.Port -RemoteCommand `
        "mv '$remoteDir/$fileName.uploading' '$remoteDir/$fileName' && chmod 644 '$remoteDir/$fileName'"

    $entryPath = New-ReleaseEntryJson -Entry $entry
    try {
        Merge-RemoteReleaseManifest -Target $ssh.Target -Port $ssh.Port `
            -RemoteReleasesDir $RemoteReleasesDir -EntryJsonPath $entryPath
    } finally {
        Remove-Item -LiteralPath $entryPath -Force -ErrorAction SilentlyContinue
    }

    # The local copy is what the dev site reads, and what tells the next release
    # whether this version was fully published.
    Merge-LocalReleaseManifest -Entry $entry

    if (-not $SkipVerify) {
        Invoke-SshRemote -Target $ssh.Target -Port $ssh.Port -RemoteCommand `
            "if [ -x /home/ambrus/apps/messageme/scripts/drop-missing-download-links.sh ]; then bash /home/ambrus/apps/messageme/scripts/drop-missing-download-links.sh; fi"
        Assert-DownloadsPageLive
    }

    Write-Host "Published $Platform $($meta.label)" -ForegroundColor Green
}
