#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/spine-size.test.ps1 — Windows-native twin of tests/spine-size.test.sh.
#
# The anti-re-bloat regression gate for the native spine. The two native spine
# capabilities are re-read on every tool call for a whole session, so their
# compiled size is a MULTIPLICATIVE cost (skills/skill-authoring.md principle 5).
# Two halves, deliberately paired:
#   (a) a SIZE ceiling — the freshly compiled claude render's two SKILL.md files
#       must together stay at or under 70% of the baseline's claude combined bytes.
#   (b) STRUCTURAL anchors — the load-bearing gates that must survive any future
#       slimming. Without (b), (a) is trivially satisfiable by deleting a gate.
#   (c) a SIZE FLOOR per compiled body — the anti-gutting tripwire. The anchors in
#       (b) are substrings: a body reduced to nothing but those strings would
#       satisfy every one of them while the instructions they anchor are gone.
#   (d) SOURCE-body ceilings against the baseline's `source` record, so re-bloat
#       authored into capabilities/*.md is caught for EVERY harness render
#       without building four of them.
#
# Byte counts are taken from the file LENGTH on disk (install.ps1 renders LF
# endings, same as the bash lane), so both twins compare like with like.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$SS_BASELINE = Join-Path $env:REPO_ROOT 'tests' 'fixtures' 'spine-baseline.json'
Assert-File 'spine-size.test: baseline fixture exists' $SS_BASELINE

$ssBase = $null
if (Test-Path -LiteralPath $SS_BASELINE) {
    $ssBase = Get-Content -LiteralPath $SS_BASELINE -Raw | ConvertFrom-Json
}

Assert-Eq 'spine-size.test: baseline records a capture date' 'yes' `
    $(if ($ssBase -and $ssBase.captured) { 'yes' } else { 'no' })

foreach ($render in @('claude', 'codex', 'agents', 'hermes', 'source')) {
    foreach ($cap in @('session_agent', 'closeout')) {
        foreach ($field in @('bytes', 'lines')) {
            $v = $null
            if ($ssBase -and $ssBase.per_render.$render -and $ssBase.per_render.$render.$cap) {
                $v = $ssBase.per_render.$render.$cap.$field
            }
            Assert-Eq "spine-size.test: baseline has per_render.$render.$cap.$field" 'yes' `
                $(if ($null -ne $v -and [int]$v -gt 0) { 'yes' } else { 'no' })
        }
    }
}

foreach ($field in @('harness', 'tool_calls', 'fixed_reads', 'tracker_calls', 'wall_time')) {
    $v = $null
    if ($ssBase -and $ssBase.live_mode1_sample) { $v = $ssBase.live_mode1_sample.$field }
    Assert-Eq "spine-size.test: baseline live_mode1_sample records $field" 'yes' `
        $(if ($null -ne $v -and "$v" -ne '') { 'yes' } else { 'no' })
}

$ssBaseSa = [int]$ssBase.per_render.claude.session_agent.bytes
$ssBaseCl = [int]$ssBase.per_render.claude.closeout.bytes
$ssBaseCombined = $ssBaseSa + $ssBaseCl
# Integer ceiling at 70% — the acceptance bar is "at least 30 percent smaller".
$ssCeiling = [int][math]::Floor($ssBaseCombined * 70 / 100)

# --- (c) anti-gutting FLOORS on the compiled bodies ---------------------------
# Hard byte minimums, not baseline-derived: the ceiling and the substring anchors
# are both satisfiable by a body stripped down to the anchor strings themselves.
# These sit well below the current bodies — a tripwire, not a target.
$ssFloorSa = 10000
$ssFloorCl = 15000

# --- (d) SOURCE-body ceilings -------------------------------------------------
$ssSrcSa = Join-Path $env:REPO_ROOT 'capabilities' 'session-agent.md'
$ssSrcCl = Join-Path $env:REPO_ROOT 'capabilities' 'closeout.md'
$ssBaseSrcSa = [int]$ssBase.per_render.source.session_agent.bytes
$ssBaseSrcCl = [int]$ssBase.per_render.source.closeout.bytes
$ssSrcCeilSa = [int][math]::Floor($ssBaseSrcSa * 70 / 100)
$ssSrcCeilCl = [int][math]::Floor($ssBaseSrcCl * 70 / 100)
# Byte length via the raw text encoded LF-normalized: a CRLF checkout would
# otherwise inflate the count against an LF-captured baseline and fail a source
# body that never changed.
function Get-SpineSourceBytes([string]$path) {
    $t = [System.IO.File]::ReadAllText($path) -replace "`r`n", "`n"
    return [System.Text.Encoding]::UTF8.GetByteCount($t)
}
$ssNowSrcSa = Get-SpineSourceBytes $ssSrcSa
$ssNowSrcCl = Get-SpineSourceBytes $ssSrcCl

if ($ssNowSrcSa -le $ssSrcCeilSa) {
    _Pass "spine-size.test: source session-agent.md is <= 70% of its baseline ($ssNowSrcSa <= $ssSrcCeilSa bytes)"
} else {
    _Fail 'spine-size.test: source session-agent.md is <= 70% of its baseline' `
        "now=$ssNowSrcSa ceiling=$ssSrcCeilSa baseline=$ssBaseSrcSa"
}
if ($ssNowSrcCl -le $ssSrcCeilCl) {
    _Pass "spine-size.test: source closeout.md is <= 70% of its baseline ($ssNowSrcCl <= $ssSrcCeilCl bytes)"
} else {
    _Fail 'spine-size.test: source closeout.md is <= 70% of its baseline' `
        "now=$ssNowSrcCl ceiling=$ssSrcCeilCl baseline=$ssBaseSrcCl"
}

# --- build a claude render (same temp-install pattern as compiler.test.ps1) ---
$ssDir = Join-Path ([System.IO.Path]::GetTempPath()) ("spine-size-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ssDir -Force | Out-Null
$ssOut = Join-Path $ssDir 'out'
New-Item -ItemType Directory -Path $ssOut -Force | Out-Null
$ssEnv = Join-Path $ssDir 'local.env'
Write-LocalEnvFixture -EnvFile $ssEnv -ConfigDir $ssOut -VaultDir (Join-Path $ssDir 'vault')

$INSTALL_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$env:AI_CONFIG_LOCAL_ENV = $ssEnv
try {
    $ssBuildRaw = & pwsh -NoProfile -File $INSTALL_PS1 --harness claude --build-only 2>$null
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
if ($ssBuildRaw -is [array]) { $ssBuild = $ssBuildRaw | Select-Object -Last 1 } else { $ssBuild = $ssBuildRaw }

$ssSa = if ($ssBuild) { Join-Path $ssBuild 'skills' 'session-agent' 'SKILL.md' } else { '' }
$ssCl = if ($ssBuild) { Join-Path $ssBuild 'skills' 'closeout' 'SKILL.md' } else { '' }

if ($ssBuild -and (Test-Path -LiteralPath $ssSa) -and (Test-Path -LiteralPath $ssCl)) {
    $ssNowSa = [int](Get-Item -LiteralPath $ssSa).Length
    $ssNowCl = [int](Get-Item -LiteralPath $ssCl).Length
    $ssNowCombined = $ssNowSa + $ssNowCl

    if ($ssNowCombined -le $ssCeiling) {
        _Pass "spine-size.test: compiled spine is <= 70% of the baseline ($ssNowCombined <= $ssCeiling bytes)"
    } else {
        _Fail 'spine-size.test: compiled spine is <= 70% of the baseline' `
            "combined=$ssNowCombined ceiling=$ssCeiling baseline=$ssBaseCombined (session-agent=$ssNowSa closeout=$ssNowCl)"
    }

    # Neither capability may grow past its own baseline either — a combined-only
    # ceiling lets one body balloon while the other is gutted.
    if ($ssNowSa -le $ssBaseSa) {
        _Pass "spine-size.test: compiled session-agent does not exceed its baseline ($ssNowSa <= $ssBaseSa)"
    } else {
        _Fail 'spine-size.test: compiled session-agent does not exceed its baseline' "now=$ssNowSa baseline=$ssBaseSa"
    }
    if ($ssNowCl -le $ssBaseCl) {
        _Pass "spine-size.test: compiled closeout does not exceed its baseline ($ssNowCl <= $ssBaseCl)"
    } else {
        _Fail 'spine-size.test: compiled closeout does not exceed its baseline' "now=$ssNowCl baseline=$ssBaseCl"
    }

    # Anti-gutting floors: deleting the instructions while keeping the anchor
    # strings below would otherwise read as a clean pass.
    if ($ssNowSa -ge $ssFloorSa) {
        _Pass "spine-size.test: compiled session-agent is above the anti-gutting floor ($ssNowSa >= $ssFloorSa)"
    } else {
        _Fail 'spine-size.test: compiled session-agent is above the anti-gutting floor' `
            "now=$ssNowSa floor=$ssFloorSa — the body has been hollowed out, not slimmed"
    }
    if ($ssNowCl -ge $ssFloorCl) {
        _Pass "spine-size.test: compiled closeout is above the anti-gutting floor ($ssNowCl >= $ssFloorCl)"
    } else {
        _Fail 'spine-size.test: compiled closeout is above the anti-gutting floor' `
            "now=$ssNowCl floor=$ssFloorCl — the body has been hollowed out, not slimmed"
    }

    $ssSaBody = Get-Content -LiteralPath $ssSa -Raw
    $ssClBody = Get-Content -LiteralPath $ssCl -Raw

    # --- (b) load-bearing structural anchors in the COMPILED bodies ------------
    # The two declaration lines the pre-edit-gate hook greps for — see
    # harnesses/claude/hooks/session-agent.ps1.
    Assert-Contains 'spine-size.test: compiled session-agent carries the Linear gate declaration line' `
        $ssSaBody 'Linear gate: <ISSUE-ID or URL>'
    Assert-Contains 'spine-size.test: compiled session-agent carries the Lessons declaration line' `
        $ssSaBody 'Lessons: <matched lesson'
    # R2b's execution-shape declaration — the routing walk's HOW line.
    Assert-Contains 'spine-size.test: compiled session-agent carries the Execution declaration line' `
        $ssSaBody 'Execution: inline | delegated wave | delegated wave + panel'
    # Every execution shape R2b names, pinned WITH its cascade position. The bare
    # values are satisfiable by an unrelated mention elsewhere in the body (the Notes
    # honesty bullet names `inline`), so a value-only loop would not notice R2b
    # losing a rule — nor the risk-before-size ORDER the numbering encodes.
    foreach ($exec in @('1. `delegated wave + panel`', '2. `delegated wave`', '3. `inline`')) {
        Assert-Contains ('spine-size.test: compiled session-agent keeps R2b cascade rule ' + $exec) `
            $ssSaBody $exec
    }
    # ORDER, not just presence: the numbering is only meaningful if the rules appear
    # in it — risk BEFORE size BEFORE the residue. A future slim that reshuffles the
    # cascade keeps every needle above and would pass on presence alone.
    $ssO1 = $ssSaBody.IndexOf('1. `delegated wave + panel`')
    $ssO2 = $ssSaBody.IndexOf('2. `delegated wave`')
    $ssO3 = $ssSaBody.IndexOf('3. `inline`')
    if ($ssO1 -ge 0 -and $ssO1 -lt $ssO2 -and $ssO2 -lt $ssO3) {
        _Pass 'spine-size.test: compiled session-agent keeps the R2b cascade order 1→2→3'
    } else {
        _Fail 'spine-size.test: compiled session-agent keeps the R2b cascade order 1→2→3' `
            "offsets rule1=$ssO1 rule2=$ssO2 rule3=$ssO3 (want 0 <= rule1 < rule2 < rule3)"
    }
    foreach ($val in @('none match', 'index unreachable', 'skipped — ')) {
        Assert-Contains "spine-size.test: compiled session-agent names the Lessons value '$val'" $ssSaBody $val
    }
    Assert-Contains 'spine-size.test: compiled session-agent instructs the gate-marker write path' `
        $ssSaBody 'agentic-os/gate-<session_id>'
    Assert-Contains 'spine-size.test: compiled session-agent keeps the Mode 1 / Mode 2 selection rule' `
        $ssSaBody 'run Mode 1. Otherwise run Mode 2'
    Assert-Contains 'spine-size.test: compiled session-agent wires scripts/orient.sh' $ssSaBody 'scripts/orient.sh'
    Assert-Contains 'spine-size.test: compiled session-agent keeps the projects-first cut' $ssSaBody 'projects-first'

    Assert-Contains 'spine-size.test: compiled closeout wires scripts/closeout-gate.sh' `
        $ssClBody 'scripts/closeout-gate.sh --draft'
    Assert-Contains 'spine-size.test: compiled closeout keeps the fail-closed do-not-write rule' `
        $ssClBody 'Non-zero = do NOT write'
    Assert-Contains 'spine-size.test: compiled closeout keeps the 8-question walk header' `
        $ssClBody 'The 8 closeout questions'
    Assert-Contains 'spine-size.test: compiled closeout keeps Q7a git status --porcelain' `
        $ssClBody 'git status --porcelain'
    Assert-Contains 'spine-size.test: compiled closeout keeps Q7a git diff --cached --quiet' `
        $ssClBody 'git diff --cached --quiet'
    Assert-Contains 'spine-size.test: compiled closeout keeps Q7a git diff --quiet' `
        $ssClBody 'git diff --quiet'
    foreach ($class in @('rule', 'check', 'script', 'linear', 'obsidian', 'playbook', 'skill', 'data-readiness', 'goal-run', 'no-action', 'state-delta')) {
        Assert-Contains "spine-size.test: compiled closeout classification table lists ``$class``" `
            $ssClBody ('| `' + $class + '` |')
    }
} else {
    _Fail 'spine-size.test: claude render produced both spine SKILL.md files' `
        "build='$ssBuild' session-agent='$ssSa' closeout='$ssCl'"
}

if ($ssBuild) { Remove-Item -LiteralPath $ssBuild -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $ssDir -Recurse -Force -ErrorAction SilentlyContinue
