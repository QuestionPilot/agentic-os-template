#Requires -Version 7
<#
.SYNOPSIS
    install-lineark.ps1 — pinned, checksum-verified installer for the OPTIONAL
    `lineark` CLI (the framework's default active-work tracker surface; see
    linear/linear-setup.md §3.2). PowerShell twin of scripts/install-lineark.sh.

.DESCRIPTION
    WHY THIS EXISTS. Upstream documents a `curl … | sh` install, and the
    framework used to reproduce that instruction verbatim. That pattern hands
    whatever the host serves at request time straight to a shell: no pinned
    version, no integrity check, no reviewable artifact. This script replaces it
    with the ordinary supply-chain shape:

      1. PIN a release tag (never "whatever main serves right now").
      2. Download the release ASSET to a throwaway dir — never into a shell.
      3. VERIFY its sha256 against an operator-reviewed pin file BEFORE the file
         is made executable or moved anywhere near PATH, and RE-VERIFY it in
         place after the move, before it is ever executed.
      4. SMOKE the installed binary and require it to report EXACTLY the pinned
         version.

    Upstream publishes tagged releases with raw binaries and NO checksum
    manifest, so the framework maintains its own: scripts/lineark-checksums.sha256,
    keyed `<tag>/<asset>`. A tag with no entry is an UNVETTED release and this
    script refuses to install it — that refusal is the whole point of the pin
    file, so it is loud and has no override switch. Vetting a new release is a
    documented procedure (linear/linear-setup.md §3.2, "Updating / re-vetting a
    new release").

    ACCEPTED RESIDUAL RISK. The ambient PATH and environment are TRUSTED INPUT
    here — the same trust boundary the README documents for every framework
    script — and invoking this script through an attacker-placed symlink
    relocates the default checksum file along with it (the trust-root warning
    below only fires when the overrides are set explicitly, so it does not cover
    the symlink case).

    WINDOWS. Upstream ships no Windows binary. On Windows this script exits 3
    (the unsupported-platform code) and names the two alternatives: build from
    source with `cargo install lineark`, or use the Linear MCP surface instead
    (linear/linear-setup.md §3.3). On macOS and Linux under pwsh it implements
    the same pin + checksum + smoke contract as the .sh twin and honors the same
    environment overrides.

    Nothing here is required to run the framework. `lineark` is optional; the
    spine capabilities degrade to a one-line warning when no tracker surface is
    present.

    Environment overrides (all optional, identical to the .sh twin):
      LINEARK_VERSION        release tag to install. Default: the pin below.
                             Must match ^v?[A-Za-z0-9._-]+$ — no slashes, no
                             whitespace, so it can never escape its own key in
                             the pin file. Also the rollback lever — an older tag
                             still listed in the checksum file installs unchanged.
      LINEARK_CHECKSUM_FILE  path to the pin file. Default: the sibling
                             scripts/lineark-checksums.sha256.
      LINEARK_BASE_URL       release-download base. Default: the upstream GitHub
                             releases base. Only https:// and file:// are
                             accepted (the hermetic tests point this at a file://
                             mirror so they never touch the network).
      LINEARK_INSTALL_DIR    install destination. Default: $HOME/.local/bin.

    Setting LINEARK_CHECKSUM_FILE or LINEARK_BASE_URL moves the TRUST ROOT off
    the repo's reviewed defaults, so each one prints a WARNING naming the
    override before anything is downloaded. Installing any tag other than the
    default pin prints a note — a silent downgrade to an older, withdrawn
    release is exactly what that line is there to make visible.

.PARAMETER Help
    Print this help and exit 0.

.NOTES
    Exit codes:
        0 — installed and the version smoke matched the pinned tag EXACTLY
        1 — install refused or failed (unvetted tag, conflicting pin entries,
            checksum mismatch, download failure, smoke mismatch). NOTHING
            executable is left behind.
        2 — usage or configuration error (unknown argument, malformed
            LINEARK_VERSION, disallowed LINEARK_BASE_URL scheme)
        3 — unsupported platform (upstream ships no binary for it)

    Tests: tests/install-lineark.test.ps1 (+ the .sh twin).
#>

[CmdletBinding()]
param(
    [Alias('h')][switch]$Help,

    # Any other argument is a usage error. Collected rather than bound so a
    # POSIX-style flag cannot be silently prefix-matched onto -Help by the
    # PowerShell binder.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Help.IsPresent) {
    Get-Help -Full $PSCommandPath | Out-String | Write-Host
    exit 0
}

foreach ($arg in $Rest) {
    if ($arg -eq '-h' -or $arg -eq '--help') {
        Get-Help -Full $PSCommandPath | Out-String | Write-Host
        exit 0
    }
    [Console]::Error.WriteLine("FAIL unknown argument: $arg (this installer takes no flags — configure it with the LINEARK_* environment variables; -Help lists them)")
    exit 2
}

# The pinned default lives here and ONLY here (mirrors the .sh twin).
$LinearkDefaultVersion = 'v3.1.0'

$selfDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Get-EnvOrDefault {
    param([string]$Name, [string]$Default)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($v)) { return $Default }
    return $v
}

$defaultChecksumFile = Join-Path $selfDir 'lineark-checksums.sha256'
$defaultBaseUrl = 'https://github.com/flipbit03/lineark/releases/download'

$version      = Get-EnvOrDefault 'LINEARK_VERSION'       $LinearkDefaultVersion
$checksumFile = Get-EnvOrDefault 'LINEARK_CHECKSUM_FILE' $defaultChecksumFile
$baseUrl      = Get-EnvOrDefault 'LINEARK_BASE_URL'      $defaultBaseUrl
$defaultInstallDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local' 'bin'
$installDir   = Get-EnvOrDefault 'LINEARK_INSTALL_DIR'   $defaultInstallDir

$revetPointer = 'linear/linear-setup.md §3.2 ("Updating / re-vetting a new release")'
$mcpPointer   = 'linear/linear-setup.md §3.3 (Linear MCP)'

# --- 0. Input guards and trust-root transparency -----------------------------
# The tag becomes a path segment in the download URL and the lookup key. Anything
# with a slash or whitespace could point the fetch at an unrelated path or split
# the key, so the shape is constrained before it is used anywhere.
if ($version -notmatch '^v?[A-Za-z0-9._-]+$') {
    [Console]::Error.WriteLine("FAIL malformed LINEARK_VERSION: $version")
    [Console]::Error.WriteLine('A release tag must match ^v?[A-Za-z0-9._-]+$ — no slashes, no whitespace.')
    exit 2
}

if (-not ($baseUrl.StartsWith('https://') -or $baseUrl.StartsWith('file://'))) {
    [Console]::Error.WriteLine("FAIL disallowed LINEARK_BASE_URL scheme: $baseUrl")
    [Console]::Error.WriteLine('Only https:// and file:// are accepted. Plain http:// is refused outright — an unencrypted fetch is exactly the transport this installer exists to stop trusting.')
    exit 2
}

# A non-default checksum file or base URL means the operator (or something in the
# environment) has moved the trust root off the repo's reviewed defaults. That is
# supported — the hermetic tests depend on it — but it is never silent.
if ($checksumFile -ne $defaultChecksumFile) {
    [Console]::Error.WriteLine("WARNING non-default trust root: LINEARK_CHECKSUM_FILE=$checksumFile")
}
if ($baseUrl -ne $defaultBaseUrl) {
    [Console]::Error.WriteLine("WARNING non-default trust root: LINEARK_BASE_URL=$baseUrl")
}
if ($version -ne $LinearkDefaultVersion) {
    Write-Host "note: installing non-default tag $version (current default: $LinearkDefaultVersion)"
}

# --- 1. Platform -> upstream asset name -------------------------------------
# Mirrors the asset set upstream actually publishes. Anything else is a hard
# stop with the two documented alternatives, not a best-effort guess.
$archName = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$asset = ''
if ($IsWindows) {
    $asset = ''
} elseif ($IsLinux) {
    switch ($archName) {
        'X64'   { $asset = 'lineark_linux_x86_64' }
        'Arm64' { $asset = 'lineark_linux_aarch64' }
    }
} elseif ($IsMacOS) {
    if ($archName -eq 'Arm64') { $asset = 'lineark_macos_aarch64' }
}

if ([string]::IsNullOrEmpty($asset)) {
    $osLabel = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } elseif ($IsLinux) { 'Linux' } else { 'unknown' }
    [Console]::Error.WriteLine("FAIL unsupported platform: $osLabel/$archName — upstream publishes no prebuilt lineark binary for it.")
    [Console]::Error.WriteLine('Alternatives:')
    [Console]::Error.WriteLine('  - build from source:  cargo install lineark')
    [Console]::Error.WriteLine("  - use the other tracker surface instead: $mcpPointer")
    exit 3
}

$key = "$version/$asset"

# --- 2. Expected checksum from the operator-reviewed pin file ----------------
if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) {
    [Console]::Error.WriteLine("FAIL checksum pin file not found: $checksumFile")
    [Console]::Error.WriteLine("Without it no release can be verified. Restore it from the repo, or point LINEARK_CHECKSUM_FILE at a reviewed copy. See $revetPointer.")
    exit 1
}

# Get-LinearkSha256 — a file's lowercase sha256.
function Get-LinearkSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Get-LinearkPinMatches — one [pscustomobject]@{Line; Sha} per pin entry whose
# key matches, in file order. Comment (`#`) and blank lines are skipped; the
# format is `<sha>  <tag>/<asset>`.
#
# Normalization is load-bearing for TWIN PARITY: a pin file saved with CRLF line
# endings, or an entry with trailing spaces, must resolve identically here and in
# the bash twin. The two twins disagreeing about which releases are vetted is
# worse than either behavior alone.
function Get-LinearkPinMatches {
    param([string]$Path, [string]$Key)
    $out = @()
    $n = 0
    foreach ($raw in [System.IO.File]::ReadAllLines($Path)) {
        $n++
        $line = $raw.TrimEnd([char]13).Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $parts = $line -split '\s+', 2
        if ($parts.Count -lt 2) { continue }
        if ($parts[1].Trim() -ne $Key) { continue }
        $out += [pscustomobject]@{ Line = $n; Sha = $parts[0].ToLowerInvariant() }
    }
    return , $out
}

$pinMatches = Get-LinearkPinMatches -Path $checksumFile -Key $key

if ($pinMatches.Count -eq 0) {
    [Console]::Error.WriteLine("FAIL unvetted release: no checksum entry for $key in $checksumFile")
    [Console]::Error.WriteLine("An unvetted release is never installed. To adopt this tag, follow the re-vet procedure in ${revetPointer}: review the upstream release, download the assets, compute their sha256 locally, append the entries, then re-run.")
    exit 1
}

# CONFLICTING PINS. Two entries for one key with DIFFERENT hashes means the pin
# file cannot say what the vetted artifact is, and "first match wins" would let
# an appended line silently decide. Identical duplicates are harmless (a merge
# artifact), so only differing shas refuse.
$distinct = @($pinMatches | ForEach-Object { $_.Sha } | Sort-Object -Unique)
if ($distinct.Count -gt 1) {
    $conflictLines = ($pinMatches | ForEach-Object { $_.Line }) -join ' '
    [Console]::Error.WriteLine("FAIL conflicting pin entries for $key in $checksumFile")
    [Console]::Error.WriteLine("  $($pinMatches.Count) entries with $($distinct.Count) different sha256 values, at line(s): $conflictLines")
    [Console]::Error.WriteLine("The pin file cannot say which artifact is vetted. Resolve the conflict by hand — see $revetPointer — then re-run. Nothing was installed.")
    exit 1
}

$expected = $pinMatches[0].Sha

# --- 3. Download to a throwaway dir (never into a shell) ---------------------
# Unique creation, never -Force: -Force on a predictable path silently REUSES an
# existing directory, so anything an attacker pre-created (or pre-populated)
# would become the staging area for a binary about to be made executable. Create
# fresh or fail.
$work = $null
for ($attempt = 0; $attempt -lt 5; $attempt++) {
    $candidate = Join-Path ([IO.Path]::GetTempPath()) ('lineark-install-' + (New-Guid).Guid)
    if (Test-Path -LiteralPath $candidate) { continue }
    try {
        New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
        $work = $candidate
        break
    } catch {
        continue
    }
}
if ($null -eq $work) {
    [Console]::Error.WriteLine('FAIL could not create a fresh temporary directory after 5 attempts — refusing to reuse an existing one. Nothing was installed.')
    exit 1
}

$url = "$baseUrl/$version/$asset"
$artifact = Join-Path $work $asset

Write-Host "lineark: installing $version ($asset)"
Write-Host "lineark: fetching $url"
try {
    if ($url.StartsWith('file://')) {
        # Invoke-WebRequest's file:// support is inconsistent across platforms;
        # a direct copy is the same operation with none of the ambiguity, and it
        # is what the hermetic tests exercise.
        $src = [Uri]::new($url).LocalPath
        Copy-Item -LiteralPath $src -Destination $artifact -Force
    } else {
        Invoke-WebRequest -Uri $url -OutFile $artifact -UseBasicParsing
    }
} catch {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine("FAIL download failed: $url")
    [Console]::Error.WriteLine('Check network access and that the tag exists upstream. Nothing was installed.')
    exit 1
}

# --- 4. Verify BEFORE chmod / move ------------------------------------------
$actual = Get-LinearkSha256 -Path $artifact

if ($expected -ne $actual) {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine("FAIL checksum mismatch for $key")
    [Console]::Error.WriteLine("  expected: $expected")
    [Console]::Error.WriteLine("  actual:   $actual")
    [Console]::Error.WriteLine("The downloaded artifact was deleted and NOTHING was installed. Either the release was re-cut upstream (re-vet it per $revetPointer) or the download is not what the pin file describes — treat the second case as hostile until proven otherwise.")
    exit 1
}

Write-Host "lineark: sha256 verified ($actual)"

# --- 5. Install --------------------------------------------------------------
$dest = Join-Path $installDir 'lineark'
if (-not (Test-Path -LiteralPath $installDir -PathType Container)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}
if (-not $IsWindows) { & chmod +x $artifact }
Move-Item -LiteralPath $artifact -Destination $dest -Force
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "lineark: installed $dest"

# --- 6. RE-VERIFY IN PLACE, before the binary is ever executed ---------------
# The hash in §4 was computed on the file in the temp dir. Between that read and
# the `--version` call in §7 the bytes at $dest are a DIFFERENT object as far as
# the security argument goes: a cross-volume Move-Item is a copy that re-reads
# the source, the destination directory may be writable by someone else, and
# $dest may already have existed. Re-hashing what is actually about to be
# executed closes that verify -> move -> execute window.
$destActual = Get-LinearkSha256 -Path $dest
if ($expected -ne $destActual) {
    Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine("FAIL post-install checksum mismatch for $dest")
    [Console]::Error.WriteLine("  expected: $expected")
    [Console]::Error.WriteLine("  actual:   $destActual")
    [Console]::Error.WriteLine('The installed file does not match what was verified before the move — it was removed and NOT executed. Treat the install directory as untrusted until you know why.')
    exit 1
}

Write-Host 'lineark: post-install sha256 re-verified in place'

# --- 7. Version smoke --------------------------------------------------------
# The checksum proves the bytes match the pin; this proves the pin describes the
# release it claims to. EXACT equality, not a substring: `lineark 13.1.0` contains
# "3.1.0", so a substring test would wave through a completely different release.

# Get-LinearkVersionToken — the first whitespace-separated token that starts with
# a digit ("lineark 3.1.0" -> "3.1.0"), or ''.
function Get-LinearkVersionToken {
    param([string]$Text)
    foreach ($tok in ($Text -split '\s+')) {
        $t = $tok.Trim([char]13).Trim()
        if ($t -match '^[0-9]') { return $t }
    }
    return ''
}

$want = $version -replace '^v', ''
$versionOut = ''
try { $versionOut = (& $dest '--version' 2>&1 | Out-String).Trim() } catch { $versionOut = "$_" }
Write-Host "lineark: $versionOut"
$versionToken = Get-LinearkVersionToken -Text $versionOut

if ($versionToken -cne $want) {
    Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    $shown = if ($versionToken -eq '') { '<none>' } else { $versionToken }
    [Console]::Error.WriteLine("FAIL version smoke failed: installed binary does not report the pinned version $want")
    [Console]::Error.WriteLine("  --version said: $versionOut")
    [Console]::Error.WriteLine("  parsed version: $shown (exact match against $want required)")
    [Console]::Error.WriteLine("The binary was removed. The checksum entry for $key likely describes a different release — re-vet per $revetPointer.")
    exit 1
}

$pathSep = if ($IsWindows) { ';' } else { ':' }
$pathParts = ($env:PATH -split [regex]::Escape($pathSep))
if ($pathParts -notcontains $installDir) {
    [Console]::Error.WriteLine("lineark: $installDir is not on PATH. Add it, e.g.:")
    [Console]::Error.WriteLine('  export PATH="' + $installDir + ':$PATH"')
}

Write-Host "PASS lineark $version installed and verified"
Write-Host 'Next: provide the API token (linear/linear-setup.md §3.2) and run `lineark whoami`.'
exit 0
