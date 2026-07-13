#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/wikilinks.test.ps1 — Windows-native twin of tests/wikilinks.test.sh.
#
# Behavioral tests for scripts/check-wikilinks.ps1. The check resolves every
# [[wikilink]] in a drafted session-log body the SAME way the vault audit's
# checkWikilinks does: a target resolves iff the vault holds a note at that full
# vault-relative path (±ext) or — for the vault ROOT only — a note with that bare
# name. Exit 0 = all resolve (or none), 1 = one or more unresolved, 2 = usage error.
#
# Mirrors the .sh twin 1:1 — same fixtures, same assertions.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$CMD_SCRIPT = Join-Path $env:REPO_ROOT 'scripts' 'check-wikilinks.ps1'
Assert-File 'wl.test: scripts/check-wikilinks.ps1 exists' $CMD_SCRIPT

function Write-LfFile {
    param([string]$Path, [string]$Content)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function New-TempDir {
    param([string]$Prefix = 'wl-test')
    $d = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + '-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $d
}

# New-MkVault <dir> — fixture vault matching the .sh twin: two root notes, two
# subfolder notes, one root .base, one subfolder .base.
function New-MkVault {
    param([string]$V)
    New-Item -ItemType Directory -Path (Join-Path $V '10-Wiki/Concepts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $V '02-Areas') -Force | Out-Null
    Write-LfFile (Join-Path $V 'START.md')  "---`ntitle: START`n---`n"
    Write-LfFile (Join-Path $V 'README.md') "---`ntitle: README`n---`n"
    Write-LfFile (Join-Path $V '10-Wiki/Concepts/Foo.md') "---`ntitle: Foo`n---`n"
    Write-LfFile (Join-Path $V '02-Areas/Bar.md') "---`ntitle: Bar`n---`n"
    Write-LfFile (Join-Path $V 'RootView.base') "rootbase`n"
    Write-LfFile (Join-Path $V '10-Wiki/SubView.base') "subbase`n"
}

# New-Draft <content> — write content to a fresh temp file, return its path.
# Callers pass single-quoted strings so literal backticks survive (PS escape char).
function New-Draft {
    param([string]$Content)
    $f = Join-Path ([IO.Path]::GetTempPath()) ('wl-draft-' + [Guid]::NewGuid().Guid.Substring(0, 8) + '.md')
    Write-LfFile $f ($Content + "`n")
    $f
}

# Invoke-Wl <draft> <vault> — run the script, return @{ Out=<joined>; Rc=<int> }.
function Invoke-Wl {
    param([string]$Draft, [string]$Vault)
    $out = & pwsh -NoProfile -File $CMD_SCRIPT --draft $Draft --vault $Vault 2>&1
    $rc = $LASTEXITCODE
    if ($out -is [array]) { $out = $out -join "`n" }
    return @{ Out = [string]$out; Rc = $rc }
}

$VAULT = New-TempDir 'wl-vault'
New-MkVault $VAULT

# === 1. Full vault-relative path resolves → exit 0, PASS.
$D1 = New-Draft 'See [[10-Wiki/Concepts/Foo]] for details.'
$r1 = Invoke-Wl $D1 $VAULT
Assert-Eq 'wl.test: full-path link exits 0' '0' "$($r1.Rc)"
Assert-Contains 'wl.test: full-path link reports PASS' $r1.Out 'PASS all 1 wikilink'

# === 2. Root-level bare names resolve → exit 0.
$D2 = New-Draft 'Start at [[START]] and [[README]].'
Assert-Exit 'wl.test: root bare names resolve → exit 0' 0 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D2 --vault $VAULT

# === 3. Bare-basename SUBFOLDER link fails closed → exit 1, names it + suggests.
$D3 = New-Draft 'Bad bare [[Foo]] subfolder link.'
$r3 = Invoke-Wl $D3 $VAULT
Assert-Eq 'wl.test: bare subfolder link exits 1 (fail closed)' '1' "$($r3.Rc)"
Assert-Contains 'wl.test: names the unresolved target' $r3.Out 'unresolved wikilink:'
Assert-Contains 'wl.test: names the bare target Foo' $r3.Out '-> Foo'
Assert-Contains 'wl.test: suggests the full path' $r3.Out '[[10-Wiki/Concepts/Foo]]'
Assert-Contains 'wl.test: failure summary counts unresolved' $r3.Out '1 of 1 wikilink target(s) unresolved'

# === 4. Alias `|` and heading `#` stripped; path still resolves → exit 0.
$D4 = New-Draft 'Alias [[10-Wiki/Concepts/Foo|nickname]] and heading [[10-Wiki/Concepts/Foo#a-section]].'
Assert-Exit 'wl.test: aliased + heading links resolve → exit 0' 0 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D4 --vault $VAULT

# === 5. Backticked memory-store names are NOT wikilinks → ignored → exit 0.
$D5 = New-Draft 'Memory notes `project-foo`, `feedback-bar`, `reference-baz` are backticked.'
$r5 = Invoke-Wl $D5 $VAULT
Assert-Eq 'wl.test: backticked memory names ignored → exit 0' '0' "$($r5.Rc)"
Assert-Contains 'wl.test: backticked-only draft has 0 wikilinks' $r5.Out 'all 0 wikilink'

# === 6. A memory-store name WRONGLY wikilinked fails → exit 1.
$D6 = New-Draft 'Wrong [[project-foo]] should be backticked.'
$r6 = Invoke-Wl $D6 $VAULT
Assert-Eq 'wl.test: wrongly-wikilinked memory name fails → exit 1' '1' "$($r6.Rc)"
Assert-Contains 'wl.test: names the wrongly-wikilinked target' $r6.Out '-> project-foo'

# === 7. No wikilinks → exit 0.
$D7 = New-Draft 'Just prose, nothing to resolve.'
Assert-Exit 'wl.test: no wikilinks → exit 0' 0 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D7 --vault $VAULT

# === 8. Explicit .md / .base extension resolves → exit 0.
$D8 = New-Draft 'Ext [[10-Wiki/Concepts/Foo.md]] and base [[10-Wiki/SubView.base]].'
Assert-Exit 'wl.test: explicit .md / .base extension resolves → exit 0' 0 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D8 --vault $VAULT

# === 9. .base mirrors .md: root .base bare resolves, subfolder .base bare fails.
$D9OK = New-Draft 'Root base [[RootView]] ok.'
Assert-Exit 'wl.test: root-level .base bare name resolves → exit 0' 0 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D9OK --vault $VAULT
$D9BAD = New-Draft 'Sub base [[SubView]] bad.'
Assert-Exit 'wl.test: subfolder .base bare name fails → exit 1' 1 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D9BAD --vault $VAULT

# === 10. Malformed empty link [[ ]] is fail-closed.
$D10 = New-Draft 'Empty [[ ]] link.'
$r10 = Invoke-Wl $D10 $VAULT
Assert-Eq 'wl.test: empty [[ ]] target fails closed → exit 1' '1' "$($r10.Rc)"
Assert-Contains 'wl.test: empty target reported as (empty)' $r10.Out '-> (empty)'

# === 11. Mixed draft: distinct targets counted; some resolve, some not → exit 1.
$D11 = New-Draft 'Good [[START]] and [[10-Wiki/Concepts/Foo]], bad [[Bar]] and [[Nope]].'
$r11 = Invoke-Wl $D11 $VAULT
Assert-Eq 'wl.test: mixed draft exits 1' '1' "$($r11.Rc)"
Assert-Contains 'wl.test: mixed draft counts 2 of 4 distinct unresolved' $r11.Out '2 of 4 wikilink target(s) unresolved'
Assert-Contains 'wl.test: mixed flags Bar' $r11.Out '-> Bar'
Assert-Contains 'wl.test: mixed flags Nope' $r11.Out '-> Nope'

# === 12. Duplicate links dedup to distinct targets in the count.
$D12 = New-Draft '[[START]] again [[START]] and once more [[START]].'
$r12 = Invoke-Wl $D12 $VAULT
Assert-Contains 'wl.test: duplicate links dedup to 1 distinct target' $r12.Out 'all 1 wikilink'

# === 13. Ambiguous basename → bare name fails with NO suggestion.
$AMB = New-TempDir 'wl-amb'
New-Item -ItemType Directory -Path (Join-Path $AMB 'A') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $AMB 'B') -Force | Out-Null
Write-LfFile (Join-Path $AMB 'A/Dup.md') "a`n"
Write-LfFile (Join-Path $AMB 'B/Dup.md') "b`n"
$D13 = New-Draft 'Ambiguous [[Dup]].'
$r13 = Invoke-Wl $D13 $AMB
Assert-Eq 'wl.test: ambiguous bare name fails → exit 1' '1' "$($r13.Rc)"
Assert-NotContains 'wl.test: ambiguous bare name gives NO suggestion' $r13.Out 'did you mean'

# === 14. Vault derived from OBSIDIAN_VAULT_PATH when --vault omitted.
$savedVault = $env:OBSIDIAN_VAULT_PATH
try {
    $env:OBSIDIAN_VAULT_PATH = $VAULT
    $out14 = & pwsh -NoProfile -File $CMD_SCRIPT --draft $D1 2>&1
    Assert-Eq 'wl.test: vault from OBSIDIAN_VAULT_PATH env → exit 0' '0' "$LASTEXITCODE"
} finally {
    if ($null -ne $savedVault) { $env:OBSIDIAN_VAULT_PATH = $savedVault }
    else { Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue }
}

# === 15. Spaced vault path (cloud-vault realism) resolves space-safely.
$VSPACE_ROOT = New-TempDir 'wl-space'
$VSPACE = Join-Path $VSPACE_ROOT 'My Vault'
New-Item -ItemType Directory -Path (Join-Path $VSPACE '10-Wiki/Concepts') -Force | Out-Null
Write-LfFile (Join-Path $VSPACE '10-Wiki/Concepts/Foo.md') "---`ntitle: Foo`n---`n"
Assert-Exit 'wl.test: spaced vault path resolves → exit 0' 0 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D1 --vault $VSPACE

# === 16. Usage errors → exit 2.
Assert-Exit 'wl.test: missing --draft → exit 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT --vault $VAULT
$missingDraft = '/tmp/no-such-draft-' + [Guid]::NewGuid().Guid.Substring(0, 8)
Assert-Exit 'wl.test: nonexistent draft → exit 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $missingDraft --vault $VAULT
$missingVault = '/tmp/no-such-vault-' + [Guid]::NewGuid().Guid.Substring(0, 8)
Assert-Exit 'wl.test: nonexistent vault → exit 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D1 --vault $missingVault
# No --vault + no OBSIDIAN_VAULT_PATH → exit 2 (save/clear/restore env).
$savedVault2 = $env:OBSIDIAN_VAULT_PATH
try {
    Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
    & pwsh -NoProfile -File $CMD_SCRIPT --draft $D1 *>$null
    Assert-Eq 'wl.test: no --vault + no OBSIDIAN_VAULT_PATH → exit 2' '2' "$LASTEXITCODE"
} finally {
    if ($null -ne $savedVault2) { $env:OBSIDIAN_VAULT_PATH = $savedVault2 }
}
Assert-Exit 'wl.test: unknown arg → exit 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D1 --vault $VAULT --bogus

# === 17. --help exits 0 and prints the banner.
$helpOut = & pwsh -NoProfile -File $CMD_SCRIPT --help 2>&1
$helpRc = $LASTEXITCODE
if ($helpOut -is [array]) { $helpOut = $helpOut -join "`n" }
Assert-Eq 'wl.test: --help exits 0' '0' "$helpRc"
Assert-Contains 'wl.test: --help prints the banner' $helpOut 'check-wikilinks.ps1'

# === 18. Code spans are NOT stripped — a wikilink inside inline code is still
# checked (matches the audit, which does not exempt code spans).
$D18 = New-Draft 'Inline code with a real link `[[Foo]]` is still checked.'
Assert-Exit 'wl.test: wikilink inside inline-code is still checked (audit fidelity)' 1 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D18 --vault $VAULT

# === 19. No display-sentinel collision: a vault note literally named `(empty)`
# makes [[(empty)]] resolve, while a malformed [[ ]] still fails closed rendered
# as "(empty)". Proves the empty target is carried as "" through resolution.
$VEMPTY = New-TempDir 'wl-vempty'
Write-LfFile (Join-Path $VEMPTY '(empty).md') "---`ntitle: empty`n---`n"
$D19a = New-Draft 'Link to [[(empty)]] real root note.'
Assert-Exit 'wl.test: [[(empty)]] resolves to a real (empty).md (no sentinel collision)' 0 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $D19a --vault $VEMPTY
$D19b = New-Draft 'Malformed [[ ]] link.'
$r19b = Invoke-Wl $D19b $VEMPTY
Assert-Eq 'wl.test: malformed [[ ]] still fails even when (empty).md exists' '1' "$($r19b.Rc)"
Assert-Contains 'wl.test: malformed empty target rendered as (empty)' $r19b.Out '-> (empty)'

# === 20. Wiring is pinned: capabilities/closeout.md invokes the check so a future
# refactor that drops the pre-drain gate is caught here.
$closeoutBody = [System.IO.File]::ReadAllText((Join-Path $env:REPO_ROOT 'capabilities/closeout.md'))
Assert-Contains 'wl.test: closeout.md wires the pre-drain check invocation' $closeoutBody 'scripts/check-wikilinks.sh --draft'

# === 21. Unreadable (but existing) draft → exit 2. Guarded: requires chmod (Unix)
# and a non-root user; otherwise skip rather than false-fail.
$UNREAD = New-Draft 'x [[START]]'
$canTest = $false
if (Get-Command chmod -ErrorAction SilentlyContinue) {
    & chmod 000 $UNREAD 2>$null
    try { $fsx = [System.IO.File]::OpenRead($UNREAD); $fsx.Close() } catch { $canTest = $true }
}
if ($canTest) {
    Assert-Exit 'wl.test: unreadable draft → exit 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT --draft $UNREAD --vault $VAULT
} else {
    _Skip 'wl.test: unreadable draft → exit 2' 'cannot revoke read on this platform/user'
}
if (Get-Command chmod -ErrorAction SilentlyContinue) { & chmod 644 $UNREAD 2>$null }

# --- Cleanup.
foreach ($d in @($VAULT, $AMB, $VSPACE_ROOT, $VEMPTY)) {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
foreach ($f in @($D1, $D2, $D3, $D4, $D5, $D6, $D7, $D8, $D9OK, $D9BAD, $D10, `
                 $D11, $D12, $D13, $D18, $D19a, $D19b, $UNREAD)) {
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
}
