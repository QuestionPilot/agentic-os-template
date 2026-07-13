#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/quickstart.test.ps1 — assert the Quickstart section anchors
# exist in README.md and the examples/ scaffold exists.
#
# Behavior-equivalent twin of tests/quickstart.test.sh.
# Uses [System.IO.File]::WriteAllText (no-BOM UTF-8) for any file writes;
# ASCII whitespace class `[\t\f\v\r]` (not \s) for PS regex per parity rules.
# These tests are purely structural (no network, no install).
#
# Per [[feedback_self_tripping_test_source]], runtime-construct the sentinel
# string values so this test file's own source does not self-trip the scanner.

$README     = Join-Path $env:REPO_ROOT 'README.md'
$ReadmeText = if (Test-Path -LiteralPath $README -PathType Leaf) {
    [System.IO.File]::ReadAllText($README)
} else { '' }

# --- (a) README.md Quickstart section ---------------------------------------

# Section heading (runtime-construct to avoid self-trip)
$QS_HEAD = '##' + ' Quickstart'
Assert-Contains "README.md has Quickstart section heading" `
    $ReadmeText $QS_HEAD

Assert-Contains "README.md Quickstart has who-is-this-for prose" `
    $ReadmeText "operator"

Assert-Contains "README.md Quickstart has clone step" `
    $ReadmeText "git clone"

Assert-Contains "README.md Quickstart has bootstrap install step" `
    $ReadmeText "bootstrap"

Assert-Contains "README.md Quickstart has first-run guidance" `
    $ReadmeText "session-agent"

Assert-Contains "README.md references examples/ directory" `
    $ReadmeText "examples/"

# --- (b) examples/ scaffold -------------------------------------------------

$ExamplesDir = Join-Path $env:REPO_ROOT 'examples'

Assert-File "examples/ README exists" `
    (Join-Path $ExamplesDir 'README.md')

Assert-File "examples/sample-project/ CLAUDE.md exists" `
    (Join-Path $ExamplesDir 'sample-project' 'CLAUDE.md')

Assert-File "examples/sample-project/ local.env.example exists" `
    (Join-Path $ExamplesDir 'sample-project' 'local.env.example')

# --- (c) examples content markers -------------------------------------------

$ExamplesReadme = $ExamplesDir + [System.IO.Path]::DirectorySeparatorChar + 'README.md'
$ExamplesReadmeText = if (Test-Path -LiteralPath $ExamplesReadme -PathType Leaf) {
    [System.IO.File]::ReadAllText($ExamplesReadme)
} else { '' }

$HOW_HEADER = '##' + ' How to run'
Assert-Contains "examples/README.md has How-to-run section" `
    $ExamplesReadmeText $HOW_HEADER

Assert-Contains "examples/README.md references session-agent" `
    $ExamplesReadmeText "session-agent"

$SpClaude = Join-Path $ExamplesDir 'sample-project' 'CLAUDE.md'
$SpClaudeText = if (Test-Path -LiteralPath $SpClaude -PathType Leaf) {
    [System.IO.File]::ReadAllText($SpClaude)
} else { '' }
Assert-Contains "examples/sample-project/CLAUDE.md references session-agent" `
    $SpClaudeText "session-agent"

$SpEnv = Join-Path $ExamplesDir 'sample-project' 'local.env.example'
$SpEnvText = if (Test-Path -LiteralPath $SpEnv -PathType Leaf) {
    [System.IO.File]::ReadAllText($SpEnv)
} else { '' }
Assert-Contains "examples/sample-project/local.env.example has CLAUDE_CONFIG_DIR" `
    $SpEnvText "CLAUDE_CONFIG_DIR"
