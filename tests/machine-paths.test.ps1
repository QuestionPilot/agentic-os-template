#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/machine-paths.test.ps1 — Windows-native twin of tests/machine-paths.test.sh.
#
# Behavioral tests for scripts/check-machine-paths.ps1. The check scans a drafted
# session-log body line-by-line for a machine-specific absolute home path the SAME
# way the vault audit's checkAgnostic does: it flags a real /Users/<name> or
# /home/<name> segment (NOT preceded by a URL host char) and a C:\Users\<name>
# segment, while leaving a URL path and a lone "Users" prose token alone. Exit 0 =
# clean, 1 = one or more offending lines, 2 = usage error.
#
# Mirrors the .sh twin 1:1 — same fixtures, same assertions.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$CMD_SCRIPT = Join-Path $env:REPO_ROOT 'scripts' 'check-machine-paths.ps1'
Assert-File 'mp.test: scripts/check-machine-paths.ps1 exists' $CMD_SCRIPT

function Write-LfFile {
    param([string]$Path, [string]$Content)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# New-Draft <content> — write content VERBATIM (no trailing newline appended;
# callers embed `n where a line break is wanted) to a fresh temp file, return its
# path. Single-quoted callers keep literal backslashes intact (PS: `\` is ordinary).
function New-Draft {
    param([string]$Content, [string]$Dir = ([IO.Path]::GetTempPath()))
    $f = Join-Path $Dir ('mp-draft-' + [Guid]::NewGuid().Guid.Substring(0, 8) + '.md')
    Write-LfFile $f $Content
    $f
}

# Invoke-Mp <draft> — run the script, return @{ Out=<joined>; Rc=<int> }.
function Invoke-Mp {
    param([string]$Draft)
    $out = & pwsh -NoProfile -File $CMD_SCRIPT --draft $Draft 2>&1
    $rc = $LASTEXITCODE
    if ($out -is [array]) { $out = $out -join "`n" }
    return @{ Out = [string]$out; Rc = $rc }
}

# === 1. Clean draft (prose + a URL path with a Users segment) → exit 0, PASS.
$D1 = New-Draft "Session note.`nSee https://example.com/Users/foo for docs.`nUsers manage their own settings.`n"
$r1 = Invoke-Mp $D1
Assert-Eq 'mp.test: clean draft (URL + prose) exits 0' '0' "$($r1.Rc)"
Assert-Contains 'mp.test: clean draft reports PASS' $r1.Out 'PASS no machine-specific absolute paths'

# === 2. A bare /Users/<name> path fails closed → exit 1, names <draft>:<line>.
$D2 = New-Draft "intro line`nlog at /Users/dana/thing here`n"
$r2 = Invoke-Mp $D2
Assert-Eq 'mp.test: /Users/<name> path exits 1 (fail closed)' '1' "$($r2.Rc)"
Assert-Contains 'mp.test: names the offending line 2' $r2.Out "${D2}:2"
Assert-Contains 'mp.test: prints the offender message' $r2.Out 'machine-specific absolute path'
Assert-Contains 'mp.test: failure summary counts offenders' $r2.Out '1 offending line(s)'

# === 3. A Windows C:\Users\<name> path fails closed → exit 1.
$D3 = New-Draft "win path C:\Users\bob\notes today`n"
$r3 = Invoke-Mp $D3
Assert-Eq 'mp.test: C:\Users\<name> path exits 1' '1' "$($r3.Rc)"
Assert-Contains 'mp.test: names the Windows offender line 1' $r3.Out "${D3}:1"

# === 4. A /home/<name> path fails closed → exit 1 (the other Unix home root).
$D4 = New-Draft "linux path /home/alice/config ok`n"
Assert-Exit 'mp.test: /home/<name> path exits 1' 1 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D4

# === 5. URL-exclusion is explicit: a home path preceded by an alnum or dot host
# char is NOT flagged; a delimiter-preceded path IS flagged.
$D5OK = New-Draft "a/Users/dave`nexample.com/Users/eric`nversion 2.0/Users/frank`n"
$r5ok = Invoke-Mp $D5OK
Assert-Eq 'mp.test: alnum/dot-prefixed (URL-host) paths pass → exit 0' '0' "$($r5ok.Rc)"
$D5BAD = New-Draft "path=/Users/bob`n"
Assert-Exit 'mp.test: delimiter-prefixed (=) real path fails → exit 1' 1 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D5BAD

# === 6. A lone home-root token WITHOUT a username segment does not trip.
$D6 = New-Draft "the /Users/ root and the word home are fine`n"
Assert-Exit 'mp.test: home root without a username segment passes → exit 0' 0 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D6

# === 7. Mixed draft: multiple offenders on distinct lines, count + line numbers.
$D7 = New-Draft "ok line`n/Users/one/a`nok`nC:\Users\two\b`n/home/three/c`n"
$r7 = Invoke-Mp $D7
Assert-Eq 'mp.test: mixed draft exits 1' '1' "$($r7.Rc)"
Assert-Contains 'mp.test: mixed counts 3 offending lines' $r7.Out '3 offending line(s)'
Assert-Contains 'mp.test: mixed flags line 2' $r7.Out "${D7}:2"
Assert-Contains 'mp.test: mixed flags line 4' $r7.Out "${D7}:4"
Assert-Contains 'mp.test: mixed flags line 5' $r7.Out "${D7}:5"

# === 8. No raw-evidence exemption: a machine path anywhere is flagged.
$D8 = New-Draft "## Raw observations`ntool-output: /Users/dana/x`n"
Assert-Exit 'mp.test: machine path under Raw observations is still flagged → exit 1' 1 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D8

# === 9. Usage errors → exit 2.
Assert-Exit 'mp.test: missing --draft → exit 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT
Assert-Exit 'mp.test: nonexistent draft → exit 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT --draft (Join-Path ([IO.Path]::GetTempPath()) 'no-such-mp-draft.md')
Assert-Exit 'mp.test: unknown arg → exit 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D1 --bogus

# === 10. --help exits 0 and prints the banner.
$helpOut = & pwsh -NoProfile -File $CMD_SCRIPT --help 2>&1
$helpRc = $LASTEXITCODE
if ($helpOut -is [array]) { $helpOut = $helpOut -join "`n" }
Assert-Eq 'mp.test: --help exits 0' '0' "$helpRc"
Assert-Contains 'mp.test: --help prints the banner' ([string]$helpOut) 'check-machine-paths.ps1'

# === 11. Spaced draft path (cloud-vault realism) is space-safe in the report.
$SPACED = Join-Path ([IO.Path]::GetTempPath()) ('mp-spaced-' + [Guid]::NewGuid().Guid.Substring(0, 8) + [char]0x20 + 'dir')
New-Item -ItemType Directory -Path $SPACED -Force | Out-Null
$D11 = New-Draft "bad /Users/x/y`n" $SPACED
$r11 = Invoke-Mp $D11
Assert-Eq 'mp.test: spaced draft path exits 1' '1' "$($r11.Rc)"
Assert-Contains 'mp.test: spaced draft path reported intact' $r11.Out "${D11}:1"

# === 12. Unreadable (but existing) draft → exit 2. Guarded: requires chmod (Unix)
# and a non-root user; otherwise skip rather than false-fail.
$UNREAD = New-Draft "x /Users/y/z`n"
$canTest = $false
if (Get-Command chmod -ErrorAction SilentlyContinue) {
    & chmod 000 $UNREAD 2>$null
    try { $fsx = [System.IO.File]::OpenRead($UNREAD); $fsx.Close() } catch { $canTest = $true }
}
if ($canTest) {
    Assert-Exit 'mp.test: unreadable draft → exit 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $UNREAD
} else {
    _Skip 'mp.test: unreadable draft → exit 2' 'cannot revoke read on this platform/user'
}
if (Get-Command chmod -ErrorAction SilentlyContinue) { & chmod 644 $UNREAD 2>$null }

# === 13. Wiring is pinned: capabilities/closeout.md invokes the check.
$closeoutBody = [System.IO.File]::ReadAllText((Join-Path $env:REPO_ROOT 'capabilities/closeout.md'))
Assert-Contains 'mp.test: closeout.md wires the pre-drain check invocation' $closeoutBody 'scripts/check-machine-paths.sh --draft'

# === 14. Offender on the FINAL line with NO trailing newline is still caught —
# the editor-strips-trailing-newline shape (New-Draft writes content verbatim;
# ReadAllLines still returns the unterminated final line).
$D14 = New-Draft "ok line`nbad /Users/dana/x"   # deliberately no trailing newline
$r14 = Invoke-Mp $D14
Assert-Eq 'mp.test: offender on final newline-less line exits 1' '1' "$($r14.Rc)"
Assert-Contains 'mp.test: final newline-less offender flagged at line 2' $r14.Out "${D14}:2"

# === 15. Two machine paths on ONE line count as ONE offending line — the report
# and count are line-based, not match-based.
$D15 = New-Draft "both /Users/one/a and /home/two/b on one line`n"
$r15 = Invoke-Mp $D15
Assert-Eq 'mp.test: two paths on one line exit 1' '1' "$($r15.Rc)"
Assert-Contains 'mp.test: two paths on one line count as 1 offending line' $r15.Out '1 offending line(s)'

# === 16. Lowercase home root is NOT flagged — documents the case-sensitivity
# trade-off inherited from the reference (checkAgnostic matches case-sensitively).
$D16 = New-Draft "lowercase /users/dana/x stays unflagged`n"
Assert-Exit 'mp.test: lowercase /users/<name> passes (case-sensitive by contract) → exit 0' 0 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D16

# === 17. Relative -Draft from a PS location that differs from the PROCESS CWD.
# .NET file APIs resolve relative paths against the process CWD, which
# Set-Location does not move — without the Resolve-Path canonicalization this
# false-blocked ("not readable", exit 2) on a perfectly valid relative draft.
# Reproduce the divergence in a child pwsh: it inherits THIS runner's location as
# its process CWD, then Set-Location moves only its PS location to the fixture
# dir before invoking the script in-process with a bare relative filename.
# In-process invocation uses the native -Draft binding (the POSIX --draft
# passthrough is exercised by every pwsh -File case above).
$RELDIR = Join-Path ([IO.Path]::GetTempPath()) ('mp-rel-' + [Guid]::NewGuid().Guid.Substring(0, 8))
New-Item -ItemType Directory -Path $RELDIR -Force | Out-Null
Write-LfFile (Join-Path $RELDIR 'rel-draft.md') "ok`nbad /Users/dana/y`n"
$relCmd = "Set-Location -LiteralPath '$RELDIR'; & '$CMD_SCRIPT' -Draft 'rel-draft.md'; exit `$LASTEXITCODE"
$rel = & pwsh -NoProfile -Command $relCmd 2>&1
$relRc = $LASTEXITCODE
if ($rel -is [array]) { $rel = $rel -join "`n" }
Assert-Eq 'mp.test: relative -Draft from foreign process CWD exits 1 (not a false exit 2)' '1' "$relRc"
Assert-Contains 'mp.test: relative -Draft offender flagged at line 2 (path echoed as given)' ([string]$rel) 'rel-draft.md:2'
Assert-Contains 'mp.test: relative -Draft prints the offender message' ([string]$rel) 'machine-specific absolute path'

# === 18. A directory passed as --draft is a usage error → exit 2.
$DIRDRAFT = Join-Path ([IO.Path]::GetTempPath()) ('mp-dir-' + [Guid]::NewGuid().Guid.Substring(0, 8))
New-Item -ItemType Directory -Path $DIRDRAFT -Force | Out-Null
Assert-Exit 'mp.test: directory as --draft → exit 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $DIRDRAFT

# --- Cleanup.
foreach ($d in @($SPACED, $RELDIR, $DIRDRAFT)) {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
foreach ($f in @($D1, $D2, $D3, $D4, $D5OK, $D5BAD, $D6, $D7, $D8, $D14, $D15, $D16, $UNREAD)) {
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
}
