#Requires -Version 7
# tests/closeout-format.test.ps1 — Windows-native twin of tests/closeout-format.test.sh.
#
# Asserts the closeout shape carries the state-delta class + State Deltas
# section across all four definition files, plus the
# position invariants. Pure content-only; no script invocation. Per
# [[reference_ps_port_traps]] trap #8 the PS twin is the pair-test that catches
# numeric-constant drift between bash + PS surfaces.
#
# Mirrors tests/closeout-format.test.sh 1:1.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

# --- Helper: line number of an exact heading match, or 0 if missing.
# Mirrors bash twin's heading_line. Uses Get-Content + Where-Object so
# Windows CRLF doesn't affect the match (lines are split + trimmed by PS).
function Get-HeadingLine {
    param([string]$Path, [string]$Heading)
    $lines = Get-Content -LiteralPath $Path
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -ceq $Heading) { return $i + 1 }
    }
    return 0
}

# --- 1. core/self-improvement.md ---
$SI_PATH = Join-Path $env:REPO_ROOT 'core' 'self-improvement.md'
$SI_CONTENT = Get-Content -LiteralPath $SI_PATH -Raw

Assert-Contains 'closeout-format.test: self-improvement.md lists state-delta class' `
    $SI_CONTENT '`state-delta`'

Assert-Contains 'closeout-format.test: self-improvement.md has the State Deltas inputs section' `
    $SI_CONTENT '## Inputs — State Deltas'

# --- 2. capabilities/closeout.md ---
$CL_PATH = Join-Path $env:REPO_ROOT 'capabilities' 'closeout.md'
$CL_CONTENT = Get-Content -LiteralPath $CL_PATH -Raw

Assert-Contains 'closeout-format.test: closeout.md routing table includes state-delta' `
    $CL_CONTENT '`state-delta`'

Assert-Contains 'closeout-format.test: closeout.md output block requires ## State Deltas' `
    $CL_CONTENT '## State Deltas'

Assert-Contains 'closeout-format.test: closeout.md Inputs section enumerates State Deltas' `
    $CL_CONTENT 'Enumerate State Deltas'

# --- 3. linear/closeout-format.md ---
$LF_PATH = Join-Path $env:REPO_ROOT 'linear' 'closeout-format.md'
$LF_CONTENT = Get-Content -LiteralPath $LF_PATH -Raw

Assert-Contains 'closeout-format.test: closeout-format.md has ## State Deltas section' `
    $LF_CONTENT '## State Deltas'

Assert-Contains 'closeout-format.test: closeout-format.md class enum includes state-delta' `
    $LF_CONTENT '`state-delta`'

# --- 4. obsidian/lesson-template.md ---
$OL_PATH = Join-Path $env:REPO_ROOT 'obsidian' 'lesson-template.md'
$OL_CONTENT = Get-Content -LiteralPath $OL_PATH -Raw

Assert-Contains 'closeout-format.test: lesson-template.md class enum includes state-delta' `
    $OL_CONTENT '`state-delta`'

# --- 5. session-agent owns the kickoff query order.
$CT_PATH = Join-Path $env:REPO_ROOT 'harnesses' 'claude' 'CLAUDE.template.md'
$AT_PATH = Join-Path $env:REPO_ROOT 'harnesses' 'codex' 'AGENTS.template.md'
$SA_PATH = Join-Path $env:REPO_ROOT 'capabilities' 'session-agent.md'
$CT_CONTENT = Get-Content -LiteralPath $CT_PATH -Raw
$AT_CONTENT = Get-Content -LiteralPath $AT_PATH -Raw
$SA_CONTENT = Get-Content -LiteralPath $SA_PATH -Raw

Assert-Contains 'closeout-format.test: session-agent.md owns the projects-first kickoff cut' `
    $SA_CONTENT 'projects-first'

Assert-Contains 'closeout-format.test: session-agent.md references linear/linear-setup.md for surface commands' `
    $SA_CONTENT 'linear/linear-setup.md'

Assert-Contains 'closeout-format.test: CLAUDE.template points at session-agent Mode 1 for kickoff' `
    $CT_CONTENT 'session-agent'

Assert-Contains 'closeout-format.test: AGENTS.template points at session-agent Mode 1 for kickoff' `
    $AT_CONTENT 'session-agent'

Assert-Contains 'closeout-format.test: CLAUDE.template references state-delta closeout rule' `
    $CT_CONTENT 'state-delta'

Assert-Contains 'closeout-format.test: AGENTS.template references state-delta closeout rule' `
    $AT_CONTENT 'state-delta'

# --- 6. core/memory-model.md ---
$MM_PATH = Join-Path $env:REPO_ROOT 'core' 'memory-model.md'
$MM_CONTENT = Get-Content -LiteralPath $MM_PATH -Raw

Assert-Contains 'closeout-format.test: memory-model.md has the Per-Harness Memory Index section' `
    $MM_CONTENT 'Per-Harness Memory Index'

Assert-Contains 'closeout-format.test: memory-model.md references state-delta as the write-side guarantee' `
    $MM_CONTENT 'state-delta'

# --- 7. every derivative carries the FULL 11-class set ---
$CO_PATH = Join-Path $env:REPO_ROOT 'core' 'closeout.md'
$CO_CONTENT = Get-Content -LiteralPath $CO_PATH -Raw

foreach ($class in @('data-readiness','goal-run')) {
    Assert-Contains "closeout-format.test: core/closeout.md lists $class" $CO_CONTENT "``$class``"
    Assert-Contains "closeout-format.test: linear/closeout-format.md lists $class" $LF_CONTENT "``$class``"
    Assert-Contains "closeout-format.test: obsidian/lesson-template.md lists $class" $OL_CONTENT "``$class``"
    Assert-Contains "closeout-format.test: capabilities/closeout.md lists $class" $CL_CONTENT "``$class``"
    Assert-Contains "closeout-format.test: self-improvement.md lists $class" $SI_CONTENT "``$class``"
}

# --- 8. output block adds ## Running State + ## Pick up here sections ---
Assert-Contains 'closeout-format.test: closeout.md output block requires ## Running State' `
    $CL_CONTENT '## Running State'
Assert-Contains 'closeout-format.test: closeout.md output block requires ## Pick up here' `
    $CL_CONTENT '## Pick up here'

# Position: State Deltas < Running State < Residual Risk.
$sd_line = Get-HeadingLine $CL_PATH '## State Deltas'
$rs_line = Get-HeadingLine $CL_PATH '## Running State'
$rr_line = Get-HeadingLine $CL_PATH '## Residual Risk'
if ($sd_line -gt 0 -and $rs_line -gt 0 -and $rr_line -gt 0 -and $sd_line -lt $rs_line -and $rs_line -lt $rr_line) {
    _Pass 'closeout-format.test: closeout.md places ## Running State between ## State Deltas and ## Residual Risk'
} else {
    _Fail 'closeout-format.test: closeout.md places ## Running State between ## State Deltas and ## Residual Risk' `
        "state-deltas:$sd_line running-state:$rs_line residual-risk:$rr_line"
}

# Position: Lessons < Pick up here.
$les_line = Get-HeadingLine $CL_PATH '## Lessons'
$pu_line  = Get-HeadingLine $CL_PATH '## Pick up here'
if ($les_line -gt 0 -and $pu_line -gt 0 -and $les_line -lt $pu_line) {
    _Pass 'closeout-format.test: closeout.md places ## Pick up here after ## Lessons'
} else {
    _Fail 'closeout-format.test: closeout.md places ## Pick up here after ## Lessons' `
        "lessons:$les_line pick-up-here:$pu_line"
}

# linear/closeout-format.md mirrors the shape.
Assert-Contains 'closeout-format.test: closeout-format.md adds ## Running State section' `
    $LF_CONTENT '## Running State'
Assert-Contains 'closeout-format.test: closeout-format.md adds ## Pick up here section' `
    $LF_CONTENT '## Pick up here'

# Stronger: ## Pick up here must be the LAST `##` heading inside the fenced
# output block in capabilities/closeout.md. Slices the file between the first
# two ```-only lines and checks the trailing heading.
$cl_lines = Get-Content -LiteralPath $CL_PATH
$fence_indices = @()
for ($i = 0; $i -lt $cl_lines.Length; $i++) {
    if ($cl_lines[$i] -ceq '```') {
        $fence_indices += $i
    }
}
if ($fence_indices.Count -ge 2 -and $fence_indices[0] -lt $fence_indices[1]) {
    $fence_start = $fence_indices[0]
    $fence_end = $fence_indices[1]
    $inner_headings = @()
    for ($i = $fence_start + 1; $i -lt $fence_end; $i++) {
        if ($cl_lines[$i] -cmatch '^## ') {
            $inner_headings += $cl_lines[$i]
        }
    }
    if ($inner_headings.Count -gt 0) {
        $last_inner = $inner_headings[-1]
    } else {
        $last_inner = ''
    }
    Assert-Eq 'closeout-format.test: closeout.md fenced output block ends with ## Pick up here' `
        '## Pick up here' $last_inner
} else {
    $startIdx = if ($fence_indices.Count -gt 0) { $fence_indices[0] } else { '' }
    $endIdx   = if ($fence_indices.Count -gt 1) { $fence_indices[1] } else { '' }
    _Fail 'closeout-format.test: closeout.md fenced output block ends with ## Pick up here' `
        ("could not locate fenced output block (start=$startIdx end=$endIdx)")
}

# linear/closeout-format.md ordering.
$lf_sd = Get-HeadingLine $LF_PATH '## State Deltas'
$lf_rs = Get-HeadingLine $LF_PATH '## Running State'
$lf_rr = Get-HeadingLine $LF_PATH '## Residual Risk'
if ($lf_sd -gt 0 -and $lf_rs -gt 0 -and $lf_rr -gt 0 -and $lf_sd -lt $lf_rs -and $lf_rs -lt $lf_rr) {
    _Pass 'closeout-format.test: closeout-format.md places ## Running State between ## State Deltas and ## Residual Risk'
} else {
    _Fail 'closeout-format.test: closeout-format.md places ## Running State between ## State Deltas and ## Residual Risk' `
        "state-deltas:$lf_sd running-state:$lf_rs residual-risk:$lf_rr"
}

# Pick up here is the last ## heading in linear/closeout-format.md.
$lf_lines = Get-Content -LiteralPath $LF_PATH
$lf_h2s = @($lf_lines | Where-Object { $_ -cmatch '^## ' })
if ($lf_h2s.Count -gt 0) {
    $lf_last_heading = $lf_h2s[-1]
} else {
    $lf_last_heading = ''
}
Assert-Eq 'closeout-format.test: closeout-format.md ## Pick up here is the last top-level section' `
    '## Pick up here' $lf_last_heading

# --- 9. "Boring is Beautiful" named principle in core/operating-system.md ---
$OS_PATH = Join-Path $env:REPO_ROOT 'core' 'operating-system.md'
$OS_CONTENT = Get-Content -LiteralPath $OS_PATH -Raw

Assert-Contains 'closeout-format.test: operating-system.md adds ## Boring is Beautiful heading' `
    $OS_CONTENT '## Boring is Beautiful'

# Position: ## Boring is Beautiful before ## Closeout Flow.
$bb_line = Get-HeadingLine $OS_PATH '## Boring is Beautiful'
$cf_line = Get-HeadingLine $OS_PATH '## Closeout Flow'
if ($bb_line -gt 0 -and $cf_line -gt 0 -and $bb_line -lt $cf_line) {
    _Pass 'closeout-format.test: operating-system.md places ## Boring is Beautiful before ## Closeout Flow'
} else {
    _Fail 'closeout-format.test: operating-system.md places ## Boring is Beautiful before ## Closeout Flow' `
        "boring-is-beautiful:$bb_line closeout-flow:$cf_line"
}

# Codex MT-4 amendment: scope the four canonical clauses to the section body.
$os_lines = Get-Content -LiteralPath $OS_PATH
if ($bb_line -gt 0 -and $cf_line -gt 0 -and $bb_line -lt $cf_line) {
    # Inclusive slice (bb_line+1) through (cf_line-1) — bash awk used 1-based;
    # PS arrays are 0-based, so subtract 1 from each bound for indexing.
    $bb_body_lines = $os_lines[$bb_line..($cf_line - 2)]
    $bb_body = $bb_body_lines -join "`n"
} else {
    $bb_body = ''
}

Assert-Contains "closeout-format.test: operating-system.md Boring section body names 'lowest autonomy'" `
    $bb_body 'lowest autonomy'
Assert-Contains "closeout-format.test: operating-system.md Boring section body says 'Workflows beat agents'" `
    $bb_body 'Workflows beat agents'
Assert-Contains 'closeout-format.test: operating-system.md Boring section body prefers deterministic over non-deterministic' `
    $bb_body 'deterministic over non-deterministic'
Assert-Contains "closeout-format.test: operating-system.md Boring section body says 'eliminate before automating'" `
    $bb_body 'eliminate before automating'

# --- 10. EAD ("Eliminate / Automate / Delegate") gate in closeout walk ---
Assert-Contains 'closeout-format.test: closeout.md walks EAD question — canonical text' `
    $CL_CONTENT 'should have eliminated'
Assert-Contains 'closeout-format.test: self-improvement.md walks EAD question — canonical text' `
    $SI_CONTENT 'should have eliminated'

# --- 11. Codex amendments (2026-05-25), count migration ---
Assert-NotContains 'closeout-format.test: closeout.md has no stale ''7 closeout questions'' substring anywhere' `
    $CL_CONTENT '7 closeout questions'

# MT-2: Q0 before the closeout walk's Q1 in both files.
$cl_lines_all = $cl_lines
$q0_cl = 0
$q1_cl = 0
for ($i = 0; $i -lt $cl_lines_all.Length; $i++) {
    if ($q0_cl -eq 0 -and $cl_lines_all[$i] -cmatch '^0\. \*\*EAD gate') { $q0_cl = $i + 1 }
    if ($q1_cl -eq 0 -and $cl_lines_all[$i] -cmatch '^1\. Did we learn anything') { $q1_cl = $i + 1 }
}
if ($q0_cl -gt 0 -and $q1_cl -gt 0 -and $q0_cl -lt $q1_cl) {
    _Pass 'closeout-format.test: closeout.md Q0 EAD gate appears before Q1 in the walk'
} else {
    _Fail 'closeout-format.test: closeout.md Q0 EAD gate appears before Q1 in the walk' "q0:$q0_cl q1:$q1_cl"
}

$si_lines_all = Get-Content -LiteralPath $SI_PATH
$q0_si = 0
$q1_si = 0
for ($i = 0; $i -lt $si_lines_all.Length; $i++) {
    if ($q0_si -eq 0 -and $si_lines_all[$i] -cmatch '^0\. \*\*EAD gate') { $q0_si = $i + 1 }
    if ($q1_si -eq 0 -and $si_lines_all[$i] -cmatch '^1\. Did we learn anything') { $q1_si = $i + 1 }
}
if ($q0_si -gt 0 -and $q1_si -gt 0 -and $q0_si -lt $q1_si) {
    _Pass 'closeout-format.test: self-improvement.md Q0 EAD gate appears before Q1 in the walk'
} else {
    _Fail 'closeout-format.test: self-improvement.md Q0 EAD gate appears before Q1 in the walk' "q0:$q0_si q1:$q1_si"
}

# MT-5: state-delta-remains-mandatory guard in both files.
Assert-Contains 'closeout-format.test: closeout.md Q0 preserves mandatory state-delta handling' `
    $CL_CONTENT 'remain mandatory regardless of Q0 outcome'
Assert-Contains 'closeout-format.test: self-improvement.md Q0 preserves mandatory state-delta handling' `
    $SI_CONTENT 'remain mandatory regardless of Q0 outcome'

# --- 12. Session-log drain — the always-on write-through capture.
# Mirror of tests/closeout-format.test.sh section 12.
Assert-Contains 'closeout-format.test: closeout.md has the Session-log drain section' `
    $CL_CONTENT '## Session-log drain'
Assert-Contains 'closeout-format.test: closeout.md drain names the Sessions archive path' `
    $CL_CONTENT '30-Archive/Sessions'
Assert-Contains 'closeout-format.test: closeout.md drain uses the agnostic vault path var' `
    $CL_CONTENT '$OBSIDIAN_VAULT_PATH'
Assert-Contains 'closeout-format.test: closeout.md drain stamps a closeout_id' `
    $CL_CONTENT 'closeout_id'
Assert-Contains 'closeout-format.test: closeout.md drain quarantines under Raw observations' `
    $CL_CONTENT 'Raw observations'
Assert-Contains 'closeout-format.test: closeout.md drain names provenance labelling' `
    $CL_CONTENT 'provenance'
Assert-Contains 'closeout-format.test: closeout.md drain runs the injection scan before writing' `
    $CL_CONTENT '--injection-scan'
Assert-Contains 'closeout-format.test: closeout.md drain requires write-verification (FLAG on miss)' `
    $CL_CONTENT 'FLAG'

# The drain section must sit OUTSIDE the fenced output block (after fence_end).
$dr_line = Get-HeadingLine $CL_PATH '## Session-log drain — write-through to the durable vault'
$dr_after = if ($dr_line -gt 0 -and $fence_end -and $dr_line -gt $fence_end) { 'yes' } else { "no(drain:$dr_line fence_end:$fence_end)" }
Assert-Eq 'closeout-format.test: closeout.md Session-log drain section is after the fenced output block' 'yes' $dr_after

# closeout-format.md ties the comment to a closeout_id.
Assert-Contains 'closeout-format.test: closeout-format.md ties the comment to a closeout_id' `
    $LF_CONTENT 'closeout_id'

# vault-guide.md §8: session log is the write-through exception; curated notes stay propose.
$VG_CONTENT = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'obsidian' 'vault-guide.md') -Raw
Assert-Contains 'closeout-format.test: vault-guide.md names the session-log write-through exception' `
    $VG_CONTENT 'write-through'
Assert-Contains 'closeout-format.test: vault-guide.md keeps curated notes propose-don''t-write' `
    $VG_CONTENT 'propose-don''t-write'

# core/self-improvement.md notes the always-on drain alongside the lesson classes.
Assert-Contains 'closeout-format.test: self-improvement.md notes the always-on session-log drain' `
    $SI_CONTENT 'session log'
