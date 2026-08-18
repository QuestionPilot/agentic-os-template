#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/entrypoint-token-occurrence.test.ps1 —. PowerShell twin of
# tests/entrypoint-token-occurrence.test.sh. Behavior-equivalent: same labels,
# same assertions, same fixtures. Mirrors the bash semantics per the twin-
# parity rule (each runner globs only its own extension, so per-file assertions
# must live in BOTH twins).
#
# assert each multi-line INJECTION-MARKER token
# (`@@CAPABILITY_CATALOG@@`) appears EXACTLY ONCE in every entrypoint template
# that uses it. install.sh / install.ps1 substitute `@@TOKEN@@` placeholders
# GLOBALLY; a stray second copy of the catalog marker (e.g. in prose explaining
# the mechanism) silently injects the whole table over that prose. PATH-CLASS
# tokens (`@@AI_CONFIG_DIR@@`, `@@OBSIDIAN_VAULT_PATH@@`) are excluded — they
# resolve to a single-line value and legitimately recur. See the.sh twin and
# [[feedback_install_sh_global_substitution_prose_trap]] for the full rationale.
#
# the root entrypoints must DESCRIBE referenced script code, never
# cite it by a brittle hardcoded line number ("line 71 of install.sh").

$repoRoot = $env:REPO_ROOT

# Count-Token <file> <literal-token> — number of literal occurrences in <file>.
# Mirrors bash count_token (grep -oF | grep -c.). [regex]::Escape makes the
# token a literal pattern; [regex]::Matches counts every occurrence (not lines).
function Count-Token {
    param([string]$File, [string]$Token)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return 0 }
    $text = [System.IO.File]::ReadAllText($File)
    return ([regex]::Matches($text, [regex]::Escape($Token))).Count
}

# The injection-marker token whose global substitution injects a multi-line
# block. Keep in lockstep with any new marker substitution in install.{sh,ps1}.
$MarkerToken = '@@CAPABILITY_CATALOG@@'

# Every entrypoint template that legitimately carries the marker.
$MarkerTemplates = @(
    'harnesses/claude/CLAUDE.template.md',
    'harnesses/codex/AGENTS.template.md',
    'harnesses/cursor/AGENTS.template.md',
    'harnesses/claude/SKILLS.template.md'
)

foreach ($tpl in $MarkerTemplates) {
    $path = Join-Path $repoRoot $tpl
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        _Fail "entrypoint template exists: $tpl" @("file not found: $path")
        continue
    }
    $n = Count-Token -File $path -Token $MarkerToken
    Assert-Eq "$tpl carries exactly one $MarkerToken (no prose-clobber copy)" '1' "$n"
}

# the operator-skills-overlay marker is the SECOND multi-line injection
# marker — install.{sh,ps1} splice the operator overlay file at it. It lives in
# the claude SKILLS template ONLY. Same one-occurrence invariant as the catalog
# marker. Built from halves so this test SOURCE carries no second literal copy.
$OverlayMarker = '@@OPERATOR_SKILLS' + '_OVERLAY@@'
$overlayN = Count-Token -File (Join-Path $repoRoot 'harnesses/claude/SKILLS.template.md') -Token $OverlayMarker
Assert-Eq 'SKILLS.template.md carries exactly one operator-overlay marker (no prose-clobber copy)' '1' "$overlayN"

# --- no brittle line-number citation of a script ------------------
# Forbidden phrasings (case-insensitive on `line`): "line <N> of `…install.sh`"
# and "`…install.sh` line <N>". Mirror the bash POSIX ERE in a.NET regex. The
# left word-boundary `(^|[^a-zA-Z0-9_])` is the.NET equivalent of the bash
# `(^|[^[:alnum:]_])` so words ending in "line" + a number do NOT false-match.
# `\.` is a literal dot. Backtick is NOT a.NET regex metachar — and inside a PS
# single-quoted string it is a literal char too, so the pattern carries real
# backticks. Verified equivalent to the bash twin across the fixture set.
$LineCiteRe = '(^|[^a-zA-Z0-9_])[Ll]ine [0-9]+ of `?[a-zA-Z0-9/._-]*\.sh|`[a-zA-Z0-9/._-]*\.sh` [Ll]ine [0-9]+'
foreach ($ep in @('CLAUDE.md', 'AGENTS.md')) {
    $epPath = Join-Path $repoRoot $ep
    if (-not (Test-Path -LiteralPath $epPath -PathType Leaf)) {
        _Fail "root entrypoint exists: $ep" @("file not found: $epPath")
        continue
    }
    $hits = Select-String -LiteralPath $epPath -Pattern $LineCiteRe -CaseSensitive -AllMatches
    if (-not $hits) {
        _Pass "$ep has no brittle 'line N of <script>.sh' citation"
    } else {
        $lines = @($hits | ForEach-Object { "$($_.LineNumber):$($_.Line)" })
        _Fail "$ep must DESCRIBE referenced script code, not cite it by line number" $lines
    }
}

# Positive controls: the forbidden pattern MUST match each known-brittle
# phrasing, so an over-narrow regex can't make the guard above vacuously pass.
# Both forbidden forms get a fixture (Codex review: cover the second form too).
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
function Test-CitePositive {
    param([string]$Label, [string]$Line)
    if ([regex]::IsMatch($Line, $LineCiteRe)) {
        _Pass $Label
    } else {
        _Fail $Label @("regex failed to match: $Line")
    }
}
Test-CitePositive 'line-citation regex matches form A: line N of script.sh (self-trip guard)' `
    'requires local.env — it exits early if not (line 71 of `scripts/install.sh`).'
Test-CitePositive 'line-citation regex matches form B: script.sh line N (self-trip guard)' `
    'see `scripts/install.sh` line 71 for the existence guard.'
# Negative control: a word ending in "line" + number must NOT match (boundary).
$negLine = 'the baseline 71 of `scripts/install.sh` reference must not trip this.'
if ([regex]::IsMatch($negLine, $LineCiteRe)) {
    _Fail 'line-citation regex does NOT match a baseline-N false-positive (boundary guard)' @(
        'regex wrongly matched a word ending in "line"')
} else {
    _Pass 'line-citation regex does NOT match a baseline-N false-positive (boundary guard)'
}

# --- Detector self-trip guard (negative test) ------------------------------
# Prove Count-Token catches a stray second occurrence — otherwise a bug that
# always returned 1 would make every assertion above vacuously pass. Build the
# fixture at runtime so this test SOURCE does not itself carry two literal
# marker tokens.
$tripFixture = [System.IO.Path]::GetTempFileName()
$tripText = @(
    '# fixture entrypoint',
    '',
    'A real marker line:',
    $MarkerToken,
    '',
    "A stray prose copy naming the $MarkerToken token mid-sentence."
) -join "`n"
$tripText += "`n"
[System.IO.File]::WriteAllText($tripFixture, $tripText, $utf8NoBom)
$tripN = Count-Token -File $tripFixture -Token $MarkerToken
Assert-Eq 'detector counts both occurrences in a two-marker fixture (self-trip guard)' '2' "$tripN"
if ($tripN -ne 1) {
    _Pass 'two-marker fixture is rejected by the one-occurrence rule'
} else {
    _Fail 'two-marker fixture is rejected by the one-occurrence rule' @("count was $tripN")
}
Remove-Item -LiteralPath $tripFixture -Force -ErrorAction SilentlyContinue
