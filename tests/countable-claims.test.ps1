#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/countable-claims.test.ps1 — PowerShell twin of countable-claims.test.sh.
# Pins the framework's countable "N of a kind" facts to the filesystem so a prose
# count and reality can't silently diverge. See the bash twin's header for the
# full rationale and acceptance criterion. FAST tier — reads only.
#
# Behavioral parity with the bash twin is the contract: same three ground-truth
# counts derived the same way, same num->word mapping, same prose anchors.

$repo = $env:REPO_ROOT

# Get-NumWord <n> — English word for a small non-negative integer (0..9). Mirror
# of bash num_word. An out-of-range count echoes its digits so the prose
# assertion fails loudly rather than matching a bogus empty string.
function Get-NumWord {
    param([int]$N)
    switch ($N) {
        0 { 'zero' }
        1 { 'one' }
        2 { 'two' }
        3 { 'three' }
        4 { 'four' }
        5 { 'five' }
        6 { 'six' }
        7 { 'seven' }
        8 { 'eight' }
        9 { 'nine' }
        default { "$N" }
    }
}

# === ground truth #1: adapter count = harnesses/*/adapter.md ================
$adapterCount = @(
    Get-ChildItem -LiteralPath (Join-Path $repo 'harnesses') -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'adapter.md') -PathType Leaf }
).Count
$adapterWord = Get-NumWord $adapterCount
Assert-Eq "adapters: harnesses/*/adapter.md parsed (non-empty)" "yes" $(if ($adapterCount -ge 1) { 'yes' } else { 'no' })
$capReadme = Get-Content -LiteralPath (Join-Path $repo 'capabilities/README.md') -Raw
Assert-Contains "capabilities/README.md adapter count matches the filesystem ($adapterCount -> '$adapterWord')" `
    $capReadme "$adapterWord adapter"

# === ground truth #2: native spine = capabilities/*.md with `kind: native` ===
# -ccontains is a case-sensitive whole-element match, mirroring bash `grep -qx`:
# README.md's schema line `kind: native | vendored` is not an exact-line match
# and must not be counted.
$nativeCount = 0
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $repo 'capabilities') -Filter '*.md' -File) {
    $lines = @(Get-Content -LiteralPath $f.FullName)
    if ($lines -ccontains 'kind: native') { $nativeCount++ }
}
$nativeWord = Get-NumWord $nativeCount
Assert-Eq "spine: capabilities/*.md kind:native parsed (non-empty)" "yes" $(if ($nativeCount -ge 1) { 'yes' } else { 'no' })
$selfAuditMd = Get-Content -LiteralPath (Join-Path $repo 'capabilities/self-audit.md') -Raw
Assert-Contains "self-audit.md spine count matches the filesystem ($nativeCount -> '$nativeWord')" `
    $selfAuditMd "$nativeWord spine"

# Cross-form pin: the DIGIT-form claim in harnesses/codex/adapter.md must agree
# with the same filesystem counts (the word-form anchors don't cover digits).
$codexAdapter = Get-Content -LiteralPath (Join-Path $repo 'harnesses/codex/adapter.md') -Raw
Assert-Contains "codex/adapter.md digit claim matches the filesystem ($nativeCount spine x $adapterCount harnesses)" `
    $codexAdapter "$nativeCount spine capabilities × $adapterCount harnesses"

# === ground truth #3: pillar count = PILLAR_KEYS entries in self-audit.sh =====
# Mirror of the bash _PILLAR_AWK parser: count quoted ENTRIES (not lines) in the
# `PILLAR_KEYS=( ... )` array literal, robust to reformatting — indented `)`, an
# inline last entry, or the whole array on one line. A function so the detector
# unit tests below can exercise it against those shapes.
function Get-PillarCount {
    param([Parameter(Mandatory)][string]$Path)
    $count = 0; $inArr = $false; $done = $false
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match 'PILLAR_KEYS=\(') { $inArr = $true }
        if ($inArr -and -not $done) {
            $count += ([regex]::Matches($line, '"[^"]+"')).Count
            if ($line -match '\)') { $done = $true }
        }
    }
    $count
}
$pillarCount = Get-PillarCount (Join-Path $repo 'scripts/self-audit.sh')
$pillarWord = Get-NumWord $pillarCount
Assert-Eq "pillars: self-audit.sh PILLAR_KEYS parsed (non-empty)" "yes" $(if ($pillarCount -ge 1) { 'yes' } else { 'no' })
Assert-Contains "self-audit.md pillar count matches self-audit.sh PILLAR_KEYS ($pillarCount -> '$pillarWord')" `
    $selfAuditMd "$pillarWord pillars"
$selfAuditSh = Get-Content -LiteralPath (Join-Path $repo 'scripts/self-audit.sh') -Raw
Assert-Contains "self-audit.sh header pillar count matches PILLAR_KEYS ($pillarCount -> '$pillarWord')" `
    $selfAuditSh "$pillarWord pillars"

# === ground truth #4: README harness-compat matrix == adapter "Verified against"
# Mirror of the bash twin: the README compat table summarizes each adapter's
# "Verified against vX.Y.Z" line (the adapter is the source of truth), so pin the
# summary to that source. Bump an adapter without the README (or vice-versa) and
# this goes RED.
$readmeLines = @(Get-Content -LiteralPath (Join-Path $repo 'README.md'))
foreach ($h in @('claude', 'codex', 'hermes', 'cursor')) {
    $adapterTxt = Get-Content -LiteralPath (Join-Path $repo "harnesses/$h/adapter.md") -Raw
    # Extract BOTH the display name and the version from the adapter's
    # "Verified against **<Display Name> vX.Y.Z**" so the README check binds the
    # version to the correctly-NAMED matrix row (a row-swap or prose-only version
    # must fail, not just "present somewhere").
    $label = ''
    $m = [regex]::Match($adapterTxt, 'Verified against \*\*([^*]*)\*\*')
    if ($m.Success) { $label = $m.Groups[1].Value }
    $ver = ''
    $vm = [regex]::Match($label, 'v\d+\.\d+\.\d+')
    if ($vm.Success) { $ver = $vm.Value }
    $name = ($label -replace ' v\d.*$', '')
    Assert-Eq "$h/adapter.md declares a Verified-against version (non-empty)" "yes" $(if ($ver) { 'yes' } else { 'no' })
    # The matrix ROW for this harness (a table line naming it) must carry its version.
    $row = @($readmeLines | Where-Object { $_ -match '^\|' -and $_ -like "*$name*" } | Select-Object -First 1)
    Assert-Contains "README compat matrix row for '$name' carries adapter version ($ver)" `
        ([string]$row) $ver
}

# === negative regressions: the specific stale count claims stay fixed ========
Assert-NotContains "capabilities/README.md no longer claims 'two adapters'" `
    $capReadme "two adapters"
# Single-line needle (CRLF-immune): the corrected example lists hermes.
# "[claude, codex]" is not a substring of "[claude, codex, hermes]".
$lifecycleMd = Get-Content -LiteralPath (Join-Path $repo 'core/lifecycle.md') -Raw
Assert-Contains "core/lifecycle.md capability example includes hermes (not the stale [claude, codex])" `
    $lifecycleMd "harnesses: [claude, codex, hermes]"

# === detector unit tests: Get-NumWord + a stale-prose fixture trips the guard =
Assert-Eq "num_word maps 3 -> three" "three" (Get-NumWord 3)
Assert-Eq "num_word maps 5 -> five" "five" (Get-NumWord 5)
Assert-Eq "num_word maps 4 -> four (the next-harness case)" "four" (Get-NumWord 4)

# Simulate a 4th harness landing (FS count 4 -> 'four') while prose still says
# 'three adapters': the contains-check the real guard uses must MISS (return
# False), i.e. the guard would go RED. Control: it HOLDS when FS and prose agree.
$fixtureProse = "the framework ships three adapters today"
Assert-Eq "guard trips when FS count (4->four) disagrees with stale prose ('three')" "False" `
    ([string]$fixtureProse.Contains("$(Get-NumWord 4) adapter"))
Assert-Eq "guard holds when FS count (3->three) agrees with prose" "True" `
    ([string]$fixtureProse.Contains('three adapter'))

# pillar parser robustness — it must count ENTRIES, not lines, regardless of how
# the array literal is formatted (the cross-model panel flagged the original
# line-based parser as brittle to reformatting).
$pillarFix = [System.IO.Path]::GetTempFileName()
@"
PILLAR_KEYS=(
  "a"
  "b"
  "c"
)
"@ | Set-Content -LiteralPath $pillarFix
Assert-Eq "pillar parser: standard multi-line array -> 3" "3" ([string](Get-PillarCount $pillarFix))
@"
PILLAR_KEYS=( "a" "b" "c" "d" )
"@ | Set-Content -LiteralPath $pillarFix
Assert-Eq "pillar parser: single-line array -> 4" "4" ([string](Get-PillarCount $pillarFix))
@"
PILLAR_KEYS=(
  "a"
  "b" )
"@ | Set-Content -LiteralPath $pillarFix
Assert-Eq "pillar parser: inline closing paren -> 2" "2" ([string](Get-PillarCount $pillarFix))
Remove-Item -LiteralPath $pillarFix -Force
