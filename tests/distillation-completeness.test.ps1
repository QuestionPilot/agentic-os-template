#Requires -Version 7
# tests/distillation-completeness.test.ps1 — Windows-native twin of
# tests/distillation-completeness.test.sh.
#
# Behavioral tests for scripts/check-distillation-completeness.ps1. The check
# cross-references every feedback/decision memory note against the 04-Lessons
# corpus. A note is DISTILLED when its name appears as a whole token anywhere in
# the corpus (kebab `-` and snake `_` interchangeable). Exit 0 = all distilled
# (or none to check), 1 = one or more undistilled, 2 = usage error.
#
# Mirrors the .sh twin 1:1 — same fixtures, same assertions.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$CMD_SCRIPT = Join-Path $env:REPO_ROOT 'scripts' 'check-distillation-completeness.ps1'
Assert-File 'distill.test: scripts/check-distillation-completeness.ps1 exists' $CMD_SCRIPT

function Write-LfFile {
    param([string]$Path, [string]$Content)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function New-TempDir {
    param([string]$Prefix = 'distill-test')
    $d = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + '-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $d
}

# New-Note <dir> <filename> <type> [body] — write a memory note with a
# frontmatter type. Single-quoted format string; values interpolated via -f.
function New-Note {
    param([string]$Dir, [string]$Name, [string]$Type, [string]$Body = 'Body.')
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $content = "---`nname: $stem`ndescription: `"n`"`nmetadata:`n  type: $Type`n---`n$Body`n"
    Write-LfFile (Join-Path $Dir $Name) $content
}

# --- Setup: a lessons dir with one thematic note recording two source notes
# (kebab + snake) plus a third name in the BODY.
$LES = New-TempDir 'distill-les'
$lessonContent = @'
---
title: Example Theme
---

## Durable Lesson

Body mentions feedback-body-recorded as a provenance reference inline.

## Source Notes

- feedback-already-kebab
- feedback_already_snake
'@
Write-LfFile (Join-Path $LES '2026-06-15 - Example Theme.md') ($lessonContent + "`n")

# === 1. All feedback notes distilled → exit 0, PASS.
$MEM_OK = New-TempDir 'distill-ok'
New-Note $MEM_OK 'feedback-already-kebab.md' 'feedback'
New-Note $MEM_OK 'feedback_already_snake.md' 'feedback'
New-Note $MEM_OK 'feedback-body-recorded.md' 'feedback'
$OK_OUT = & pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_OK --lessons-dir $LES 2>&1
$OK_RC = $LASTEXITCODE
if ($OK_OUT -is [array]) { $OK_OUT = $OK_OUT -join "`n" }
Assert-Eq 'distill.test: all-distilled dir exits 0' '0' "$OK_RC"
Assert-Contains 'distill.test: all-distilled reports PASS' $OK_OUT 'PASS'
Assert-Contains 'distill.test: PASS names the count (3 checked)' $OK_OUT 'all 3 feedback/decision'

# === 2. kebab↔snake normalization, both directions: neither note flagged.
Assert-NotContains 'distill.test: kebab note matches snake Source-Notes entry' $OK_OUT 'feedback-already-kebab.md'
Assert-NotContains 'distill.test: snake note matches kebab (reverse) not flagged' $OK_OUT 'feedback_already_snake.md'
Assert-NotContains 'distill.test: body-recorded name counts (whole-file scan)' $OK_OUT 'feedback-body-recorded.md'

# === 3. An undistilled feedback note → exit 1, names the file.
$MEM_BAD = New-TempDir 'distill-bad'
New-Note $MEM_BAD 'feedback-already-kebab.md' 'feedback'
New-Note $MEM_BAD 'feedback-never-promoted.md' 'feedback'
$BAD_OUT = & pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_BAD --lessons-dir $LES 2>&1
$BAD_RC = $LASTEXITCODE
if ($BAD_OUT -is [array]) { $BAD_OUT = $BAD_OUT -join "`n" }
Assert-Eq 'distill.test: undistilled note exits 1' '1' "$BAD_RC"
Assert-Contains 'distill.test: names the undistilled note' $BAD_OUT 'feedback-never-promoted.md'
Assert-NotContains 'distill.test: does not flag the distilled note' $BAD_OUT 'feedback-already-kebab.md'
Assert-Contains 'distill.test: failure summary counts undistilled' $BAD_OUT '1 of 2 feedback/decision'

# === 4. Decision notes are in scope (by filename prefix).
$MEM_DEC = New-TempDir 'distill-dec'
New-Note $MEM_DEC 'decision-undistilled.md' 'decision'
$DEC_OUT = & pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_DEC --lessons-dir $LES 2>&1
$DEC_RC = $LASTEXITCODE
if ($DEC_OUT -is [array]) { $DEC_OUT = $DEC_OUT -join "`n" }
Assert-Eq 'distill.test: undistilled decision note exits 1' '1' "$DEC_RC"
Assert-Contains 'distill.test: names the undistilled decision note' $DEC_OUT 'decision-undistilled.md'

# === 5. Frontmatter-type selection: feedback-by-frontmatter checked; project/
# reference out of scope.
$MEM_FM = New-TempDir 'distill-fm'
New-Note $MEM_FM 'home-folder.md' 'feedback'
New-Note $MEM_FM 'project-active-thing.md' 'project'
New-Note $MEM_FM 'reference-stable-pointer.md' 'reference'
$FM_OUT = & pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_FM --lessons-dir $LES 2>&1
$FM_RC = $LASTEXITCODE
if ($FM_OUT -is [array]) { $FM_OUT = $FM_OUT -join "`n" }
Assert-Eq 'distill.test: feedback-by-frontmatter note is checked → exit 1' '1' "$FM_RC"
Assert-Contains 'distill.test: flags the no-prefix feedback-typed note' $FM_OUT 'home-folder.md'
Assert-NotContains 'distill.test: ignores project_* notes' $FM_OUT 'project-active-thing.md'
Assert-NotContains 'distill.test: ignores reference_* notes' $FM_OUT 'reference-stable-pointer.md'

# === 6. Whole-token boundary: a shorter prefix name is not falsely matched.
$MEM_BND = New-TempDir 'distill-bnd'
$LES_BND = New-TempDir 'distill-les-bnd'
$bndLesson = @'
---
title: Boundary
---
## Source Notes
- feedback-cross-model-review-infra
'@
Write-LfFile (Join-Path $LES_BND 'lesson.md') ($bndLesson + "`n")
New-Note $MEM_BND 'feedback-cross-model-review.md' 'feedback'
$BND_OUT = & pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_BND --lessons-dir $LES_BND 2>&1
$BND_RC = $LASTEXITCODE
if ($BND_OUT -is [array]) { $BND_OUT = $BND_OUT -join "`n" }
Assert-Eq 'distill.test: prefix-name not falsely matched by a longer distilled name' '1' "$BND_RC"
Assert-Contains 'distill.test: the prefix note is flagged undistilled' $BND_OUT 'feedback-cross-model-review.md'

# === 7. No feedback/decision notes → exit 0.
$MEM_NONE = New-TempDir 'distill-none'
New-Note $MEM_NONE 'project-only.md' 'project'
New-Note $MEM_NONE 'reference-only.md' 'reference'
Assert-Exit 'distill.test: no feedback/decision notes exits 0' 0 -- pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_NONE --lessons-dir $LES

# === 8. MEMORY.md is never treated as a feedback note.
$MEM_IDX = New-TempDir 'distill-idx'
Write-LfFile (Join-Path $MEM_IDX 'MEMORY.md') "# Memory Index`n`n- [x](feedback-something.md) — a pointer line`n"
Assert-Exit 'distill.test: MEMORY.md alone exits 0 (not a feedback note)' 0 -- pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_IDX --lessons-dir $LES

# === 9. Usage errors: missing dirs and unresolvable env → exit 2.
$missingMem = '/tmp/no-such-mem-' + [Guid]::NewGuid().Guid.Substring(0, 8)
$missingLes = '/tmp/no-such-les-' + [Guid]::NewGuid().Guid.Substring(0, 8)
Assert-Exit 'distill.test: missing memory dir exits 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $missingMem --lessons-dir $LES
Assert-Exit 'distill.test: missing lessons dir exits 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_OK --lessons-dir $missingLes

# No --lessons-dir + no OBSIDIAN_VAULT_PATH → exit 2 (save/clear/restore env).
$savedVault = $env:OBSIDIAN_VAULT_PATH
try {
    Remove-Item Env:OBSIDIAN_VAULT_PATH -ErrorAction SilentlyContinue
    & pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_OK *>$null
    Assert-Eq 'distill.test: no --lessons-dir + no OBSIDIAN_VAULT_PATH exits 2' '2' "$LASTEXITCODE"
} finally {
    if ($null -ne $savedVault) { $env:OBSIDIAN_VAULT_PATH = $savedVault }
}

# No --memory-dir + no CLAUDE_CONFIG_DIR → exit 2.
$savedCCD = $env:CLAUDE_CONFIG_DIR
try {
    Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    & pwsh -NoProfile -File $CMD_SCRIPT --lessons-dir $LES *>$null
    Assert-Eq 'distill.test: no --memory-dir + no CLAUDE_CONFIG_DIR exits 2' '2' "$LASTEXITCODE"
} finally {
    if ($null -ne $savedCCD) { $env:CLAUDE_CONFIG_DIR = $savedCCD }
}

# === 10. Spaced lessons path (cloud-vault realism).
$LES_SPACE_ROOT = New-TempDir 'distill-les-space'
$LES_SPACE = Join-Path $LES_SPACE_ROOT 'My Lessons'
New-Item -ItemType Directory -Path $LES_SPACE -Force | Out-Null
Copy-Item (Join-Path $LES '2026-06-15 - Example Theme.md') $LES_SPACE
$SPACE_OUT = & pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_OK --lessons-dir $LES_SPACE 2>&1
$SPACE_RC = $LASTEXITCODE
if ($SPACE_OUT -is [array]) { $SPACE_OUT = $SPACE_OUT -join "`n" }
Assert-Eq 'distill.test: spaced lessons path resolves (all distilled) exit 0' '0' "$SPACE_RC"
Assert-Contains 'distill.test: spaced-path run reports PASS' $SPACE_OUT 'PASS'

# === 11. --help exits 0 and prints the banner.
$HELP_OUT = & pwsh -NoProfile -File $CMD_SCRIPT --help 2>&1
$HELP_RC = $LASTEXITCODE
if ($HELP_OUT -is [array]) { $HELP_OUT = $HELP_OUT -join "`n" }
Assert-Eq 'distill.test: --help exits 0' '0' "$HELP_RC"
Assert-Contains 'distill.test: --help prints the banner' $HELP_OUT 'check-distillation-completeness.ps1'

# === 12. Unknown arg → exit 2.
Assert-Exit 'distill.test: unknown arg exits 2' 2 -- pwsh -NoProfile -File $CMD_SCRIPT --bogus

# === 13. Bare feedback.md / decision.md stems are in scope (Codex F3). A
# non-feedback frontmatter type isolates the bare-stem filename match.
$MEM_BARE = New-TempDir 'distill-bare'
New-Note $MEM_BARE 'feedback.md' 'note'
New-Note $MEM_BARE 'decision.md' 'note'
$BARE_OUT = & pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_BARE --lessons-dir $LES 2>&1
$BARE_RC = $LASTEXITCODE
if ($BARE_OUT -is [array]) { $BARE_OUT = $BARE_OUT -join "`n" }
Assert-Eq 'distill.test: bare feedback.md/decision.md stems are in scope → exit 1' '1' "$BARE_RC"
Assert-Contains 'distill.test: flags bare feedback.md' $BARE_OUT 'feedback.md'
Assert-Contains 'distill.test: flags bare decision.md' $BARE_OUT 'decision.md'

# Boundary: feedbackish-thing.md (non-feedback type) is NOT a feedback note.
$MEM_NOTFB = New-TempDir 'distill-notfb'
New-Note $MEM_NOTFB 'feedbackish-thing.md' 'reference'
Assert-Exit 'distill.test: feedbackish-* is not a feedback note (exit 0)' 0 -- pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_NOTFB --lessons-dir $LES

# === 14. BOM'd frontmatter-only feedback note (no prefix) is in scope (Codex F4).
# ReadAllLines strips the BOM so the frontmatter is read and the type detected.
$MEM_BOM = New-TempDir 'distill-bom'
$bomContent = "---`nname: home-folder`ndescription: `"n`"`nmetadata:`n  type: feedback`n---`nBody.`n"
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
[System.IO.File]::WriteAllText((Join-Path $MEM_BOM 'home-folder.md'), $bomContent, $utf8Bom)
$BOM_OUT = & pwsh -NoProfile -File $CMD_SCRIPT --memory-dir $MEM_BOM --lessons-dir $LES 2>&1
$BOM_RC = $LASTEXITCODE
if ($BOM_OUT -is [array]) { $BOM_OUT = $BOM_OUT -join "`n" }
Assert-Eq "distill.test: BOM'd frontmatter-only feedback note is in scope → exit 1" '1' "$BOM_RC"
Assert-Contains "distill.test: flags the BOM'd no-prefix feedback note" $BOM_OUT 'home-folder.md'

# --- Cleanup.
foreach ($d in @($LES, $MEM_OK, $MEM_BAD, $MEM_DEC, $MEM_FM, $MEM_BND, $LES_BND, `
                 $MEM_NONE, $MEM_IDX, $LES_SPACE_ROOT, $MEM_BARE, $MEM_NOTFB, $MEM_BOM)) {
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
