#Requires -Version 7
# tests/closeout-file-sweep.test.ps1 — Windows-native twin of
# tests/closeout-file-sweep.test.sh.
#
# invariants for the closeout file-sweep step + ## Files created this
# session output section. Mirrors the bash twin 1:1; per [[reference_ps_port_traps]]
# trap #8 the PS twin is the pair-test that catches numeric/string-constant
# drift between the bash hook + PS twin.
#
# Pure content-only; no script invocation.

# Helper: line number of an exact heading match, or 0 if missing.
function Get-HeadingLine {
    param([string]$Path, [string]$Heading)
    $lines = Get-Content -LiteralPath $Path
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -ceq $Heading) { return $i + 1 }
    }
    return 0
}

$CL_PATH = Join-Path $env:REPO_ROOT 'capabilities' 'closeout.md'
$SI_PATH = Join-Path $env:REPO_ROOT 'core' 'self-improvement.md'
$LF_PATH = Join-Path $env:REPO_ROOT 'linear' 'closeout-format.md'

Assert-File 'closeout-file-sweep.test: capabilities/closeout.md exists' $CL_PATH
Assert-File 'closeout-file-sweep.test: core/self-improvement.md exists' $SI_PATH
Assert-File 'closeout-file-sweep.test: linear/closeout-format.md exists' $LF_PATH

$CL_CONTENT = Get-Content -LiteralPath $CL_PATH -Raw
$SI_CONTENT = Get-Content -LiteralPath $SI_PATH -Raw
$LF_CONTENT = Get-Content -LiteralPath $LF_PATH -Raw

# --- 1. capabilities/closeout.md — Q7 walk + frontmatter + summary count ----
Assert-Contains 'closeout-file-sweep.test: closeout.md walk header says 8 closeout questions' `
    $CL_CONTENT 'The 8 closeout questions'
Assert-Contains 'closeout-file-sweep.test: closeout.md frontmatter summary says 8 closeout questions' `
    $CL_CONTENT 'walk the 8 closeout questions'

Assert-NotContains "closeout-file-sweep.test: closeout.md has no stale '7 closeout questions' substring" `
    $CL_CONTENT '7 closeout questions'

Assert-Contains 'closeout-file-sweep.test: closeout.md walks Q7 File sweep' `
    $CL_CONTENT 'File sweep'
Assert-Contains 'closeout-file-sweep.test: closeout.md Q7 enumerates create-side surfaces' `
    $CL_CONTENT '`Write` / `Edit`'
Assert-Contains 'closeout-file-sweep.test: closeout.md Q7 forbids default-keep' `
    $CL_CONTENT 'Default-keep is forbidden'

Assert-Contains 'closeout-file-sweep.test: closeout.md Q7 lists keep-because-X classification' `
    $CL_CONTENT 'keep-because-'
Assert-Contains 'closeout-file-sweep.test: closeout.md Q7 lists clean-now classification' `
    $CL_CONTENT 'clean-now'
Assert-Contains 'closeout-file-sweep.test: closeout.md Q7 lists clean-by-Y classification' `
    $CL_CONTENT 'clean-by-'

# --- 2. capabilities/closeout.md — new ## Files created this session section -
Assert-Contains 'closeout-file-sweep.test: closeout.md output block adds ## Files created this session' `
    $CL_CONTENT '## Files created this session'

$sd_line = Get-HeadingLine $CL_PATH '## State Deltas'
$fc_line = Get-HeadingLine $CL_PATH '## Files created this session'
$rs_line = Get-HeadingLine $CL_PATH '## Running State'
if ($sd_line -gt 0 -and $fc_line -gt 0 -and $rs_line -gt 0 -and $sd_line -lt $fc_line -and $fc_line -lt $rs_line) {
    _Pass 'closeout-file-sweep.test: closeout.md places ## Files created this session between ## State Deltas and ## Running State'
} else {
    _Fail 'closeout-file-sweep.test: closeout.md places ## Files created this session between ## State Deltas and ## Running State' `
        "state-deltas:$sd_line files-created:$fc_line running-state:$rs_line"
}

# Q7 position: anchor on the actual leading "7. " (with canonical signal phrase)
# and on Q6's text to find the walk-list specifically.
$cl_lines = Get-Content -LiteralPath $CL_PATH
$q6_cl = 0
$q7_cl = 0
for ($i = 0; $i -lt $cl_lines.Length; $i++) {
    if ($q6_cl -eq 0 -and $cl_lines[$i] -cmatch '^6\. Did the work reveal a missing data path') { $q6_cl = $i + 1 }
    if ($q7_cl -eq 0 -and $cl_lines[$i] -cmatch '^7\. \*\*File sweep') { $q7_cl = $i + 1 }
}
if ($q6_cl -gt 0 -and $q7_cl -gt 0 -and $q6_cl -lt $q7_cl) {
    _Pass 'closeout-file-sweep.test: closeout.md Q7 File sweep appears after Q6 in the walk'
} else {
    _Fail 'closeout-file-sweep.test: closeout.md Q7 File sweep appears after Q6 in the walk' `
        "q6:$q6_cl q7:$q7_cl"
}

# --- 3. core/self-improvement.md — Q7 mirror in the canonical walk ----------
Assert-Contains 'closeout-file-sweep.test: self-improvement.md walks Q7 File sweep' `
    $SI_CONTENT 'File sweep'
Assert-Contains 'closeout-file-sweep.test: self-improvement.md Q7 forbids default-keep' `
    $SI_CONTENT 'Default-keep is forbidden'

# Codex MT-2 amendment: lockstep parity on the 3 Q7 classification tokens.
Assert-Contains 'closeout-file-sweep.test: self-improvement.md Q7 lists keep-because-X classification' `
    $SI_CONTENT 'keep-because-'
Assert-Contains 'closeout-file-sweep.test: self-improvement.md Q7 lists clean-now classification' `
    $SI_CONTENT 'clean-now'
Assert-Contains 'closeout-file-sweep.test: self-improvement.md Q7 lists clean-by-Y classification' `
    $SI_CONTENT 'clean-by-'

# Codex MT-2 amendment: Q0's fast-path must preserve Q7's file sweep.
Assert-Contains 'closeout-file-sweep.test: closeout.md Q0 preserves mandatory Q7 file sweep' `
    $CL_CONTENT 'Q7 file sweep below ALSO remains mandatory'
Assert-Contains 'closeout-file-sweep.test: self-improvement.md Q0 preserves mandatory Q7 file sweep' `
    $SI_CONTENT 'Q7 file sweep below ALSO remains mandatory'

# Q7 position in self-improvement.md.
$si_lines = Get-Content -LiteralPath $SI_PATH
$q6_si = 0
$q7_si = 0
for ($i = 0; $i -lt $si_lines.Length; $i++) {
    if ($q6_si -eq 0 -and $si_lines[$i] -cmatch '^6\. Did the work reveal a missing') { $q6_si = $i + 1 }
    if ($q7_si -eq 0 -and $si_lines[$i] -cmatch '^7\. \*\*File sweep') { $q7_si = $i + 1 }
}
if ($q6_si -gt 0 -and $q7_si -gt 0 -and $q6_si -lt $q7_si) {
    _Pass 'closeout-file-sweep.test: self-improvement.md Q7 File sweep appears after Q6 in the walk'
} else {
    _Fail 'closeout-file-sweep.test: self-improvement.md Q7 File sweep appears after Q6 in the walk' `
        "q6:$q6_si q7:$q7_si"
}

# --- 4. linear/closeout-format.md — mirror the new section -------------------
Assert-Contains 'closeout-file-sweep.test: closeout-format.md adds ## Files created this session' `
    $LF_CONTENT '## Files created this session'

$lf_sd = Get-HeadingLine $LF_PATH '## State Deltas'
$lf_fc = Get-HeadingLine $LF_PATH '## Files created this session'
$lf_rs = Get-HeadingLine $LF_PATH '## Running State'
if ($lf_sd -gt 0 -and $lf_fc -gt 0 -and $lf_rs -gt 0 -and $lf_sd -lt $lf_fc -and $lf_fc -lt $lf_rs) {
    _Pass 'closeout-file-sweep.test: closeout-format.md places ## Files created this session between ## State Deltas and ## Running State'
} else {
    _Fail 'closeout-file-sweep.test: closeout-format.md places ## Files created this session between ## State Deltas and ## Running State' `
        "state-deltas:$lf_sd files-created:$lf_fc running-state:$lf_rs"
}

# --- 6. Q7a — operator-main git-state cleanliness verification ------
#
# Windows-native twin of the bash twin's block. Mirrors 1:1 per
# [[reference_ps_port_traps]] trap #8 (count-string + content-constant drift
# between bash + PS surfaces).
#
# Lockstep contract:
# - capabilities/closeout.md carries Q7a walk body + 3 check commands
# - core/self-improvement.md mirrors Q7a + 3 check commands
# - linear/closeout-format.md shows verified-clean shape in ## State Deltas
#
# Scoping (Codex F-1 + F-2): body-scoped slices instead of file-scope
# substring checks. See bash twin lines ~250-330 for the rationale +
# the MT-2 EAD position-guard precedent.

# Helper: slice a file's lines (1-indexed, inclusive) and return as a joined string.
function Get-LinesSlice {
    param([string]$Path, [int]$Start, [int]$End)
    if ($Start -lt 1 -or $End -lt $Start) { return '' }
    $lines = Get-Content -LiteralPath $Path
    if ($End -gt $lines.Length) { $End = $lines.Length }
    return ($lines[($Start - 1)..($End - 1)] -join "`n")
}

# Helper: return 1-indexed line number of first regex match, or 0 if missing.
function Get-LineMatch {
    param([string]$Path, [string]$Pattern)
    $lines = Get-Content -LiteralPath $Path
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -cmatch $Pattern) { return $i + 1 }
    }
    return 0
}

# 6.1 — capabilities/closeout.md Q7a presence + signal phrase.
Assert-Contains 'closeout-file-sweep.test: closeout.md walks Q7a operator-main git-state cleanliness' `
    $CL_CONTENT 'Q7a'
Assert-Contains 'closeout-file-sweep.test: closeout.md Q7a names operator-main git-state cleanliness' `
    $CL_CONTENT 'operator-main git-state cleanliness'

# 6.2 — capabilities/closeout.md Q7a walk body MUST carry all three check
# commands. Slice file between the Q7a anchor and "If every answer is..."
# paragraph (walk-end marker). Codex F-1: prevents future edits that drop
# the Q7a walk body while leaving the three command strings in unrelated
# State Deltas / Q0 prose from false-PASSing the gate.
$q7a_cl = Get-LineMatch $CL_PATH '\*\*Q7a — operator-main git-state cleanliness'
$walk_end_cl = Get-LineMatch $CL_PATH '^If every answer is "no"'
if ($q7a_cl -gt 0 -and $walk_end_cl -gt 0 -and $q7a_cl -lt $walk_end_cl) {
    $q7a_body_cl = Get-LinesSlice $CL_PATH $q7a_cl ($walk_end_cl - 1)
} else {
    $q7a_body_cl = ''
}
Assert-Contains 'closeout-file-sweep.test: closeout.md Q7a walk body names git status --porcelain check' `
    $q7a_body_cl 'git status --porcelain'
Assert-Contains 'closeout-file-sweep.test: closeout.md Q7a walk body names git diff --cached --quiet check' `
    $q7a_body_cl 'git diff --cached --quiet'
Assert-Contains 'closeout-file-sweep.test: closeout.md Q7a walk body names git diff --quiet check' `
    $q7a_body_cl 'git diff --quiet'

# 6.3 — capabilities/closeout.md Q7a forbids silent clean claims (body-scoped).
Assert-Contains 'closeout-file-sweep.test: closeout.md Q7a forbids silent clean claims' `
    $q7a_body_cl 'Silent claims of `clean` are forbidden'

# 6.4 — core/self-improvement.md mirrors Q7a (file-scope OK for presence).
Assert-Contains 'closeout-file-sweep.test: self-improvement.md mirrors Q7a sub-step' `
    $SI_CONTENT 'Q7a'
Assert-Contains 'closeout-file-sweep.test: self-improvement.md mirrors Q7a operator-main git-state cleanliness' `
    $SI_CONTENT 'operator-main git-state cleanliness'

# 6.5 — core/self-improvement.md Q7a walk body MUST carry all three check
# commands (body-scoped; mirror of 6.2). Walk-end marker in this file is
# the "If the answer is no" parenthetical that closes Q7's numbered item.
$q7a_si = Get-LineMatch $SI_PATH '\*\*Q7a — operator-main git-state cleanliness'
$walk_end_si = Get-LineMatch $SI_PATH '^If the answer is no'
if ($q7a_si -gt 0 -and $walk_end_si -gt 0 -and $q7a_si -lt $walk_end_si) {
    $q7a_body_si = Get-LinesSlice $SI_PATH $q7a_si ($walk_end_si - 1)
} else {
    $q7a_body_si = ''
}
Assert-Contains 'closeout-file-sweep.test: self-improvement.md Q7a walk body names git status --porcelain check' `
    $q7a_body_si 'git status --porcelain'
Assert-Contains 'closeout-file-sweep.test: self-improvement.md Q7a walk body names git diff --cached --quiet check' `
    $q7a_body_si 'git diff --cached --quiet'
Assert-Contains 'closeout-file-sweep.test: self-improvement.md Q7a walk body names git diff --quiet check' `
    $q7a_body_si 'git diff --quiet'

# 6.6 — Q0 fast-path body-scoped preservation of Q7a verification (Codex F-2).
# Mirrors MT-2 EAD-position-guard slice pattern (closeout-format.test
# lines ~285-301): anchor Q0 between '^0\. \*\*EAD gate' and '^1\. Did we
# learn anything', assert Q7a-verification clause lands inside that body.
$q0_cl_line = Get-LineMatch $CL_PATH '^0\. \*\*EAD gate'
$q1_cl_line = Get-LineMatch $CL_PATH '^1\. Did we learn anything'
if ($q0_cl_line -gt 0 -and $q1_cl_line -gt 0 -and $q0_cl_line -lt $q1_cl_line) {
    $q0_body_cl = Get-LinesSlice $CL_PATH $q0_cl_line ($q1_cl_line - 1)
} else {
    $q0_body_cl = ''
}
Assert-Contains 'closeout-file-sweep.test: closeout.md Q0 body preserves mandatory Q7a verification' `
    $q0_body_cl 'Q7a verification'

$q0_si_line = Get-LineMatch $SI_PATH '^0\. \*\*EAD gate'
$q1_si_line = Get-LineMatch $SI_PATH '^1\. Did we learn anything'
if ($q0_si_line -gt 0 -and $q1_si_line -gt 0 -and $q0_si_line -lt $q1_si_line) {
    $q0_body_si = Get-LinesSlice $SI_PATH $q0_si_line ($q1_si_line - 1)
} else {
    $q0_body_si = ''
}
Assert-Contains 'closeout-file-sweep.test: self-improvement.md Q0 body preserves mandatory Q7a verification' `
    $q0_body_si 'Q7a verification'

# 6.7 — linear/closeout-format.md ## State Deltas section shows the
# verified-clean + dirty-state shapes.
Assert-Contains 'closeout-file-sweep.test: closeout-format.md State Deltas example shows verified-clean shape' `
    $LF_CONTENT 'verified: git status --porcelain empty'
Assert-Contains 'closeout-file-sweep.test: closeout-format.md State Deltas example shows dirty-state shape' `
    $LF_CONTENT 'operator-main: 1 staged file'

# 6.8 — Codex F-3 amendment: capabilities/closeout.md post-walk parenthetical
# mirrors the "Q7a never short-circuits either" wording present in
# core/self-improvement.md. Lockstep parity, same shape as MT-2.
Assert-Contains 'closeout-file-sweep.test: closeout.md post-walk note mirrors Q7a never-short-circuit clause' `
    $CL_CONTENT 'Q7a never short-circuits either'
Assert-Contains 'closeout-file-sweep.test: self-improvement.md post-walk note mirrors Q7a never-short-circuit clause' `
    $SI_CONTENT 'Q7a never short-circuits either'
