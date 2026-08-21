#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/install-linear-cli.test.ps1 — Windows-native twin of
# tests/install-linear-cli.test.sh.
#
# Behavioral tests for scripts/install-linear-cli.ps1, the pinned
# checksum-verified installer for the `linear` CLI (schpet/linear-cli) that
# succeeds the retired lineark installer. What is under test is the REFUSAL
# contract, because that is the whole reason the script exists:
#
#   - correct checksum              -> installs, version smoke passes, exit 0
#   - checksum MISMATCH             -> exit 1, artifact deleted, nothing
#                                      installed, expected vs actual printed
#   - tag ABSENT from the pin file  -> exit 1, "unvetted release", nothing
#                                      installed, re-vet procedure named
#   - version smoke MISMATCH        -> exit 1, the binary removed again
#
# NEW versus the lineark suite: the release asset is an ARCHIVE (zip on Windows,
# tar.xz on macOS/Linux) containing the binary, so the archive-shape refusals
# are pinned too — an archive holding TWO candidate binaries and an archive
# holding NONE are both exit 1 ("expected exactly one"), never a guess.
#
# HERMETIC. No network: the release mirror is a local directory served through
# `file://`. On Windows the installed binname is linear.exe and the PS twin
# EXECUTES it as a Win32 process, so a shebang shell script cannot stand in the
# way it does for the bash twin — the fake binary is a tiny C# program compiled
# on the fly with the .NET Framework csc.exe every Windows box ships. On
# macOS/Linux pwsh the stand-in stays a /bin/sh script, like the lineark suite.
# EVERY invocation pins LINEAR_CLI_VERSION, LINEAR_CLI_CHECKSUM_FILE,
# LINEAR_CLI_BASE_URL and LINEAR_CLI_INSTALL_DIR, so the operator's real pin
# file, real install dir and real network are never reachable from this suite.
#
# TWIN DIVERGENCE. The bash twin forces the unsupported-platform branch on every
# host by stubbing `uname` ahead of the script's PATH. The PS twin resolves its
# platform from RuntimeInformation, which no PATH entry can shadow — and unlike
# lineark, upstream ships a Windows binary, so on every host this suite supports
# the platform IS supported and the unsupported branch is a named skip.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$LC_SCRIPT = Join-Path $env:REPO_ROOT 'scripts' 'install-linear-cli.ps1'
$LC_SUMS_REAL = Join-Path $env:REPO_ROOT 'scripts' 'linear-cli-checksums.sha256'

Assert-File 'install-linear-cli.test: scripts/install-linear-cli.ps1 exists' $LC_SCRIPT
Assert-File 'install-linear-cli.test: scripts/linear-cli-checksums.sha256 exists' $LC_SUMS_REAL
Assert-File 'install-linear-cli.test: the bash twin exists' (Join-Path $env:REPO_ROOT 'scripts' 'install-linear-cli.sh')

function New-LcTempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('lc-test-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Write-LcFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-LcSha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Get-LcFileUrl — a file:// URL the installer's [Uri]::LocalPath handling maps
# back to this exact directory on every platform (Windows paths need the
# file:///C:/... form).
function Get-LcFileUrl {
    param([string]$Path)
    return ([Uri]::new((Get-Item -LiteralPath $Path).FullName)).AbsoluteUri
}

$LC_TMP = New-LcTempDir
$LC_VER = 'v9.9.9'

# --- host -> asset name + binname, mirroring the script's own platform map ---
$LC_ARCH = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$LC_ASSET = ''
$LC_BIN = 'linear'
if ($IsWindows) {
    if ($LC_ARCH -eq 'X64') { $LC_ASSET = 'linear-x86_64-pc-windows-msvc.zip'; $LC_BIN = 'linear.exe' }
} elseif ($IsLinux) {
    if ($LC_ARCH -eq 'X64') { $LC_ASSET = 'linear-x86_64-unknown-linux-gnu.tar.xz' }
    elseif ($LC_ARCH -eq 'Arm64') { $LC_ASSET = 'linear-aarch64-unknown-linux-gnu.tar.xz' }
} elseif ($IsMacOS) {
    if ($LC_ARCH -eq 'Arm64') { $LC_ASSET = 'linear-aarch64-apple-darwin.tar.xz' }
    elseif ($LC_ARCH -eq 'X64') { $LC_ASSET = 'linear-x86_64-apple-darwin.tar.xz' }
}

# --- fake-binary factory -----------------------------------------------------
# On Windows the installed file is EXECUTED as a Win32 process, so the stand-in
# must be a real PE binary: a two-line C# program compiled with the .NET
# Framework csc.exe (present on every Windows install). Elsewhere a /bin/sh
# script suffices. The banner carries ANSI color the way the real CLI colors its
# own, so the installer's ANSI stripping is on the hook every run. Compiled exes
# are cached per version — several cases reuse the same one.
$LC_CSC = ''
if ($IsWindows) {
    $cscCmd = Get-Command csc -ErrorAction SilentlyContinue
    if ($cscCmd) { $LC_CSC = $cscCmd.Source }
    else {
        $fw = Join-Path $env:windir 'Microsoft.NET' 'Framework64' 'v4.0.30319' 'csc.exe'
        if (Test-Path -LiteralPath $fw) { $LC_CSC = $fw }
    }
}

$script:LC_EXE_CACHE = @{}
function New-LcFakeBinary {
    param([string]$Path, [string]$VersionString)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if ($IsWindows) {
        if (-not $script:LC_EXE_CACHE.ContainsKey($VersionString)) {
            $buildDir = Join-Path $LC_TMP "exe-$VersionString"
            New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
            $cs = Join-Path $buildDir 'v.cs'
            Write-LcFile $cs "class P { static void Main() { System.Console.WriteLine(`"\u001b[1mlinear\u001b[0m $VersionString`"); } }"
            $exe = Join-Path $buildDir 'linear.exe'
            & $LC_CSC -nologo "-out:$exe" $cs | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
                throw "csc failed to build the fake linear.exe ($VersionString)"
            }
            $script:LC_EXE_CACHE[$VersionString] = $exe
        }
        Copy-Item -LiteralPath $script:LC_EXE_CACHE[$VersionString] -Destination $Path -Force
    } else {
        Write-LcFile $Path "#!/bin/sh`nprintf `"\033[1mlinear\033[0m $VersionString\n`"`n"
        & chmod +x $Path
    }
}

# New-LcArchive — pack a directory's CONTENTS into the archive the platform map
# will request: Compress-Archive for the zip, native tar for the tar.xz.
function New-LcArchive {
    param([string]$SrcDir, [string]$OutPath)
    $dir = Split-Path -Parent $OutPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if ($OutPath.EndsWith('.zip')) {
        Compress-Archive -Path (Join-Path $SrcDir '*') -DestinationPath $OutPath -Force
    } else {
        & tar -cJf $OutPath -C $SrcDir .
        if ($LASTEXITCODE -ne 0) { throw "tar failed to build $OutPath" }
    }
}

# New-LcRelease — a complete fake release: fake binary packed into the
# platform-appropriate archive at <mirror>/<tag>/<asset>.
function New-LcRelease {
    param([string]$Mirror, [string]$Tag, [string]$PrintedVersion)
    $src = Join-Path $LC_TMP ('src-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $src -Force | Out-Null
    New-LcFakeBinary (Join-Path $src $LC_BIN) $PrintedVersion
    New-LcArchive $src (Join-Path $Mirror $Tag $LC_ASSET)
    Remove-Item -LiteralPath $src -Recurse -Force
}

# Invoke-LcInstall — run the installer with EVERY override pinned; captures
# stdout and stderr SEPARATELY so the trust-root warnings can be pinned to
# stderr specifically. Nothing is inherited from the operator's environment.
function Invoke-LcInstall {
    param(
        [string]$Version,
        [string]$SumsFile,
        [string]$BaseUrl,
        [string]$InstallDir,
        [string[]]$Argv = @()
    )
    $saved = @{}
    foreach ($n in 'LINEAR_CLI_VERSION', 'LINEAR_CLI_CHECKSUM_FILE', 'LINEAR_CLI_BASE_URL', 'LINEAR_CLI_INSTALL_DIR') {
        $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    }
    $env:LINEAR_CLI_VERSION = $Version
    $env:LINEAR_CLI_CHECKSUM_FILE = $SumsFile
    $env:LINEAR_CLI_BASE_URL = $BaseUrl
    $env:LINEAR_CLI_INSTALL_DIR = $InstallDir
    $errFile = Join-Path $LC_TMP ('.err-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    try {
        $stdout = (& pwsh -NoProfile -File $LC_SCRIPT @Argv 2>$errFile | Out-String)
        $rc = $LASTEXITCODE
    } finally {
        foreach ($n in $saved.Keys) {
            if ($null -eq $saved[$n]) {
                Remove-Item ("Env:" + $n) -ErrorAction SilentlyContinue
            } else {
                [Environment]::SetEnvironmentVariable($n, $saved[$n])
            }
        }
    }
    $stderr = if (Test-Path -LiteralPath $errFile) { [System.IO.File]::ReadAllText($errFile) } else { '' }
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Out    = ($stdout + "`n" + $stderr)
        StdOut = $stdout
        StdErr = $stderr
        Rc     = $rc
    }
}

# === A. The pin file the framework actually ships parses and is well-formed.
# A POSITIVE fixture for the lookup parser: without it, a lookup that matched
# nothing at all would still pass every refusal test below.
$LC_SUMS_BODY = [System.IO.File]::ReadAllText($LC_SUMS_REAL)
$LC_REAL_ENTRIES = @([regex]::Matches($LC_SUMS_BODY, '(?m)^[0-9a-f]{64}\s+v[0-9]+\.[0-9]+\.[0-9]+/linear-')).Count
if ($LC_REAL_ENTRIES -ge 5) {
    _Pass "install-linear-cli.test: the shipped pin file carries well-formed entries (found $LC_REAL_ENTRIES)"
} else {
    _Fail 'install-linear-cli.test: the shipped pin file carries well-formed entries' `
        @("expected >=5 '<sha256>  <tag>/<asset>' lines, found $LC_REAL_ENTRIES")
}
Assert-Contains 'install-linear-cli.test: the pin file pins the default tag for linux x86_64' $LC_SUMS_BODY 'v2.5.0/linear-x86_64-unknown-linux-gnu.tar.xz'
Assert-Contains 'install-linear-cli.test: the pin file pins the default tag for linux aarch64' $LC_SUMS_BODY 'v2.5.0/linear-aarch64-unknown-linux-gnu.tar.xz'
Assert-Contains 'install-linear-cli.test: the pin file pins the default tag for macos arm64' $LC_SUMS_BODY 'v2.5.0/linear-aarch64-apple-darwin.tar.xz'
Assert-Contains 'install-linear-cli.test: the pin file pins the default tag for macos x86_64' $LC_SUMS_BODY 'v2.5.0/linear-x86_64-apple-darwin.tar.xz'
Assert-Contains 'install-linear-cli.test: the pin file pins the default tag for windows x86_64' $LC_SUMS_BODY 'v2.5.0/linear-x86_64-pc-windows-msvc.zip'
Assert-Contains 'install-linear-cli.test: the pin file names the re-vet procedure' $LC_SUMS_BODY 'linear/linear-setup.md'

# The default pin is declared exactly once in each twin, and both must name the
# same tag — a bump that edits one and not the other must break loudly.
$LC_PS_BODY = [System.IO.File]::ReadAllText($LC_SCRIPT)
Assert-Contains 'install-linear-cli.test: the PS twin declares the default pinned tag' `
    $LC_PS_BODY "`$LinearCliDefaultVersion = 'v2.5.0'"
$LC_SH_BODY = [System.IO.File]::ReadAllText((Join-Path $env:REPO_ROOT 'scripts' 'install-linear-cli.sh'))
Assert-Contains 'install-linear-cli.test: the bash twin declares the same default pinned tag' `
    $LC_SH_BODY 'LINEAR_CLI_DEFAULT_VERSION="v2.5.0"'

$LC_INSTALL_LABELS = @(
    'install-linear-cli.test: a correct checksum exits 0',
    'install-linear-cli.test: the archive sha is verified and reported',
    'install-linear-cli.test: the version smoke output is printed',
    'install-linear-cli.test: the success verdict names the pinned tag',
    'install-linear-cli.test: a correct checksum installs the binary',
    'install-linear-cli.test: a non-default checksum file warns about the trust root',
    'install-linear-cli.test: a non-default base URL warns about the trust root',
    'install-linear-cli.test: the trust-root warnings go to STDERR',
    'install-linear-cli.test: a non-default tag is announced as such',
    'install-linear-cli.test: the installed file is re-hashed in place after the move',
    'install-linear-cli.test: a CRLF pin file still resolves the entry',
    'install-linear-cli.test: a CRLF pin file is not misread as unvetted',
    'install-linear-cli.test: a pin entry with trailing whitespace still resolves',
    'install-linear-cli.test: conflicting pin entries exit 1',
    'install-linear-cli.test: the conflict is named as such',
    'install-linear-cli.test: the conflict names the offending line numbers',
    'install-linear-cli.test: conflicting pin entries install NOTHING',
    'install-linear-cli.test: identical duplicate pin entries are accepted',
    'install-linear-cli.test: a checksum mismatch exits 1',
    'install-linear-cli.test: a checksum mismatch is named as such',
    'install-linear-cli.test: the mismatch prints the EXPECTED hash',
    'install-linear-cli.test: the mismatch prints the ACTUAL hash',
    'install-linear-cli.test: the mismatch says the artifact was deleted',
    'install-linear-cli.test: a checksum mismatch installs NOTHING',
    'install-linear-cli.test: an unvetted tag exits 1',
    'install-linear-cli.test: an unvetted tag is named as such',
    'install-linear-cli.test: the unvetted refusal names the missing key',
    'install-linear-cli.test: the unvetted refusal points at the re-vet procedure',
    'install-linear-cli.test: an unvetted tag installs NOTHING',
    'install-linear-cli.test: a version-smoke mismatch exits 1',
    'install-linear-cli.test: the smoke failure is named as such',
    'install-linear-cli.test: the smoke failure shows the parsed token',
    'install-linear-cli.test: the smoke failure names the pinned version',
    'install-linear-cli.test: a version-smoke mismatch removes the installed binary',
    'install-linear-cli.test: an archive with TWO candidate binaries is REFUSED',
    'install-linear-cli.test: the two-binary refusal says exactly one is expected',
    'install-linear-cli.test: the two-binary refusal reports the count found',
    'install-linear-cli.test: an archive with TWO candidate binaries installs NOTHING',
    'install-linear-cli.test: an archive with NO candidate binary is REFUSED',
    'install-linear-cli.test: the no-binary refusal says exactly one is expected',
    'install-linear-cli.test: the no-binary refusal reports the count found',
    'install-linear-cli.test: an archive with NO candidate binary installs NOTHING',
    'install-linear-cli.test: a successful run leaves no staging directory behind'
)

$LC_SKIP_REASON = ''
if ($LC_ASSET -eq '') {
    $LC_SKIP_REASON = "no upstream linear-cli asset for this platform ($LC_ARCH)"
} elseif ($IsWindows -and $LC_CSC -eq '') {
    # Without csc there is no way to fabricate a runnable linear.exe, and every
    # case below either executes it or shares fixtures with one that does.
    $LC_SKIP_REASON = 'no csc.exe found to build the fake linear.exe'
}

if ($LC_SKIP_REASON -ne '') {
    # Named skips, never silent.
    foreach ($l in $LC_INSTALL_LABELS) { _Skip $l $LC_SKIP_REASON }
} else {
    $LC_MIRROR = Join-Path $LC_TMP 'mirror'
    New-LcRelease -Mirror $LC_MIRROR -Tag $LC_VER -PrintedVersion '9.9.9'
    $LC_GOOD_SHA = Get-LcSha (Join-Path $LC_MIRROR $LC_VER $LC_ASSET)
    $LC_MIRROR_URL = Get-LcFileUrl $LC_MIRROR

    # === B. POSITIVE — correct checksum installs and the version smoke passes.
    # The fixture pin file leads with a comment and a blank line so the lookup's
    # comment-skipping is exercised by the case that must succeed.
    $LC_SUMS_OK = Join-Path $LC_TMP 'sums-ok'
    Write-LcFile $LC_SUMS_OK "# fixture pin file — comment lines must be skipped by the lookup`n`n$LC_GOOD_SHA  $LC_VER/$LC_ASSET`n"

    $LC_DIR_OK = Join-Path $LC_TMP 'bin-ok'
    $lcOk = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_OK -BaseUrl $LC_MIRROR_URL -InstallDir $LC_DIR_OK
    Assert-Eq 'install-linear-cli.test: a correct checksum exits 0' 0 $lcOk.Rc
    Assert-Contains 'install-linear-cli.test: the archive sha is verified and reported' $lcOk.Out "archive sha256 verified ($LC_GOOD_SHA)"
    Assert-Contains 'install-linear-cli.test: the version smoke output is printed' $lcOk.Out '9.9.9'
    Assert-Contains 'install-linear-cli.test: the success verdict names the pinned tag' $lcOk.Out "PASS linear-cli $LC_VER installed and verified"
    if (Test-Path -LiteralPath (Join-Path $LC_DIR_OK $LC_BIN) -PathType Leaf) {
        _Pass 'install-linear-cli.test: a correct checksum installs the binary'
    } else {
        _Fail 'install-linear-cli.test: a correct checksum installs the binary' @("not found: $(Join-Path $LC_DIR_OK $LC_BIN)")
    }

    # === B2. TRANSPARENCY, asserted on the run that SUCCEEDS, and pinned to the
    # STREAM. Every invocation in this suite overrides the checksum file and the
    # base URL, i.e. moves the trust root off the repo defaults — that must be
    # stated out loud ON STDERR (diagnostics never pollute machine-readable
    # stdout), and a tag other than the compiled-in default must be announced
    # rather than silently applied (a silent downgrade onto a withdrawn release
    # is the threat).
    Assert-Contains 'install-linear-cli.test: a non-default checksum file warns about the trust root' `
        $lcOk.StdErr "WARNING non-default trust root: LINEAR_CLI_CHECKSUM_FILE=$LC_SUMS_OK"
    Assert-Contains 'install-linear-cli.test: a non-default base URL warns about the trust root' `
        $lcOk.StdErr "WARNING non-default trust root: LINEAR_CLI_BASE_URL=$LC_MIRROR_URL"
    Assert-NotContains 'install-linear-cli.test: the trust-root warnings go to STDERR' `
        $lcOk.StdOut 'WARNING non-default trust root'
    Assert-Contains 'install-linear-cli.test: a non-default tag is announced as such' `
        $lcOk.StdOut "note: installing non-default tag $LC_VER (current default: v2.5.0)"
    # POSITIVE fixture for the post-move re-hash: if this line never appeared,
    # the TOCTOU re-verify could be dead code and nothing here would notice.
    Assert-Contains 'install-linear-cli.test: the installed file is re-hashed in place after the move' `
        $lcOk.Out 'post-install sha256 re-verified in place'

    # === B4. PIN-FILE NORMALIZATION, and it is a TWIN-PARITY contract. A pin
    # file saved with CRLF endings, or an entry carrying trailing spaces, must
    # resolve the same way in both twins — the two disagreeing about which
    # releases are vetted is worse than either behavior alone.
    $LC_SUMS_CRLF = Join-Path $LC_TMP 'sums-crlf'
    Write-LcFile $LC_SUMS_CRLF "# fixture with CRLF endings`r`n$LC_GOOD_SHA  $LC_VER/$LC_ASSET`r`n"
    $lcCrlf = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_CRLF -BaseUrl $LC_MIRROR_URL `
        -InstallDir (Join-Path $LC_TMP 'bin-crlf')
    Assert-Eq 'install-linear-cli.test: a CRLF pin file still resolves the entry' 0 $lcCrlf.Rc
    Assert-NotContains 'install-linear-cli.test: a CRLF pin file is not misread as unvetted' $lcCrlf.Out 'unvetted release'

    $LC_SUMS_TRAIL = Join-Path $LC_TMP 'sums-trailing'
    Write-LcFile $LC_SUMS_TRAIL "$LC_GOOD_SHA  $LC_VER/$LC_ASSET   `n"
    $lcTrail = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_TRAIL -BaseUrl $LC_MIRROR_URL `
        -InstallDir (Join-Path $LC_TMP 'bin-trailing')
    Assert-Eq 'install-linear-cli.test: a pin entry with trailing whitespace still resolves' 0 $lcTrail.Rc

    # === B5. CONFLICTING PINS. Two entries for one key with different hashes:
    # the file cannot say which artifact is vetted, and "first match wins" would
    # let an appended line decide silently. Identical duplicates are a harmless
    # merge artifact and must still install — otherwise the guard is a nuisance.
    $LC_OTHER_SHA = '1' * 64
    $LC_SUMS_CONFLICT = Join-Path $LC_TMP 'sums-conflict'
    Write-LcFile $LC_SUMS_CONFLICT "# conflicting fixture`n$LC_GOOD_SHA  $LC_VER/$LC_ASSET`n$LC_OTHER_SHA  $LC_VER/$LC_ASSET`n"
    $LC_DIR_CONFLICT = Join-Path $LC_TMP 'bin-conflict'
    $lcConflict = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_CONFLICT -BaseUrl $LC_MIRROR_URL -InstallDir $LC_DIR_CONFLICT
    Assert-Eq 'install-linear-cli.test: conflicting pin entries exit 1' 1 $lcConflict.Rc
    Assert-Contains 'install-linear-cli.test: the conflict is named as such' $lcConflict.Out 'FAIL conflicting pin entries'
    # Line numbers are what make the refusal actionable — the operator has to
    # find and reconcile the entries by hand.
    Assert-Contains 'install-linear-cli.test: the conflict names the offending line numbers' $lcConflict.Out 'at line(s): 2 3'
    if (-not (Test-Path -LiteralPath (Join-Path $LC_DIR_CONFLICT $LC_BIN))) {
        _Pass 'install-linear-cli.test: conflicting pin entries install NOTHING'
    } else {
        _Fail 'install-linear-cli.test: conflicting pin entries install NOTHING' @('installed anyway')
    }

    $LC_SUMS_DUP = Join-Path $LC_TMP 'sums-dup'
    Write-LcFile $LC_SUMS_DUP "$LC_GOOD_SHA  $LC_VER/$LC_ASSET`n$LC_GOOD_SHA  $LC_VER/$LC_ASSET`n"
    $lcDup = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_DUP -BaseUrl $LC_MIRROR_URL `
        -InstallDir (Join-Path $LC_TMP 'bin-dup')
    Assert-Eq 'install-linear-cli.test: identical duplicate pin entries are accepted' 0 $lcDup.Rc

    # === B6. STAGING DIRECTORY. The PS twin must never reuse a pre-existing
    # temp dir (a -Force create on a predictable path would adopt whatever an
    # attacker pre-populated) and must clean up after itself. Counting the
    # staging dirs around a successful run covers both halves at once.
    $lcStageBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory `
        -Filter 'linear-cli-install-*' -ErrorAction SilentlyContinue).Count
    $lcStage = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_OK -BaseUrl $LC_MIRROR_URL `
        -InstallDir (Join-Path $LC_TMP 'bin-stage')
    $lcStageAfter = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory `
        -Filter 'linear-cli-install-*' -ErrorAction SilentlyContinue).Count
    if ($lcStage.Rc -eq 0 -and $lcStageAfter -eq $lcStageBefore) {
        _Pass 'install-linear-cli.test: a successful run leaves no staging directory behind'
    } else {
        _Fail 'install-linear-cli.test: a successful run leaves no staging directory behind' `
            @("rc=$($lcStage.Rc) staging dirs before=$lcStageBefore after=$lcStageAfter")
    }

    # === C. NEGATIVE — checksum mismatch. The archive is deleted, nothing is
    # installed, and both hashes are named so the operator can compare them
    # against upstream's manifest by eye.
    $LC_BAD_SHA = '0' * 64
    $LC_SUMS_BAD = Join-Path $LC_TMP 'sums-bad'
    Write-LcFile $LC_SUMS_BAD "$LC_BAD_SHA  $LC_VER/$LC_ASSET`n"
    $LC_DIR_BAD = Join-Path $LC_TMP 'bin-bad'
    $lcBad = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_BAD -BaseUrl $LC_MIRROR_URL -InstallDir $LC_DIR_BAD
    Assert-Eq 'install-linear-cli.test: a checksum mismatch exits 1' 1 $lcBad.Rc
    Assert-Contains 'install-linear-cli.test: a checksum mismatch is named as such' $lcBad.Out 'FAIL checksum mismatch'
    Assert-Contains 'install-linear-cli.test: the mismatch prints the EXPECTED hash' $lcBad.Out "expected: $LC_BAD_SHA"
    Assert-Contains 'install-linear-cli.test: the mismatch prints the ACTUAL hash' $lcBad.Out "actual:   $LC_GOOD_SHA"
    Assert-Contains 'install-linear-cli.test: the mismatch says the artifact was deleted' `
        $lcBad.Out 'The downloaded artifact was deleted and NOTHING was installed'
    $lcBadLeft = @(Get-ChildItem -LiteralPath $LC_DIR_BAD -File -Recurse -ErrorAction SilentlyContinue).Count
    if ($lcBadLeft -eq 0) {
        _Pass 'install-linear-cli.test: a checksum mismatch installs NOTHING'
    } else {
        _Fail 'install-linear-cli.test: a checksum mismatch installs NOTHING' @("files left under ${LC_DIR_BAD}: $lcBadLeft")
    }

    # === D. NEGATIVE — the tag is absent from the pin file (unvetted release).
    # The pin file is valid and non-empty; it just does not cover THIS tag, so
    # the refusal must come from the lookup, not from an unreadable file.
    $LC_SUMS_OTHER = Join-Path $LC_TMP 'sums-other'
    Write-LcFile $LC_SUMS_OTHER "$LC_GOOD_SHA  v0.0.1/$LC_ASSET`n"
    $LC_DIR_UNVETTED = Join-Path $LC_TMP 'bin-unvetted'
    $lcUnvetted = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_OTHER -BaseUrl $LC_MIRROR_URL -InstallDir $LC_DIR_UNVETTED
    Assert-Eq 'install-linear-cli.test: an unvetted tag exits 1' 1 $lcUnvetted.Rc
    Assert-Contains 'install-linear-cli.test: an unvetted tag is named as such' $lcUnvetted.Out 'FAIL unvetted release'
    Assert-Contains 'install-linear-cli.test: the unvetted refusal names the missing key' $lcUnvetted.Out "$LC_VER/$LC_ASSET"
    Assert-Contains 'install-linear-cli.test: the unvetted refusal points at the re-vet procedure' `
        $lcUnvetted.Out 'linear/linear-setup.md §3.2'
    $lcUnvettedLeft = @(Get-ChildItem -LiteralPath $LC_DIR_UNVETTED -File -Recurse -ErrorAction SilentlyContinue).Count
    if ($lcUnvettedLeft -eq 0) {
        _Pass 'install-linear-cli.test: an unvetted tag installs NOTHING'
    } else {
        _Fail 'install-linear-cli.test: an unvetted tag installs NOTHING' @("files left under $LC_DIR_UNVETTED")
    }

    # === D2. NEGATIVE — version smoke mismatch. The bytes verify, but the
    # binary reports a different version than the tag claims, so the pin file
    # and the tag disagree and the binary must not stay on PATH.
    $LC_MIRROR_WRONG = Join-Path $LC_TMP 'mirror-wrong'
    New-LcRelease -Mirror $LC_MIRROR_WRONG -Tag $LC_VER -PrintedVersion '1.2.3'
    $LC_SUMS_WRONG = Join-Path $LC_TMP 'sums-wrong'
    Write-LcFile $LC_SUMS_WRONG ((Get-LcSha (Join-Path $LC_MIRROR_WRONG $LC_VER $LC_ASSET)) + "  $LC_VER/$LC_ASSET`n")
    $LC_DIR_WRONG = Join-Path $LC_TMP 'bin-wrong'
    $lcWrong = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_WRONG `
        -BaseUrl (Get-LcFileUrl $LC_MIRROR_WRONG) -InstallDir $LC_DIR_WRONG
    Assert-Eq 'install-linear-cli.test: a version-smoke mismatch exits 1' 1 $lcWrong.Rc
    Assert-Contains 'install-linear-cli.test: the smoke failure is named as such' $lcWrong.Out 'FAIL version smoke failed'
    Assert-Contains 'install-linear-cli.test: the smoke failure shows the parsed token' $lcWrong.Out 'parsed version: 1.2.3'
    Assert-Contains 'install-linear-cli.test: the smoke failure names the pinned version' $lcWrong.Out 'pinned version 9.9.9'
    if (-not (Test-Path -LiteralPath (Join-Path $LC_DIR_WRONG $LC_BIN))) {
        _Pass 'install-linear-cli.test: a version-smoke mismatch removes the installed binary'
    } else {
        _Fail 'install-linear-cli.test: a version-smoke mismatch removes the installed binary' `
            @("still present: $(Join-Path $LC_DIR_WRONG $LC_BIN)")
    }

    # === D3. NEGATIVE, archive-specific — TWO candidate binaries inside one
    # verified archive. The pin covers the archive, not the binary, so an
    # archive that offers a CHOICE of binaries is a refusal: picking either one
    # would execute a file the vetting never singled out.
    $LC_SRC_TWO = Join-Path $LC_TMP 'src-two'
    New-Item -ItemType Directory -Path (Join-Path $LC_SRC_TWO 'nested') -Force | Out-Null
    New-LcFakeBinary (Join-Path $LC_SRC_TWO $LC_BIN) '9.9.9'
    New-LcFakeBinary (Join-Path $LC_SRC_TWO 'nested' $LC_BIN) '6.6.6'
    $LC_MIRROR_TWO = Join-Path $LC_TMP 'mirror-two'
    New-LcArchive $LC_SRC_TWO (Join-Path $LC_MIRROR_TWO $LC_VER $LC_ASSET)
    $LC_SUMS_TWO = Join-Path $LC_TMP 'sums-two'
    Write-LcFile $LC_SUMS_TWO ((Get-LcSha (Join-Path $LC_MIRROR_TWO $LC_VER $LC_ASSET)) + "  $LC_VER/$LC_ASSET`n")
    $LC_DIR_TWO = Join-Path $LC_TMP 'bin-two'
    $lcTwo = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_TWO `
        -BaseUrl (Get-LcFileUrl $LC_MIRROR_TWO) -InstallDir $LC_DIR_TWO
    Assert-Eq 'install-linear-cli.test: an archive with TWO candidate binaries is REFUSED' 1 $lcTwo.Rc
    Assert-Contains 'install-linear-cli.test: the two-binary refusal says exactly one is expected' `
        $lcTwo.Out "expected exactly one $LC_BIN"
    Assert-Contains 'install-linear-cli.test: the two-binary refusal reports the count found' $lcTwo.Out 'found 2'
    if (-not (Test-Path -LiteralPath (Join-Path $LC_DIR_TWO $LC_BIN))) {
        _Pass 'install-linear-cli.test: an archive with TWO candidate binaries installs NOTHING'
    } else {
        _Fail 'install-linear-cli.test: an archive with TWO candidate binaries installs NOTHING' @('installed anyway')
    }

    # === D4. NEGATIVE, archive-specific — NO candidate binary inside the
    # archive. A verified archive that does not contain the promised binary is
    # the same refusal from the other side: found 0, nothing to install, exit 1.
    $LC_SRC_NONE = Join-Path $LC_TMP 'src-none'
    New-Item -ItemType Directory -Path $LC_SRC_NONE -Force | Out-Null
    Write-LcFile (Join-Path $LC_SRC_NONE 'README.txt') "not a binary`n"
    $LC_MIRROR_NONE = Join-Path $LC_TMP 'mirror-none'
    New-LcArchive $LC_SRC_NONE (Join-Path $LC_MIRROR_NONE $LC_VER $LC_ASSET)
    $LC_SUMS_NONE = Join-Path $LC_TMP 'sums-none'
    Write-LcFile $LC_SUMS_NONE ((Get-LcSha (Join-Path $LC_MIRROR_NONE $LC_VER $LC_ASSET)) + "  $LC_VER/$LC_ASSET`n")
    $LC_DIR_NONE = Join-Path $LC_TMP 'bin-none'
    $lcNone = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_NONE `
        -BaseUrl (Get-LcFileUrl $LC_MIRROR_NONE) -InstallDir $LC_DIR_NONE
    Assert-Eq 'install-linear-cli.test: an archive with NO candidate binary is REFUSED' 1 $lcNone.Rc
    Assert-Contains 'install-linear-cli.test: the no-binary refusal says exactly one is expected' `
        $lcNone.Out "expected exactly one $LC_BIN"
    Assert-Contains 'install-linear-cli.test: the no-binary refusal reports the count found' $lcNone.Out 'found 0'
    if (-not (Test-Path -LiteralPath (Join-Path $LC_DIR_NONE $LC_BIN))) {
        _Pass 'install-linear-cli.test: an archive with NO candidate binary installs NOTHING'
    } else {
        _Fail 'install-linear-cli.test: an archive with NO candidate binary installs NOTHING' @('installed anyway')
    }
}

# === E. Unsupported platform. Unlike lineark, upstream DOES ship a Windows
# binary, so every platform this suite runs on is supported and the branch
# cannot be provoked (RuntimeInformation cannot be shadowed the way the bash
# twin shadows `uname`). Named skips on supported hosts; if a future lane runs
# on an architecture with no asset, the case fires there.
$LC_UNSUP_LABELS = @(
    'install-linear-cli.test: an unsupported platform exits 3',
    'install-linear-cli.test: the unsupported path offers the npm alternative',
    'install-linear-cli.test: the unsupported path offers the Linear MCP fallback'
)
if ($LC_ASSET -ne '') {
    foreach ($l in $LC_UNSUP_LABELS) {
        _Skip $l 'this host HAS an upstream asset — the unsupported branch cannot be provoked here'
    }
} else {
    $LC_DIR_UNSUP = Join-Path $LC_TMP 'bin-unsup'
    $lcUnsup = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_REAL `
        -BaseUrl 'https://example.invalid/releases' -InstallDir $LC_DIR_UNSUP
    Assert-Eq 'install-linear-cli.test: an unsupported platform exits 3' 3 $lcUnsup.Rc
    Assert-Contains 'install-linear-cli.test: the unsupported path offers the npm alternative' `
        $lcUnsup.Out 'npm install -g @schpet/linear-cli'
    Assert-Contains 'install-linear-cli.test: the unsupported path offers the Linear MCP fallback' `
        $lcUnsup.Out 'linear/linear-setup.md §3.3'
}

# === E2. Staging-directory hardening is a SOURCE-SHAPE contract too: the create
# must be a unique path created WITHOUT -Force, so a pre-existing directory can
# never be adopted. The behavioral count above cannot distinguish "created
# fresh" from "reused an identically-named dir", so both are pinned.
Assert-Contains 'install-linear-cli.test: the staging dir is created without -Force' `
    $LC_PS_BODY 'New-Item -ItemType Directory -Path $candidate -ErrorAction Stop'
Assert-Contains 'install-linear-cli.test: the staging dir path is unguessable (New-Guid)' `
    $LC_PS_BODY "('linear-cli-install-' + (New-Guid).Guid)"

# === E3. LINEAR_CLI_BASE_URL scheme allowlist. Only https:// and file:// are
# accepted; plain http:// is the transport this installer exists to stop
# trusting, so it is refused before anything is fetched. Platform-independent:
# the guard runs before platform detection.
$lcScheme = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_REAL `
    -BaseUrl 'http://example.invalid/releases' -InstallDir (Join-Path $LC_TMP 'bin-scheme')
Assert-Eq 'install-linear-cli.test: a plain http:// base URL exits 2' 2 $lcScheme.Rc
Assert-Contains 'install-linear-cli.test: the scheme refusal names the offending URL' `
    $lcScheme.Out 'disallowed LINEAR_CLI_BASE_URL scheme: http://example.invalid/releases'
Assert-Contains 'install-linear-cli.test: the scheme refusal states the allowlist' `
    $lcScheme.Out 'Only https:// and file:// are accepted'
# The allowed schemes must NOT be caught by the same guard — a guard that
# refuses everything would pass the assertion above while breaking every
# install. The absent tag guarantees the run dies at the pin lookup, never the
# network.
$lcSchemeOk = Invoke-LcInstall -Version 'v0.0.0-absent' -SumsFile $LC_SUMS_REAL `
    -BaseUrl 'https://example.invalid/releases' -InstallDir (Join-Path $LC_TMP 'bin-scheme-ok')
Assert-NotContains 'install-linear-cli.test: an https:// base URL passes the scheme guard' `
    $lcSchemeOk.Out 'disallowed LINEAR_CLI_BASE_URL scheme'

# === E4. LINEAR_CLI_VERSION syntax guard. The tag becomes a path segment in the
# download URL and the lookup key, so a traversal shape is refused outright
# rather than sanitized.
$lcVerSyntax = Invoke-LcInstall -Version '../v2.5.0' -SumsFile $LC_SUMS_REAL `
    -BaseUrl 'https://example.invalid/releases' -InstallDir (Join-Path $LC_TMP 'bin-version-syntax')
Assert-Eq 'install-linear-cli.test: a traversal-shaped LINEAR_CLI_VERSION exits 2' 2 $lcVerSyntax.Rc
Assert-Contains 'install-linear-cli.test: the version-syntax refusal names the value' `
    $lcVerSyntax.Out 'malformed LINEAR_CLI_VERSION: ../v2.5.0'
Assert-Contains 'install-linear-cli.test: the version-syntax refusal states the allowed shape' `
    $lcVerSyntax.Out '^v?[A-Za-z0-9._-]+$'

# === F. Usage error — an unknown flag is exit 2, not a silently ignored word.
# The PS binder will happily prefix-match `--force` onto a declared parameter if
# the script lets it; this pins the explicit rejection instead.
$lcUsage = Invoke-LcInstall -Version $LC_VER -SumsFile $LC_SUMS_REAL -BaseUrl 'https://example.invalid/releases' `
    -InstallDir (Join-Path $LC_TMP 'bin-usage') -Argv @('--force')
Assert-Eq 'install-linear-cli.test: an unknown flag exits 2' 2 $lcUsage.Rc
Assert-Contains 'install-linear-cli.test: the usage error names the offending argument' $lcUsage.Out 'unknown argument: --force'

# === G. The docs teach the pinned installer, not the upstream unpinned routes.
$LC_SETUP_BODY = [System.IO.File]::ReadAllText((Join-Path $env:REPO_ROOT 'linear' 'linear-setup.md'))
Assert-Contains 'install-linear-cli.test: linear-setup.md documents the pinned installer' `
    $LC_SETUP_BODY 'bash scripts/install-linear-cli.sh'
Assert-Contains 'install-linear-cli.test: linear-setup.md documents the pwsh form' `
    $LC_SETUP_BODY 'scripts/install-linear-cli.ps1'
Assert-Contains 'install-linear-cli.test: linear-setup.md names the checksum pin file' `
    $LC_SETUP_BODY 'scripts/linear-cli-checksums.sha256'
Assert-Contains 'install-linear-cli.test: linear-setup.md documents the re-vet procedure' `
    $LC_SETUP_BODY 'Updating / re-vetting a new release'
Assert-Contains 'install-linear-cli.test: linear-setup.md documents the rollback lever' `
    $LC_SETUP_BODY 'LINEAR_CLI_VERSION='

$LC_README_BODY = [System.IO.File]::ReadAllText((Join-Path $env:REPO_ROOT 'README.md'))
Assert-Contains 'install-linear-cli.test: README points at the pinned installer' `
    $LC_README_BODY 'scripts/install-linear-cli.sh'

# Inline cleanup — tests/run.ps1 dot-sources this file.
Remove-Item -LiteralPath $LC_TMP -Recurse -Force -ErrorAction SilentlyContinue
