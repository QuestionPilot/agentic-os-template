#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/project-note-budget.test.ps1 — Windows-native twin of
# tests/project-note-budget.test.sh.
#
# Behavioral tests for scripts/check-project-note-budget.ps1, the fourth check in
# the closeout pre-write gate. It fails CLOSED on a `type: project` memory note
# whose file size exceeds the per-note budget. Three properties carry the weight,
# each pinned both ways (a positive that fires AND a negative that must not):
#
#   TYPE-GATED     only frontmatter `type: project` is in scope — an equally
#                  oversize reference note, and a `node_type:` near-miss, must
#                  pass.
#   SURFACE        no -MemoryDir at all is a named SKIP (exit 0); a given dir that
#                  does not exist is a FAILURE.
#   DENOMINATOR    every run says how many notes it measured.
#
# Mirrors the .sh twin 1:1 — same fixtures, same assertions.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$PNB_SCRIPT = Join-Path $env:REPO_ROOT 'scripts' 'check-project-note-budget.ps1'
Assert-File 'pnb.test: scripts/check-project-note-budget.ps1 exists' $PNB_SCRIPT

function Write-PnbFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# New-PnbNote <path> <type-line> <pad-bytes> — a memory note with the given
# frontmatter type line, padded to roughly <pad-bytes>.
function New-PnbNote {
    param([string]$Path, [string]$TypeLine, [int]$Pad)
    Write-PnbFile $Path ("---`nmetadata:`n  $TypeLine`n---`n" + ('x' * $Pad) + "`n")
}

# New-PnbRawNote <path> <frontmatter> <pad-bytes> — a note whose WHOLE
# frontmatter block (fences included) is given verbatim, for the nesting cases
# New-PnbNote's fixed `metadata:` shape cannot express.
function New-PnbRawNote {
    param([string]$Path, [string]$Frontmatter, [int]$Pad)
    Write-PnbFile $Path ($Frontmatter + ('x' * $Pad) + "`n")
}

# New-PnbExactNote <path> <total-bytes> — a `type: project` note whose FILE SIZE
# is exactly <total-bytes>, frontmatter included. The budget compares file size,
# so an off-by-a-few fixture cannot test a boundary at all. The header is ASCII
# with LF newlines, so its character count IS its byte count.
function New-PnbExactNote {
    param([string]$Path, [int]$Total)
    $hdr = "---`nmetadata:`n  type: project`n---`n"
    Write-PnbFile $Path ($hdr + ('x' * ($Total - $hdr.Length)))
}

# Run the check and capture stdout+stderr as one string plus the exit code.
function Invoke-Pnb {
    param([string[]]$Argv)
    $out = (& pwsh -NoProfile -File $PNB_SCRIPT @Argv 2>&1 | Out-String)
    return [pscustomobject]@{ Out = $out; Rc = $LASTEXITCODE }
}

$PNB_TMP = Join-Path ([IO.Path]::GetTempPath()) ('pnb-test-' + [Guid]::NewGuid().Guid.Substring(0, 8))
New-Item -ItemType Directory -Path $PNB_TMP -Force | Out-Null

# The twin runs INSIDE the living repo, where a real local.env may carry
# PROJECT_NOTE_BODY_WARN_KB. Every case that asserts a cap therefore pins
# $env:AI_CONFIG_LOCAL_ENV at a fixture (or at a path that does not exist, the
# no-key shape) so the operator's own knob can never decide the verdict.
$PNB_NOENV = Join-Path $PNB_TMP 'no-such-local.env'
$pnbSavedLocalEnv = [Environment]::GetEnvironmentVariable('AI_CONFIG_LOCAL_ENV')
$pnbSavedCap = [Environment]::GetEnvironmentVariable('PROJECT_NOTE_BODY_WARN_KB')
$env:AI_CONFIG_LOCAL_ENV = $PNB_NOENV
Remove-Item Env:PROJECT_NOTE_BODY_WARN_KB -ErrorAction SilentlyContinue

try {

# === 1. No -MemoryDir at all → a NAMED skip with the denominator, exit 0.
$pnbNone = Invoke-Pnb @()
Assert-Eq 'pnb.test: no --memory-dir exits 0 (inapplicable surface, not a failure)' 0 $pnbNone.Rc
Assert-Contains 'pnb.test: the absent surface is a NAMED skip' $pnbNone.Out 'SKIP no --memory-dir given'
Assert-Contains 'pnb.test: the skip still prints its denominator' `
    $pnbNone.Out 'scanned 0 project note(s) in 0 dir(s)'

# === 2. A store whose project notes are all within budget → PASS with the count.
$PNB_OK = Join-Path $PNB_TMP 'store-ok'
New-PnbNote (Join-Path $PNB_OK 'arc-one.md') 'type: project' 512
New-PnbNote (Join-Path $PNB_OK 'arc-two.md') 'type: project' 1024
Write-PnbFile (Join-Path $PNB_OK 'MEMORY.md') "- [Arc one](arc-one.md)`n"
$pnbOk = Invoke-Pnb @('--memory-dir', $PNB_OK)
Assert-Eq 'pnb.test: a within-budget store exits 0' 0 $pnbOk.Rc
Assert-Contains 'pnb.test: the clean verdict names the budget' `
    $pnbOk.Out 'PASS every project-type note is within the 16 KB budget'
Assert-Contains 'pnb.test: the denominator counts the project notes it measured' `
    $pnbOk.Out 'scanned 2 project note(s) in 1 dir(s) against a 16 KB budget'

# === 3. An over-budget project note fails closed, naming the file and the size.
$PNB_BIG = Join-Path $PNB_TMP 'store-over'
$PNB_BIG_NOTE = Join-Path $PNB_BIG 'oversize.md'
New-PnbNote $PNB_BIG_NOTE 'type: project' 17408
$pnbBig = Invoke-Pnb @('--memory-dir', $PNB_BIG)
Assert-Eq 'pnb.test: an over-budget project note exits 1 (fail closed)' 1 $pnbBig.Rc
Assert-Contains 'pnb.test: the offending note is named by full path' `
    $pnbBig.Out "FAIL project note over budget: $PNB_BIG_NOTE"
Assert-Contains 'pnb.test: the finding states the measured size against the cap' $pnbBig.Out 'B > 16 KB)'
Assert-Contains 'pnb.test: the finding points at the remediation rule' `
    $pnbBig.Out 'trim per capabilities/closeout.md memory-hygiene rule 4'
Assert-Contains 'pnb.test: the verdict separates over-budget notes from missing dirs' `
    $pnbBig.Out 'FAIL 1 note(s) over the 16 KB budget, 0 memory dir(s) unusable, 0 note(s) unreadable'

# === 3b. The EXACT boundary. The comparison is `size > cap`, so a note of
# exactly 16*1024 bytes is within budget and one byte more is not. An off-by-one
# here would either nag every note that merely reaches the cap or wave through
# the first note that breaches it, and no order-of-magnitude fixture can tell.
$PNB_EDGE_AT = Join-Path $PNB_TMP 'store-edge-at'
$PNB_EDGE_OVER = Join-Path $PNB_TMP 'store-edge-over'
$PNB_AT_NOTE = Join-Path $PNB_EDGE_AT 'exactly-16k.md'
$PNB_OVER_NOTE = Join-Path $PNB_EDGE_OVER 'one-byte-over.md'
New-PnbExactNote $PNB_AT_NOTE 16384
New-PnbExactNote $PNB_OVER_NOTE 16385
# The fixtures must really be those sizes — a mis-built fixture would make both
# assertions below vacuous.
Assert-Eq 'pnb.test: the at-cap fixture is exactly 16384 bytes' 16384 (Get-Item -LiteralPath $PNB_AT_NOTE).Length
Assert-Eq 'pnb.test: the over-cap fixture is exactly 16385 bytes' 16385 (Get-Item -LiteralPath $PNB_OVER_NOTE).Length
$pnbAt = Invoke-Pnb @('--memory-dir', $PNB_EDGE_AT)
Assert-Eq 'pnb.test: a note of exactly 16*1024 bytes is WITHIN budget' 0 $pnbAt.Rc
Assert-Contains 'pnb.test: the at-cap note was really measured (denominator is 1)' `
    $pnbAt.Out 'scanned 1 project note(s) in 1 dir(s)'
$pnbOver1 = Invoke-Pnb @('--memory-dir', $PNB_EDGE_OVER)
Assert-Eq 'pnb.test: one byte over the cap FAILS' 1 $pnbOver1.Rc
Assert-Contains 'pnb.test: the one-byte-over finding reports the exact size' `
    $pnbOver1.Out '(16385 B > 16 KB)'

# === 4. TYPE-GATED, both negatives. An equally oversize `type: reference` note is
# out of scope, and `node_type: project` is a near-miss the detector must NOT
# claim — the anchored `type:` match is what keeps this from becoming a blanket
# note-size cap.
$PNB_TYPE = Join-Path $PNB_TMP 'store-types'
New-PnbNote (Join-Path $PNB_TYPE 'big-reference.md') 'type: reference' 17408
New-PnbNote (Join-Path $PNB_TYPE 'big-nodetype.md') 'node_type: project' 17408
$pnbType = Invoke-Pnb @('--memory-dir', $PNB_TYPE)
Assert-Eq 'pnb.test: oversize non-project notes pass (type-gated)' 0 $pnbType.Rc
Assert-Contains 'pnb.test: neither near-miss note is counted in the denominator' `
    $pnbType.Out 'scanned 0 project note(s) in 1 dir(s)'
Assert-NotContains 'pnb.test: an oversize reference note is never reported' $pnbType.Out 'big-reference.md'
Assert-NotContains 'pnb.test: a node_type: near-miss is never reported' $pnbType.Out 'big-nodetype.md'

# === 4b. WHICH `type:` wins — the nesting rule. A frontmatter block can carry
# several `type:` keys under different parents, so "the first `type:` at any
# indent" reads the wrong one: a note whose `source:` provenance block names
# `type: project` above its real `metadata: type: reference` was classified
# project. `Type: project` is the case negative — the bash twin's awk is
# case-sensitive, so the PS regexes must be (-cmatch / -creplace) or the two
# shells classify different notes. Negatives first, each oversize so a
# mis-classification cannot hide.
$PNB_NEST_NO = Join-Path $PNB_TMP 'store-nesting-negative'
New-PnbRawNote (Join-Path $PNB_NEST_NO 'source-nested.md') "---`nsource:`n  type: project`nmetadata:`n  type: reference`n---`n" 17408
New-PnbRawNote (Join-Path $PNB_NEST_NO 'source-only.md') "---`nsource:`n  type: project`n---`n" 17408
New-PnbRawNote (Join-Path $PNB_NEST_NO 'capital-type.md') "---`nmetadata:`n  Type: project`n---`n" 17408
New-PnbRawNote (Join-Path $PNB_NEST_NO 'body-mention.md') "---`nmetadata:`n  type: reference`n---`ntype: project`n" 17408
# An UNCLOSED opening fence is not frontmatter at all — the whole file is body,
# so a body line `type: project` must not classify it. Without the closed-block
# guard the walker fell off the end of the file still holding the body's value.
New-PnbRawNote (Join-Path $PNB_NEST_NO 'unclosed.md') "---`ntitle: an arc`ntype: project`n" 17408
# A `type:` DEEPER than metadata's own first indent level belongs to a sub-key,
# not to the note. Here `metadata: source: type: project` sits under `source:`
# while the note's real direct child says reference.
New-PnbRawNote (Join-Path $PNB_NEST_NO 'deep-nested.md') "---`nmetadata:`n  source:`n    type: project`n  type: reference`n---`n" 17408
# Same sub-key `type:`, but with NO direct child at all — the note simply has no
# type, and must not inherit its provenance block's.
New-PnbRawNote (Join-Path $PNB_NEST_NO 'deep-only.md') "---`nmetadata:`n  source:`n    type: project`n---`n" 17408
$pnbNestNo = Invoke-Pnb @('--memory-dir', $PNB_NEST_NO)
Assert-Eq 'pnb.test: none of the seven near-miss shapes classify as project' 0 $pnbNestNo.Rc
Assert-Contains 'pnb.test: the near-miss store measures ZERO project notes' `
    $pnbNestNo.Out 'scanned 0 project note(s) in 1 dir(s)'
foreach ($miss in @('source-nested.md', 'source-only.md', 'capital-type.md', 'body-mention.md',
                    'unclosed.md', 'deep-nested.md', 'deep-only.md')) {
    Assert-NotContains "pnb.test: '$miss' is never reported" $pnbNestNo.Out $miss
}

# The POSITIVES, so the negatives above cannot pass by the detector simply having
# stopped working: `metadata.type` wins, and a TOP-LEVEL `type:` counts when
# there is no metadata block at all.
$PNB_NEST_YES = Join-Path $PNB_TMP 'store-nesting-positive'
$PNB_NEST_META = Join-Path $PNB_NEST_YES 'metadata-type.md'
$PNB_NEST_TOP = Join-Path $PNB_NEST_YES 'toplevel-type.md'
New-PnbRawNote $PNB_NEST_META "---`nsource:`n  type: reference`nmetadata:`n  type: project`n---`n" 17408
New-PnbRawNote $PNB_NEST_TOP "---`ntype: project`ntitle: an arc`n---`n" 17408
# The non-vacuity control for the direct-child rule: metadata carries BOTH a
# sub-key `type:` and a direct one. A fix that simply ignored everything under
# `metadata:` would satisfy every negative above and still fail here.
$PNB_NEST_BOTH = Join-Path $PNB_NEST_YES 'deep-plus-direct.md'
New-PnbRawNote $PNB_NEST_BOTH "---`nmetadata:`n  source:`n    type: reference`n  type: project`n---`n" 17408
$pnbNestYes = Invoke-Pnb @('--memory-dir', $PNB_NEST_YES)
Assert-Eq 'pnb.test: metadata.type and a top-level type: both classify as project' 1 $pnbNestYes.Rc
Assert-Contains 'pnb.test: all three positive shapes are measured' `
    $pnbNestYes.Out 'scanned 3 project note(s) in 1 dir(s)'
Assert-Contains 'pnb.test: metadata.type wins over a source-nested type' $pnbNestYes.Out $PNB_NEST_META
Assert-Contains 'pnb.test: a top-level type: with no metadata block counts' $pnbNestYes.Out $PNB_NEST_TOP
Assert-Contains 'pnb.test: a DIRECT metadata child still counts beside a deeper sub-key type' `
    $pnbNestYes.Out $PNB_NEST_BOTH

# === 5. A QUOTED type value still classifies as a project note — the store writes
# `type: "project"` as often as the bare form, and a detector that misses the
# quoted spelling silently exempts half the notes it exists to measure.
$PNB_QUOTED = Join-Path $PNB_TMP 'store-quoted'
$PNB_QUOTED_NOTE = Join-Path $PNB_QUOTED 'quoted.md'
New-PnbNote $PNB_QUOTED_NOTE 'type: "project"' 17408
$pnbQuoted = Invoke-Pnb @('--memory-dir', $PNB_QUOTED)
Assert-Eq 'pnb.test: a quoted type: "project" note is in scope' 1 $pnbQuoted.Rc
Assert-Contains 'pnb.test: the quoted-type note is the reported offender' $pnbQuoted.Out $PNB_QUOTED_NOTE

# === 5b. An INLINE YAML COMMENT on the type value. `type: project # active arc`
# is ordinary YAML and ordinary operator practice, and the old value extractor
# handed back `project # active arc` — so the note the comment describes as an
# active arc was the one note the budget never measured. Quoted and bare
# spellings both, plus the negative that a `#` with no space before it (or one
# inside the quotes) is part of the value, not a comment.
$PNB_CMT = Join-Path $PNB_TMP 'store-comments'
New-PnbRawNote (Join-Path $PNB_CMT 'bare-comment.md') "---`nmetadata:`n  type: project # active arc`n---`n" 17408
New-PnbRawNote (Join-Path $PNB_CMT 'quoted-comment.md') "---`nmetadata:`n  type: `"project`"   # active arc`n---`n" 17408
New-PnbRawNote (Join-Path $PNB_CMT 'toplevel-comment.md') "---`ntype: project  # top-level, commented`n---`n" 17408
$pnbCmt = Invoke-Pnb @('--memory-dir', $PNB_CMT)
Assert-Eq 'pnb.test: a commented type value still classifies as project' 1 $pnbCmt.Rc
Assert-Contains 'pnb.test: all three commented spellings are measured' `
    $pnbCmt.Out 'scanned 3 project note(s) in 1 dir(s)'

# The negatives: a `#` that is NOT a comment must stay in the value, so these
# notes are NOT project notes. Without them the fix could be "strip everything
# from the first #", which silently rewrites legitimate values.
$PNB_CMT_NEG = Join-Path $PNB_TMP 'store-comments-negative'
New-PnbRawNote (Join-Path $PNB_CMT_NEG 'hash-in-quotes.md') "---`nmetadata:`n  type: `"project #1`"`n---`n" 17408
New-PnbRawNote (Join-Path $PNB_CMT_NEG 'hash-no-space.md') "---`nmetadata:`n  type: project#1`n---`n" 17408
New-PnbRawNote (Join-Path $PNB_CMT_NEG 'reference-comment.md') "---`nmetadata:`n  type: reference # still an arc`n---`n" 17408
$pnbCmtNeg = Invoke-Pnb @('--memory-dir', $PNB_CMT_NEG)
Assert-Eq 'pnb.test: a non-comment # stays in the value (none of these are project)' 0 $pnbCmtNeg.Rc
Assert-Contains 'pnb.test: the non-comment store measures ZERO project notes' `
    $pnbCmtNeg.Out 'scanned 0 project note(s) in 1 dir(s)'

# === 6. MEMORY.md is the INDEX, never a note — excluded even when it carries
# project frontmatter and is oversize.
$PNB_IDX = Join-Path $PNB_TMP 'store-index'
New-PnbNote (Join-Path $PNB_IDX 'MEMORY.md') 'type: project' 17408
$pnbIdx = Invoke-Pnb @('--memory-dir', $PNB_IDX)
Assert-Eq 'pnb.test: an oversize MEMORY.md is not a project note' 0 $pnbIdx.Rc
Assert-Contains 'pnb.test: MEMORY.md is excluded from the denominator' `
    $pnbIdx.Out 'scanned 0 project note(s) in 1 dir(s)'

# === 7. A given memory dir that does not exist is a FAILURE, not a skip.
$PNB_GHOST = Join-Path $PNB_TMP 'no-such-store'
$pnbGhost = Invoke-Pnb @('--memory-dir', $PNB_GHOST)
Assert-Eq 'pnb.test: a nonexistent --memory-dir exits 1 (configured but broken)' 1 $pnbGhost.Rc
Assert-Contains 'pnb.test: the missing store is named' $pnbGhost.Out "FAIL memory dir not found: $PNB_GHOST"
Assert-NotContains 'pnb.test: a missing given store is never reported as a skip' $pnbGhost.Out 'SKIP'

# === 7b. A store that EXISTS but cannot be ENUMERATED must FAIL — the run
# reported `scanned 0` and PASSed over a store it never opened, a clean verdict
# from a measurement that never happened. Same for a note that cannot be read: it
# classifies as "no type" and would drop out silently, indistinguishable from a
# reference note. The fixture revokes POSIX permission bits, which Windows does
# not model the same way, so the whole block is skipped there with a reason
# rather than asserted on a platform where chmod is a no-op.
if ($IsWindows) {
    _Skip 'pnb.test: an unreadable NOTE fails the scan' 'chmod-based permission fixture is POSIX-only'
    _Skip 'pnb.test: the unreadable note is named' 'chmod-based permission fixture is POSIX-only'
    _Skip 'pnb.test: an unreadable STORE fails the scan' 'chmod-based permission fixture is POSIX-only'
    _Skip 'pnb.test: the unreadable store is named' 'chmod-based permission fixture is POSIX-only'
    _Skip 'pnb.test: an unreadable store never reports a clean PASS' 'chmod-based permission fixture is POSIX-only'
} else {
    $PNB_PERM = Join-Path $PNB_TMP 'store-perm'
    $PNB_PERM_NOTE = Join-Path $PNB_PERM 'arc.md'
    New-PnbNote $PNB_PERM_NOTE 'type: project' 512
    & chmod 000 $PNB_PERM_NOTE 2>&1 | Out-Null
    # Root can read a 000 file, so prove the revoke actually took before
    # asserting on it — the same probe the script itself uses.
    $pnbNoteRevoked = $false
    try { $pnbProbe = [System.IO.File]::OpenRead($PNB_PERM_NOTE); $pnbProbe.Close() }
    catch { $pnbNoteRevoked = $true }
    if ($pnbNoteRevoked) {
        $pnbPermNote = Invoke-Pnb @('--memory-dir', $PNB_PERM)
        Assert-Eq 'pnb.test: an unreadable NOTE fails the scan' 1 $pnbPermNote.Rc
        Assert-Contains 'pnb.test: the unreadable note is named' `
            $pnbPermNote.Out "FAIL memory note not readable: $PNB_PERM_NOTE"
    } else {
        _Skip 'pnb.test: an unreadable NOTE fails the scan' 'cannot revoke read (running as root?)'
        _Skip 'pnb.test: the unreadable note is named' 'cannot revoke read (running as root?)'
    }
    & chmod 644 $PNB_PERM_NOTE 2>&1 | Out-Null

    & chmod 000 $PNB_PERM 2>&1 | Out-Null
    $pnbDirRevoked = $false
    try { [void][System.IO.Directory]::GetFileSystemEntries($PNB_PERM) }
    catch { $pnbDirRevoked = $true }
    if ($pnbDirRevoked) {
        $pnbPermDir = Invoke-Pnb @('--memory-dir', $PNB_PERM)
        & chmod 755 $PNB_PERM 2>&1 | Out-Null
        Assert-Eq 'pnb.test: an unreadable STORE fails the scan' 1 $pnbPermDir.Rc
        Assert-Contains 'pnb.test: the unreadable store is named' `
            $pnbPermDir.Out "FAIL memory dir not readable: $PNB_PERM"
        Assert-NotContains 'pnb.test: an unreadable store never reports a clean PASS' `
            $pnbPermDir.Out 'PASS every project-type note'
    } else {
        & chmod 755 $PNB_PERM 2>&1 | Out-Null
        _Skip 'pnb.test: an unreadable STORE fails the scan' 'cannot revoke read (running as root?)'
        _Skip 'pnb.test: the unreadable store is named' 'cannot revoke read (running as root?)'
        _Skip 'pnb.test: an unreadable store never reports a clean PASS' 'cannot revoke read (running as root?)'
    }
}

# === 7c. The scan is DEPTH-1 by contract: a memory store is a flat directory of
# notes, and its subdirectories (attachments, archives, a nested store with its
# own index) are not this store's notes. Pinned because a one-character change to
# the enumeration would recurse into an operator's whole archive tree.
$PNB_DEPTH = Join-Path $PNB_TMP 'store-depth'
New-PnbNote (Join-Path $PNB_DEPTH 'arc.md') 'type: project' 512
New-PnbNote (Join-Path $PNB_DEPTH 'archive' 'retired-arc.md') 'type: project' 17408
$pnbDepth = Invoke-Pnb @('--memory-dir', $PNB_DEPTH)
Assert-Eq 'pnb.test: an over-budget note in a SUBDIRECTORY does not fail the scan' 0 $pnbDepth.Rc
Assert-Contains 'pnb.test: the subdirectory note is not counted in the denominator' `
    $pnbDepth.Out 'scanned 1 project note(s) in 1 dir(s)'
Assert-NotContains 'pnb.test: the subdirectory note is never reported' `
    $pnbDepth.Out 'retired-arc.md'

# === 8. -MemoryDir is REPEATABLE: one verdict over every store, each finding
# attributed to the store it fired in, and the denominator counting both dirs.
$pnbMulti = Invoke-Pnb @('--memory-dir', $PNB_OK, '--memory-dir', $PNB_BIG)
Assert-Eq 'pnb.test: a repeated --memory-dir with one bad store exits 1' 1 $pnbMulti.Rc
Assert-Contains 'pnb.test: the denominator counts both stores' $pnbMulti.Out 'scanned 3 project note(s) in 2 dir(s)'
Assert-Contains 'pnb.test: the finding is attributed to its own store' $pnbMulti.Out $PNB_BIG_NOTE

# === 9. --warn-kb raises the cap and the SAME store then passes — proving the
# knob is really consulted, not decoration.
$pnbKb = Invoke-Pnb @('--memory-dir', $PNB_BIG, '--warn-kb', '20')
Assert-Eq 'pnb.test: --warn-kb 20 passes the store that fails at 16' 0 $pnbKb.Rc
Assert-Contains 'pnb.test: the raised cap is echoed in the denominator' $pnbKb.Out 'against a 20 KB budget'

# === 10. local.env supplies the cap, read as DATA — never imported into the
# process environment. The fixture carries a POSIX command substitution that
# would create a sentinel file if the file were executed. BOTH halves matter: the
# sentinel must NOT appear, and the cap MUST take effect (the file really was
# read) — without the second half the first would pass just as happily against a
# parser that ignores local.env entirely.
$PNB_LENV = Join-Path $PNB_TMP 'local-env-cap.env'
$PNB_SENTINEL = Join-Path $PNB_TMP 'sourced-sentinel'
Write-PnbFile $PNB_LENV ("EVIL=`$(touch `"$PNB_SENTINEL`")`nPROJECT_NOTE_BODY_WARN_KB=`"20`"`n")
$env:AI_CONFIG_LOCAL_ENV = $PNB_LENV
$pnbLenv = Invoke-Pnb @('--memory-dir', $PNB_BIG)
$env:AI_CONFIG_LOCAL_ENV = $PNB_NOENV
Assert-Eq 'pnb.test: the local.env cap takes effect (the file really was read)' 0 $pnbLenv.Rc
Assert-Contains 'pnb.test: the local.env cap is echoed in the denominator' $pnbLenv.Out 'against a 20 KB budget'
if (Test-Path -LiteralPath $PNB_SENTINEL) {
    _Fail 'pnb.test: local.env is read as DATA, never executed' "sentinel created: $PNB_SENTINEL"
} else {
    _Pass 'pnb.test: local.env is read as DATA, never executed'
}

# === 11. Cap PRECEDENCE: flag > local.env > ambient env > default. The local.env
# fixture sets 20 and the ambient var sets 1, so an inversion flips the verdict —
# neither assertion can pass vacuously.
$env:AI_CONFIG_LOCAL_ENV = $PNB_LENV
$env:PROJECT_NOTE_BODY_WARN_KB = '1'
$pnbPrec1 = Invoke-Pnb @('--memory-dir', $PNB_BIG)
$pnbPrec2 = Invoke-Pnb @('--memory-dir', $PNB_BIG, '--warn-kb', '32')
Remove-Item Env:PROJECT_NOTE_BODY_WARN_KB -ErrorAction SilentlyContinue
$env:AI_CONFIG_LOCAL_ENV = $PNB_NOENV
$env:PROJECT_NOTE_BODY_WARN_KB = '20'
$pnbPrec3 = Invoke-Pnb @('--memory-dir', $PNB_BIG)
Remove-Item Env:PROJECT_NOTE_BODY_WARN_KB -ErrorAction SilentlyContinue
Assert-Contains 'pnb.test: local.env beats the ambient env var' $pnbPrec1.Out 'against a 20 KB budget'
Assert-Contains 'pnb.test: --warn-kb beats local.env' $pnbPrec2.Out 'against a 32 KB budget'
Assert-Contains 'pnb.test: the ambient env var is used when local.env has no key' `
    $pnbPrec3.Out 'against a 20 KB budget'

# === 12. An UNUSABLE cap degrades to the default SILENTLY. The digit bound is
# load-bearing on the bash side, where KB*1024 is 64-bit signed arithmetic that a
# huge value wraps to 0; the twin applies the same bound so both shells accept
# and reject exactly the same knob values.
foreach ($bad in @('0', 'abc', '-5', '18014398509481984')) {
    $env:PROJECT_NOTE_BODY_WARN_KB = $bad
    $pnbBad = Invoke-Pnb @('--memory-dir', $PNB_OK)
    Remove-Item Env:PROJECT_NOTE_BODY_WARN_KB -ErrorAction SilentlyContinue
    Assert-Contains "pnb.test: an unusable cap '$bad' falls back to the 16 KB default" `
        $pnbBad.Out 'against a 16 KB budget'
}

# === 12b. LEADING-ZERO cap values. bash reads a leading-zero literal as OCTAL:
# `08` was an arithmetic ERROR that aborted the run before the denominator ever
# printed, and `0000016` silently meant 14 — while this twin's [int] parse read
# both as decimal, so the two shells disagreed on the same operator input. Both
# now normalize to base 10 and echo the NORMALIZED value. The whole output is
# compared against the plain-decimal spelling, so a normalization that fixed only
# the denominator line would still fail here.
$pnbZ08 = Invoke-Pnb @('--memory-dir', $PNB_OK, '--warn-kb', '08')
$pnbD8 = Invoke-Pnb @('--memory-dir', $PNB_OK, '--warn-kb', '8')
Assert-Eq 'pnb.test: --warn-kb 08 completes (no octal arithmetic abort)' 0 $pnbZ08.Rc
Assert-Contains 'pnb.test: --warn-kb 08 echoes the NORMALIZED cap' $pnbZ08.Out 'against a 8 KB budget'
Assert-Eq 'pnb.test: --warn-kb 08 and --warn-kb 8 produce identical output' $pnbD8.Out $pnbZ08.Out
$pnbZ16 = Invoke-Pnb @('--memory-dir', $PNB_OK, '--warn-kb', '0000016')
$pnbD16 = Invoke-Pnb @('--memory-dir', $PNB_OK, '--warn-kb', '16')
Assert-Eq 'pnb.test: --warn-kb 0000016 completes' 0 $pnbZ16.Rc
Assert-Contains 'pnb.test: --warn-kb 0000016 is decimal 16, not octal 14' $pnbZ16.Out 'against a 16 KB budget'
Assert-Eq 'pnb.test: --warn-kb 0000016 and --warn-kb 16 produce identical output' $pnbD16.Out $pnbZ16.Out

# === 13. A store path containing a SPACE is handled intact (this framework's own
# home carries one).
$PNB_SPACED = Join-Path $PNB_TMP 'store with space'
$PNB_SPACED_NOTE = Join-Path $PNB_SPACED 'oversize.md'
New-PnbNote $PNB_SPACED_NOTE 'type: project' 17408
$pnbSpaced = Invoke-Pnb @('--memory-dir', $PNB_SPACED)
Assert-Eq 'pnb.test: a spaced store path exits 1' 1 $pnbSpaced.Rc
Assert-Contains 'pnb.test: the spaced path is reported intact' $pnbSpaced.Out $PNB_SPACED_NOTE

# === 14. Usage errors exit 2 (distinct from a finding, so a caller can tell "the
# check said no" from "you invoked it wrong"). Unlike the `--draft` case recorded
# in [[reference_ps_binder_and_automatic_variable_traps]], `--memory-dir` and
# `--warn-kb` carry an interior hyphen, so the binder cannot prefix-match them to
# -MemoryDir / -WarnKb and the $Rest loop sees them — exit 2, same as bash.
Assert-Eq 'pnb.test: an unknown arg is a usage error' 2 (Invoke-Pnb @('--bogus')).Rc
Assert-Eq 'pnb.test: --memory-dir without a value is a usage error' 2 (Invoke-Pnb @('--memory-dir')).Rc
# An EXPLICIT empty value is a usage error too, never a silent fallback to the
# named SKIP: `--memory-dir $someUnsetVar` must fail loudly, not report a clean
# run over nothing.
$pnbEmpty = Invoke-Pnb @('--memory-dir', '')
Assert-Eq 'pnb.test: an explicitly EMPTY --memory-dir is a usage error' 2 $pnbEmpty.Rc
Assert-Contains 'pnb.test: the empty --memory-dir message names the requirement' `
    $pnbEmpty.Out 'FAIL --memory-dir requires a non-empty value'
Assert-NotContains 'pnb.test: an empty --memory-dir never degrades to the named SKIP' `
    $pnbEmpty.Out 'SKIP'
Assert-Eq 'pnb.test: --warn-kb without a value is a usage error' 2 (Invoke-Pnb @('--warn-kb')).Rc
Assert-Eq 'pnb.test: --help exits 0' 0 (Invoke-Pnb @('--help')).Rc

# === 15. Wiring, so a future refactor that drops the check is caught here: the
# gate's check set names this script, and the capability body carries the rule the
# finding points operators at.
$pnbGateBody = [System.IO.File]::ReadAllText((Join-Path $env:REPO_ROOT 'scripts' 'closeout-gate.ps1'))
Assert-Contains 'pnb.test: closeout-gate.ps1 runs check-project-note-budget.ps1 in its check set' `
    $pnbGateBody 'check-project-note-budget.ps1'
$pnbCloseoutBody = [System.IO.File]::ReadAllText((Join-Path $env:REPO_ROOT 'capabilities' 'closeout.md'))
Assert-Contains 'pnb.test: closeout.md carries the project-note budget memory-hygiene rule' `
    $pnbCloseoutBody '**Project-note budget.**'
Assert-Contains 'pnb.test: closeout.md names the knob the check reads' `
    $pnbCloseoutBody 'PROJECT_NOTE_BODY_WARN_KB'

} finally {
    if ($null -ne $pnbSavedLocalEnv) { $env:AI_CONFIG_LOCAL_ENV = $pnbSavedLocalEnv }
    else { Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue }
    if ($null -ne $pnbSavedCap) { $env:PROJECT_NOTE_BODY_WARN_KB = $pnbSavedCap }
    else { Remove-Item Env:PROJECT_NOTE_BODY_WARN_KB -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $PNB_TMP -Recurse -Force -ErrorAction SilentlyContinue
}
