#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/install-lineark.test.ps1 — Windows-native twin of tests/install-lineark.test.sh.
#
# Behavioral tests for scripts/install-lineark.ps1, the pinned checksum-verified
# installer that replaced the upstream `curl … | sh` instruction for the optional
# `lineark` CLI. What is under test is the REFUSAL contract, because that is the
# whole reason the script exists:
#
#   - correct checksum              -> installs, version smoke passes, exit 0
#   - checksum MISMATCH             -> exit 1, nothing installed, expected vs
#                                      actual both printed
#   - tag ABSENT from the pin file  -> exit 1, "unvetted release", nothing
#                                      installed, re-vet procedure named
#   - version smoke MISMATCH        -> exit 1, the binary removed again
#   - unsupported platform          -> exit 3, both documented alternatives named
#
# HERMETIC. No network: the release mirror is a local directory served through
# `file://`, and the "binary" is a two-line /bin/sh script so `--version` works.
# EVERY invocation pins LINEARK_VERSION, LINEARK_CHECKSUM_FILE, LINEARK_BASE_URL
# and LINEARK_INSTALL_DIR, so the operator's real pin file, real install dir and
# real network are never reachable from this suite.
#
# TWIN DIVERGENCE, stated because it drives the skip shims below. The bash twin
# forces the unsupported-platform branch on every host by stubbing `uname` ahead
# of the script's PATH. The PS twin resolves its platform from
# RuntimeInformation, which no PATH entry can shadow — so on Windows (where
# upstream ships no binary at all) the unsupported case is the ONLY case that
# runs, and the install cases are named skips; on macOS/Linux it is the reverse.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$LK_SCRIPT = Join-Path $env:REPO_ROOT 'scripts' 'install-lineark.ps1'
$LK_SUMS_REAL = Join-Path $env:REPO_ROOT 'scripts' 'lineark-checksums.sha256'

Assert-File 'install-lineark.test: scripts/install-lineark.ps1 exists' $LK_SCRIPT
Assert-File 'install-lineark.test: scripts/lineark-checksums.sha256 exists' $LK_SUMS_REAL
Assert-File 'install-lineark.test: the bash twin exists' (Join-Path $env:REPO_ROOT 'scripts' 'install-lineark.sh')

function New-LkTempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('lk-test-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Write-LkFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# New-LkFakeAsset — a stand-in release artifact that is a real executable, so the
# version smoke is exercised rather than stubbed out.
function New-LkFakeAsset {
    param([string]$Path, [string]$VersionString)
    Write-LkFile $Path "#!/bin/sh`nprintf `"lineark $VersionString\n`"`n"
    if (-not $IsWindows) { & chmod +x $Path }
}

function Get-LkSha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Invoke-LkInstall — run the installer with EVERY override pinned. Nothing is
# inherited from the operator's environment.
function Invoke-LkInstall {
    param(
        [string]$Version,
        [string]$SumsFile,
        [string]$BaseUrl,
        [string]$InstallDir,
        [string[]]$Argv = @()
    )
    $saved = @{}
    foreach ($n in 'LINEARK_VERSION', 'LINEARK_CHECKSUM_FILE', 'LINEARK_BASE_URL', 'LINEARK_INSTALL_DIR') {
        $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    }
    $env:LINEARK_VERSION = $Version
    $env:LINEARK_CHECKSUM_FILE = $SumsFile
    $env:LINEARK_BASE_URL = $BaseUrl
    $env:LINEARK_INSTALL_DIR = $InstallDir
    try {
        $out = (& pwsh -NoProfile -File $LK_SCRIPT @Argv 2>&1 | Out-String)
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
    return [pscustomobject]@{ Out = $out; Rc = $rc }
}

$LK_TMP = New-LkTempDir
$LK_VER = 'v9.9.9'
$LK_MIRROR = Join-Path $LK_TMP 'mirror'

# --- host -> asset name, mirroring the script's own platform table ----------
$LK_ARCH = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$LK_ASSET = ''
if ($IsLinux) {
    if ($LK_ARCH -eq 'X64') { $LK_ASSET = 'lineark_linux_x86_64' }
    elseif ($LK_ARCH -eq 'Arm64') { $LK_ASSET = 'lineark_linux_aarch64' }
} elseif ($IsMacOS) {
    if ($LK_ARCH -eq 'Arm64') { $LK_ASSET = 'lineark_macos_aarch64' }
}

# === A. The pin file the framework actually ships parses and is well-formed.
# A POSITIVE fixture for the lookup parser: without it, a lookup that matched
# nothing at all would still pass every refusal test below.
$LK_SUMS_BODY = [System.IO.File]::ReadAllText($LK_SUMS_REAL)
$LK_REAL_ENTRIES = @([regex]::Matches($LK_SUMS_BODY, '(?m)^[0-9a-f]{64}\s+v[0-9]+\.[0-9]+\.[0-9]+/lineark_')).Count
if ($LK_REAL_ENTRIES -ge 3) {
    _Pass "install-lineark.test: the shipped pin file carries well-formed entries (found $LK_REAL_ENTRIES)"
} else {
    _Fail 'install-lineark.test: the shipped pin file carries well-formed entries' `
        @("expected >=3 '<sha256>  <tag>/<asset>' lines, found $LK_REAL_ENTRIES")
}
Assert-Contains 'install-lineark.test: the pin file pins the default tag for linux x86_64' $LK_SUMS_BODY 'v3.1.0/lineark_linux_x86_64'
Assert-Contains 'install-lineark.test: the pin file pins the default tag for linux aarch64' $LK_SUMS_BODY 'v3.1.0/lineark_linux_aarch64'
Assert-Contains 'install-lineark.test: the pin file pins the default tag for macos aarch64' $LK_SUMS_BODY 'v3.1.0/lineark_macos_aarch64'
Assert-Contains 'install-lineark.test: the pin file names the re-vet procedure' $LK_SUMS_BODY 'linear/linear-setup.md'

# The default pin is declared exactly once in each twin, and both must name the
# same tag — a bump that edits one and not the other must break loudly.
$LK_PS_BODY = [System.IO.File]::ReadAllText($LK_SCRIPT)
Assert-Contains 'install-lineark.test: the PS twin declares the default pinned tag' `
    $LK_PS_BODY "`$LinearkDefaultVersion = 'v3.1.0'"
$LK_SH_BODY = [System.IO.File]::ReadAllText((Join-Path $env:REPO_ROOT 'scripts' 'install-lineark.sh'))
Assert-Contains 'install-lineark.test: the bash twin declares the same default pinned tag' `
    $LK_SH_BODY 'LINEARK_DEFAULT_VERSION="v3.1.0"'

$LK_INSTALL_LABELS = @(
    'install-lineark.test: a correct checksum exits 0',
    'install-lineark.test: the verified sha is reported',
    'install-lineark.test: the version smoke output is printed',
    'install-lineark.test: the success verdict names the pinned tag',
    'install-lineark.test: a correct checksum installs the binary',
    'install-lineark.test: a checksum mismatch exits 1',
    'install-lineark.test: a checksum mismatch is named as such',
    'install-lineark.test: the mismatch prints the EXPECTED hash',
    'install-lineark.test: the mismatch prints the ACTUAL hash',
    'install-lineark.test: a checksum mismatch installs NOTHING',
    'install-lineark.test: an unvetted tag exits 1',
    'install-lineark.test: an unvetted tag is named as such',
    'install-lineark.test: the unvetted refusal points at the re-vet procedure',
    'install-lineark.test: an unvetted tag installs NOTHING',
    'install-lineark.test: a version-smoke mismatch exits 1',
    'install-lineark.test: the smoke failure is named as such',
    'install-lineark.test: a version-smoke mismatch removes the installed binary',
    'install-lineark.test: a non-default checksum file warns about the trust root',
    'install-lineark.test: a non-default base URL warns about the trust root',
    'install-lineark.test: a non-default tag is announced as such',
    'install-lineark.test: the installed file is re-hashed in place after the move',
    'install-lineark.test: a superset version (13.1.0 vs 3.1.0) is REFUSED',
    'install-lineark.test: a longer version (9.9.9.0 vs 9.9.9) is REFUSED',
    'install-lineark.test: a CRLF pin file still resolves the entry',
    'install-lineark.test: a pin entry with trailing whitespace still resolves',
    'install-lineark.test: conflicting pin entries exit 1',
    'install-lineark.test: the conflict names the offending line numbers',
    'install-lineark.test: identical duplicate pin entries are accepted',
    'install-lineark.test: a successful run leaves no staging directory behind'
)

if ($LK_ASSET -eq '') {
    # No prebuilt asset for this host (every Windows lane, and Intel macOS).
    # Named skips, never silent — the unsupported-platform case below IS the
    # assertion that runs here.
    foreach ($l in $LK_INSTALL_LABELS) {
        _Skip $l "no upstream lineark asset for this platform ($LK_ARCH)"
    }
} else {
    New-LkFakeAsset (Join-Path $LK_MIRROR $LK_VER $LK_ASSET) '9.9.9'
    $LK_GOOD_SHA = Get-LkSha (Join-Path $LK_MIRROR $LK_VER $LK_ASSET)

    # === B. POSITIVE — correct checksum installs and the version smoke passes.
    # The fixture pin file leads with a comment and a blank line so the lookup's
    # comment-skipping is exercised by the case that must succeed.
    $LK_SUMS_OK = Join-Path $LK_TMP 'sums-ok'
    Write-LkFile $LK_SUMS_OK "# fixture pin file — comment lines must be skipped by the lookup`n`n$LK_GOOD_SHA  $LK_VER/$LK_ASSET`n"

    $LK_DIR_OK = Join-Path $LK_TMP 'bin-ok'
    $lkOk = Invoke-LkInstall -Version $LK_VER -SumsFile $LK_SUMS_OK -BaseUrl "file://$LK_MIRROR" -InstallDir $LK_DIR_OK
    Assert-Eq 'install-lineark.test: a correct checksum exits 0' 0 $lkOk.Rc
    Assert-Contains 'install-lineark.test: the verified sha is reported' $lkOk.Out "sha256 verified ($LK_GOOD_SHA)"
    Assert-Contains 'install-lineark.test: the version smoke output is printed' $lkOk.Out 'lineark 9.9.9'
    Assert-Contains 'install-lineark.test: the success verdict names the pinned tag' $lkOk.Out "PASS lineark $LK_VER installed and verified"
    if (Test-Path -LiteralPath (Join-Path $LK_DIR_OK 'lineark') -PathType Leaf) {
        _Pass 'install-lineark.test: a correct checksum installs the binary'
    } else {
        _Fail 'install-lineark.test: a correct checksum installs the binary' @("not found: $(Join-Path $LK_DIR_OK 'lineark')")
    }

    # === B2. TRANSPARENCY, asserted on the run that SUCCEEDS. Every invocation
    # in this suite overrides the checksum file and the base URL, i.e. moves the
    # trust root off the repo defaults — that must be stated out loud, and a tag
    # other than the compiled-in default must be announced rather than silently
    # applied (a silent downgrade onto a withdrawn release is the threat).
    Assert-Contains 'install-lineark.test: a non-default checksum file warns about the trust root' `
        $lkOk.Out "WARNING non-default trust root: LINEARK_CHECKSUM_FILE=$LK_SUMS_OK"
    Assert-Contains 'install-lineark.test: a non-default base URL warns about the trust root' `
        $lkOk.Out "WARNING non-default trust root: LINEARK_BASE_URL=file://$LK_MIRROR"
    Assert-Contains 'install-lineark.test: a non-default tag is announced as such' `
        $lkOk.Out "note: installing non-default tag $LK_VER (current default: v3.1.0)"
    # POSITIVE fixture for the post-move re-hash. The bash twin additionally
    # FORCES the mismatch with a stubbed `mv`; Move-Item is a cmdlet with no
    # PATH-shadowable equivalent, so on this side the printed line is the
    # available evidence that the check runs at all (documented divergence).
    Assert-Contains 'install-lineark.test: the installed file is re-hashed in place after the move' `
        $lkOk.Out 'post-install sha256 re-verified in place'

    # New-LkCase — a one-off mirror + matching pin file whose sha is correct, so
    # the case under test is the ONLY variable.
    function New-LkCase {
        param([string]$Name, [string]$Tag, [string]$PrintedVersion)
        $mirror = Join-Path $LK_TMP "m-$Name"
        $sums = Join-Path $LK_TMP "s-$Name"
        $assetPath = Join-Path $mirror $Tag $LK_ASSET
        New-LkFakeAsset $assetPath $PrintedVersion
        Write-LkFile $sums ((Get-LkSha $assetPath) + "  $Tag/$LK_ASSET`n")
        return [pscustomobject]@{
            Mirror = $mirror
            Sums   = $sums
            Dir    = (Join-Path $LK_TMP "d-$Name")
        }
    }

    # === B3. EXACT version smoke. A substring test passes `lineark 13.1.0`
    # against a v3.1.0 pin — a completely different release wearing the right
    # suffix. Both directions of "contains but is not equal" are pinned.
    $lkSuperCase = New-LkCase -Name 'superset' -Tag 'v3.1.0' -PrintedVersion '13.1.0'
    $lkSuper = Invoke-LkInstall -Version 'v3.1.0' -SumsFile $lkSuperCase.Sums `
        -BaseUrl ('file://' + $lkSuperCase.Mirror) -InstallDir $lkSuperCase.Dir
    Assert-Eq 'install-lineark.test: a superset version (13.1.0 vs 3.1.0) is REFUSED' 1 $lkSuper.Rc
    Assert-Contains 'install-lineark.test: the superset refusal shows the parsed token' $lkSuper.Out 'parsed version: 13.1.0'
    Assert-Contains 'install-lineark.test: the superset refusal states exact match is required' `
        $lkSuper.Out 'exact match against 3.1.0 required'

    $lkLongCase = New-LkCase -Name 'longer' -Tag $LK_VER -PrintedVersion '9.9.9.0'
    $lkLong = Invoke-LkInstall -Version $LK_VER -SumsFile $lkLongCase.Sums `
        -BaseUrl ('file://' + $lkLongCase.Mirror) -InstallDir $lkLongCase.Dir
    Assert-Eq 'install-lineark.test: a longer version (9.9.9.0 vs 9.9.9) is REFUSED' 1 $lkLong.Rc
    Assert-Contains 'install-lineark.test: the longer-version refusal shows the parsed token' $lkLong.Out 'parsed version: 9.9.9.0'

    # === B4. PIN-FILE NORMALIZATION, and it is a TWIN-PARITY contract. A pin
    # file saved with CRLF endings, or an entry carrying trailing spaces, must
    # resolve the same way in both twins — the two disagreeing about which
    # releases are vetted is worse than either behavior alone.
    $LK_SUMS_CRLF = Join-Path $LK_TMP 'sums-crlf'
    Write-LkFile $LK_SUMS_CRLF "# fixture with CRLF endings`r`n$LK_GOOD_SHA  $LK_VER/$LK_ASSET`r`n"
    $lkCrlf = Invoke-LkInstall -Version $LK_VER -SumsFile $LK_SUMS_CRLF -BaseUrl "file://$LK_MIRROR" `
        -InstallDir (Join-Path $LK_TMP 'bin-crlf')
    Assert-Eq 'install-lineark.test: a CRLF pin file still resolves the entry' 0 $lkCrlf.Rc
    Assert-NotContains 'install-lineark.test: a CRLF pin file is not misread as unvetted' $lkCrlf.Out 'unvetted release'

    $LK_SUMS_TRAIL = Join-Path $LK_TMP 'sums-trailing'
    Write-LkFile $LK_SUMS_TRAIL "$LK_GOOD_SHA  $LK_VER/$LK_ASSET   `n"
    $lkTrail = Invoke-LkInstall -Version $LK_VER -SumsFile $LK_SUMS_TRAIL -BaseUrl "file://$LK_MIRROR" `
        -InstallDir (Join-Path $LK_TMP 'bin-trailing')
    Assert-Eq 'install-lineark.test: a pin entry with trailing whitespace still resolves' 0 $lkTrail.Rc

    # === B5. CONFLICTING PINS. Two entries for one key with different hashes:
    # the file cannot say which artifact is vetted, and "first match wins" would
    # let an appended line decide silently. Identical duplicates are a harmless
    # merge artifact and must still install — otherwise the guard is a nuisance.
    $LK_OTHER_SHA = '1' * 64
    $LK_SUMS_CONFLICT = Join-Path $LK_TMP 'sums-conflict'
    Write-LkFile $LK_SUMS_CONFLICT "# conflicting fixture`n$LK_GOOD_SHA  $LK_VER/$LK_ASSET`n$LK_OTHER_SHA  $LK_VER/$LK_ASSET`n"
    $LK_DIR_CONFLICT = Join-Path $LK_TMP 'bin-conflict'
    $lkConflict = Invoke-LkInstall -Version $LK_VER -SumsFile $LK_SUMS_CONFLICT -BaseUrl "file://$LK_MIRROR" -InstallDir $LK_DIR_CONFLICT
    Assert-Eq 'install-lineark.test: conflicting pin entries exit 1' 1 $lkConflict.Rc
    Assert-Contains 'install-lineark.test: the conflict is named as such' $lkConflict.Out 'FAIL conflicting pin entries'
    Assert-Contains 'install-lineark.test: the conflict names the offending line numbers' $lkConflict.Out 'at line(s): 2 3'
    if (-not (Test-Path -LiteralPath (Join-Path $LK_DIR_CONFLICT 'lineark'))) {
        _Pass 'install-lineark.test: conflicting pin entries install NOTHING'
    } else {
        _Fail 'install-lineark.test: conflicting pin entries install NOTHING' @('installed anyway')
    }

    $LK_SUMS_DUP = Join-Path $LK_TMP 'sums-dup'
    Write-LkFile $LK_SUMS_DUP "$LK_GOOD_SHA  $LK_VER/$LK_ASSET`n$LK_GOOD_SHA  $LK_VER/$LK_ASSET`n"
    $lkDup = Invoke-LkInstall -Version $LK_VER -SumsFile $LK_SUMS_DUP -BaseUrl "file://$LK_MIRROR" `
        -InstallDir (Join-Path $LK_TMP 'bin-dup')
    Assert-Eq 'install-lineark.test: identical duplicate pin entries are accepted' 0 $lkDup.Rc

    # === B6. STAGING DIRECTORY. The PS twin must never reuse a pre-existing temp
    # dir (a -Force create on a predictable path would adopt whatever an attacker
    # pre-populated) and must clean up after itself. Counting the staging dirs
    # around a successful run covers both halves at once.
    $lkStageBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory `
        -Filter 'lineark-install-*' -ErrorAction SilentlyContinue).Count
    $lkStage = Invoke-LkInstall -Version $LK_VER -SumsFile $LK_SUMS_OK -BaseUrl "file://$LK_MIRROR" `
        -InstallDir (Join-Path $LK_TMP 'bin-stage')
    $lkStageAfter = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory `
        -Filter 'lineark-install-*' -ErrorAction SilentlyContinue).Count
    if ($lkStage.Rc -eq 0 -and $lkStageAfter -eq $lkStageBefore) {
        _Pass 'install-lineark.test: a successful run leaves no staging directory behind'
    } else {
        _Fail 'install-lineark.test: a successful run leaves no staging directory behind' `
            @("rc=$($lkStage.Rc) staging dirs before=$lkStageBefore after=$lkStageAfter")
    }

    # === C. NEGATIVE — checksum mismatch. Nothing installed, both hashes named.
    $LK_BAD_SHA = '0' * 64
    $LK_SUMS_BAD = Join-Path $LK_TMP 'sums-bad'
    Write-LkFile $LK_SUMS_BAD "$LK_BAD_SHA  $LK_VER/$LK_ASSET`n"
    $LK_DIR_BAD = Join-Path $LK_TMP 'bin-bad'
    $lkBad = Invoke-LkInstall -Version $LK_VER -SumsFile $LK_SUMS_BAD -BaseUrl "file://$LK_MIRROR" -InstallDir $LK_DIR_BAD
    Assert-Eq 'install-lineark.test: a checksum mismatch exits 1' 1 $lkBad.Rc
    Assert-Contains 'install-lineark.test: a checksum mismatch is named as such' $lkBad.Out 'FAIL checksum mismatch'
    Assert-Contains 'install-lineark.test: the mismatch prints the EXPECTED hash' $lkBad.Out "expected: $LK_BAD_SHA"
    Assert-Contains 'install-lineark.test: the mismatch prints the ACTUAL hash' $lkBad.Out "actual:   $LK_GOOD_SHA"
    $lkBadLeft = @(Get-ChildItem -LiteralPath $LK_DIR_BAD -File -Recurse -ErrorAction SilentlyContinue).Count
    if ($lkBadLeft -eq 0) {
        _Pass 'install-lineark.test: a checksum mismatch installs NOTHING'
    } else {
        _Fail 'install-lineark.test: a checksum mismatch installs NOTHING' @("files left under ${LK_DIR_BAD}: $lkBadLeft")
    }

    # === D. NEGATIVE — the tag is absent from the pin file (unvetted release).
    # The pin file is valid and non-empty; it just does not cover THIS tag, so
    # the refusal must come from the lookup, not from an unreadable file.
    $LK_SUMS_OTHER = Join-Path $LK_TMP 'sums-other'
    Write-LkFile $LK_SUMS_OTHER "$LK_GOOD_SHA  v0.0.1/$LK_ASSET`n"
    $LK_DIR_UNVETTED = Join-Path $LK_TMP 'bin-unvetted'
    $lkUnvetted = Invoke-LkInstall -Version $LK_VER -SumsFile $LK_SUMS_OTHER -BaseUrl "file://$LK_MIRROR" -InstallDir $LK_DIR_UNVETTED
    Assert-Eq 'install-lineark.test: an unvetted tag exits 1' 1 $lkUnvetted.Rc
    Assert-Contains 'install-lineark.test: an unvetted tag is named as such' $lkUnvetted.Out 'FAIL unvetted release'
    Assert-Contains 'install-lineark.test: the unvetted refusal points at the re-vet procedure' `
        $lkUnvetted.Out 'linear/linear-setup.md §3.2'
    $lkUnvettedLeft = @(Get-ChildItem -LiteralPath $LK_DIR_UNVETTED -File -Recurse -ErrorAction SilentlyContinue).Count
    if ($lkUnvettedLeft -eq 0) {
        _Pass 'install-lineark.test: an unvetted tag installs NOTHING'
    } else {
        _Fail 'install-lineark.test: an unvetted tag installs NOTHING' @("files left under $LK_DIR_UNVETTED")
    }

    # === D2. NEGATIVE — version smoke mismatch. The bytes verify, but the binary
    # reports a different version than the tag claims, so the pin file and the
    # tag disagree and the binary must not stay on PATH.
    $LK_MIRROR_WRONG = Join-Path $LK_TMP 'mirror-wrong'
    New-LkFakeAsset (Join-Path $LK_MIRROR_WRONG $LK_VER $LK_ASSET) '1.2.3'
    $LK_WRONG_SHA = Get-LkSha (Join-Path $LK_MIRROR_WRONG $LK_VER $LK_ASSET)
    $LK_SUMS_WRONG = Join-Path $LK_TMP 'sums-wrong'
    Write-LkFile $LK_SUMS_WRONG "$LK_WRONG_SHA  $LK_VER/$LK_ASSET`n"
    $LK_DIR_WRONG = Join-Path $LK_TMP 'bin-wrong'
    $lkWrong = Invoke-LkInstall -Version $LK_VER -SumsFile $LK_SUMS_WRONG -BaseUrl "file://$LK_MIRROR_WRONG" -InstallDir $LK_DIR_WRONG
    Assert-Eq 'install-lineark.test: a version-smoke mismatch exits 1' 1 $lkWrong.Rc
    Assert-Contains 'install-lineark.test: the smoke failure is named as such' $lkWrong.Out 'FAIL version smoke failed'
    if (-not (Test-Path -LiteralPath (Join-Path $LK_DIR_WRONG 'lineark'))) {
        _Pass 'install-lineark.test: a version-smoke mismatch removes the installed binary'
    } else {
        _Fail 'install-lineark.test: a version-smoke mismatch removes the installed binary' `
            @("still present: $(Join-Path $LK_DIR_WRONG 'lineark')")
    }
}

# === E. Unsupported platform. Upstream ships no Windows binary at all, so the
# Windows lane is exactly where this must hold; elsewhere it is a named skip
# (RuntimeInformation cannot be shadowed the way the bash twin shadows `uname`).
$LK_UNSUP_LABELS = @(
    'install-lineark.test: an unsupported platform exits 3',
    'install-lineark.test: the unsupported path offers the cargo alternative',
    'install-lineark.test: the unsupported path offers the Linear MCP fallback'
)
if ($LK_ASSET -ne '') {
    foreach ($l in $LK_UNSUP_LABELS) {
        _Skip $l 'this host HAS an upstream asset — the unsupported branch cannot be provoked here'
    }
} else {
    $LK_DIR_UNSUP = Join-Path $LK_TMP 'bin-unsup'
    $lkUnsup = Invoke-LkInstall -Version $LK_VER -SumsFile $LK_SUMS_REAL -BaseUrl "file://$LK_MIRROR" -InstallDir $LK_DIR_UNSUP
    Assert-Eq 'install-lineark.test: an unsupported platform exits 3' 3 $lkUnsup.Rc
    Assert-Contains 'install-lineark.test: the unsupported path offers the cargo alternative' $lkUnsup.Out 'cargo install lineark'
    Assert-Contains 'install-lineark.test: the unsupported path offers the Linear MCP fallback' $lkUnsup.Out 'linear/linear-setup.md §3.3'
}

# === E2. Staging-directory hardening is a SOURCE-SHAPE contract too: the create
# must be a unique path created WITHOUT -Force, so a pre-existing directory can
# never be adopted. The behavioral count above cannot distinguish "created fresh"
# from "reused an identically-named dir", so both are pinned.
Assert-Contains 'install-lineark.test: the staging dir is created without -Force' `
    $LK_PS_BODY 'New-Item -ItemType Directory -Path $candidate -ErrorAction Stop'
Assert-Contains 'install-lineark.test: the staging dir path is unguessable (New-Guid)' `
    $LK_PS_BODY "('lineark-install-' + (New-Guid).Guid)"

# === E3. LINEARK_BASE_URL scheme allowlist. Only https:// and file:// are
# accepted; plain http:// is the transport this installer exists to stop
# trusting, so it is refused before anything is fetched. Platform-independent:
# the guard runs before platform detection, so it holds on the Windows lane too.
$lkScheme = Invoke-LkInstall -Version $LK_VER -SumsFile $LK_SUMS_REAL `
    -BaseUrl 'http://example.invalid/releases' -InstallDir (Join-Path $LK_TMP 'bin-scheme')
Assert-Eq 'install-lineark.test: a plain http:// base URL exits 2' 2 $lkScheme.Rc
Assert-Contains 'install-lineark.test: the scheme refusal names the offending URL' `
    $lkScheme.Out 'disallowed LINEARK_BASE_URL scheme: http://example.invalid/releases'
Assert-Contains 'install-lineark.test: the scheme refusal states the allowlist' `
    $lkScheme.Out 'Only https:// and file:// are accepted'
# The allowed schemes must NOT be caught by the same guard — a guard that refuses
# everything would pass the assertion above while breaking every install.
$lkSchemeOk = Invoke-LkInstall -Version 'v0.0.0-absent' -SumsFile $LK_SUMS_REAL `
    -BaseUrl 'https://example.invalid/releases' -InstallDir (Join-Path $LK_TMP 'bin-scheme-ok')
Assert-NotContains 'install-lineark.test: an https:// base URL passes the scheme guard' `
    $lkSchemeOk.Out 'disallowed LINEARK_BASE_URL scheme'

# === E4. LINEARK_VERSION syntax guard. The tag becomes a path segment in the
# download URL and the lookup key, so a traversal shape is refused outright
# rather than sanitized.
$lkVerSyntax = Invoke-LkInstall -Version '../v3.1.0' -SumsFile $LK_SUMS_REAL `
    -BaseUrl "file://$LK_MIRROR" -InstallDir (Join-Path $LK_TMP 'bin-version-syntax')
Assert-Eq 'install-lineark.test: a traversal-shaped LINEARK_VERSION exits 2' 2 $lkVerSyntax.Rc
Assert-Contains 'install-lineark.test: the version-syntax refusal names the value' `
    $lkVerSyntax.Out 'malformed LINEARK_VERSION: ../v3.1.0'
Assert-Contains 'install-lineark.test: the version-syntax refusal states the allowed shape' `
    $lkVerSyntax.Out '^v?[A-Za-z0-9._-]+$'

# === F. Usage error — an unknown flag is exit 2, not a silently ignored word.
# The PS binder will happily prefix-match `--force` onto a declared parameter if
# the script lets it; this pins the explicit rejection instead.
$lkUsage = Invoke-LkInstall -Version $LK_VER -SumsFile $LK_SUMS_REAL -BaseUrl "file://$LK_MIRROR" `
    -InstallDir (Join-Path $LK_TMP 'bin-usage') -Argv @('--force')
Assert-Eq 'install-lineark.test: an unknown flag exits 2' 2 $lkUsage.Rc
Assert-Contains 'install-lineark.test: the usage error names the offending argument' $lkUsage.Out 'unknown argument: --force'

# === G. The docs no longer teach the unpinned curl-to-shell install.
$LK_SETUP_BODY = [System.IO.File]::ReadAllText((Join-Path $env:REPO_ROOT 'linear' 'linear-setup.md'))
Assert-NotContains 'install-lineark.test: linear-setup.md no longer pipes the upstream installer into a shell' `
    $LK_SETUP_BODY 'install.sh | sh'
Assert-Contains 'install-lineark.test: linear-setup.md documents the pinned installer' `
    $LK_SETUP_BODY 'bash scripts/install-lineark.sh'
Assert-Contains 'install-lineark.test: linear-setup.md documents the pwsh form' `
    $LK_SETUP_BODY 'scripts/install-lineark.ps1'
Assert-Contains 'install-lineark.test: linear-setup.md documents the re-vet procedure' `
    $LK_SETUP_BODY 'Updating / re-vetting a new release'
Assert-Contains 'install-lineark.test: linear-setup.md names the checksum pin file' `
    $LK_SETUP_BODY 'scripts/lineark-checksums.sha256'
# Revocation is the half operators forget: keeping old entries enables rollback,
# and DELETING one is the only way to make a withdrawn release un-installable.
Assert-Contains 'install-lineark.test: linear-setup.md documents revocation by entry removal' `
    $LK_SETUP_BODY 'Removing an entry from'
Assert-Contains 'install-lineark.test: linear-setup.md says a revoked tag becomes unvetted' `
    $LK_SETUP_BODY 'refuses that tag as an unvetted release'
Assert-Contains 'install-lineark.test: the pin file documents revocation by entry removal' `
    $LK_SUMS_BODY 'REVOCATION mechanism'
Assert-Contains 'install-lineark.test: the pin file says old tags are kept for rollback' `
    $LK_SUMS_BODY 'KEEPING old tags listed is deliberate'

$LK_README_BODY = [System.IO.File]::ReadAllText((Join-Path $env:REPO_ROOT 'README.md'))
Assert-NotContains 'install-lineark.test: README no longer says the lineark doc reproduces curl-to-shell' `
    $LK_README_BODY "reproduce the upstream installer's"
Assert-Contains 'install-lineark.test: README points at the pinned installer' `
    $LK_README_BODY 'scripts/install-lineark.sh'

# Inline cleanup — tests/run.ps1 dot-sources this file.
Remove-Item -LiteralPath $LK_TMP -Recurse -Force -ErrorAction SilentlyContinue
