#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/bootstrap-linux-doc.test.ps1 — Windows-native twin of
# tests/bootstrap-linux-doc.test.sh.
#
# Asserts that playbooks/new-machine-bootstrap.md contains a Linux (apt-based)
# walked path covering the required steps.
#
# tests/lib.ps1 is dot-sourced by tests/run.ps1; Assert-* + counters already in
# scope. Do NOT re-dot-source.

$BootstrapPlaybook = Join-Path $env:REPO_ROOT 'playbooks' 'new-machine-bootstrap.md'

Assert-File 'bootstrap-linux-doc: playbook exists' $BootstrapPlaybook

$pb = [System.IO.File]::ReadAllText($BootstrapPlaybook)

# --- Extract the Linux section (from '### Linux' through the next '###' heading) ---
# Mirrors the bash awk extraction: scopes subsequent assertions to the Linux
# section only (Codex F-1: whole-file token presence passes even if content is
# in the wrong section). Uses LF-split; CRLF files are pre-trimmed by TrimEnd.
$pbLines = $pb -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
$linuxLines = [System.Collections.Generic.List[string]]::new()
$inLinux = $false
foreach ($line in $pbLines) {
    if ($line -match '^### Linux') { $inLinux = $true }
    elseif ($inLinux -and $line -match '^### ') { $inLinux = $false }
    if ($inLinux) { $linuxLines.Add($line) }
}
$linuxSection = $linuxLines -join "`n"

Assert-Contains 'bootstrap-linux-doc: playbook has a Linux (apt-based) section heading' `
    $linuxSection '### Linux (apt-based)'

# --- apt-get update in the Linux section ---
Assert-Contains 'bootstrap-linux-doc: Linux section contains apt-get update' `
    $linuxSection 'apt-get update'

# --- apt-get install in the Linux section (prerequisite step) ---
Assert-Contains 'bootstrap-linux-doc: Linux section contains apt-get install' `
    $linuxSection 'apt-get install'

# --- clone step in the Linux section ---
Assert-Contains 'bootstrap-linux-doc: Linux section mentions git clone' `
    $linuxSection 'git clone'

# --- bootstrap.sh invocation in the Linux section ---
Assert-Contains 'bootstrap-linux-doc: Linux section references bootstrap.sh' `
    $linuxSection 'bootstrap.sh'

# --- validate.sh step in the Linux section ---
Assert-Contains 'bootstrap-linux-doc: Linux section references validate.sh' `
    $linuxSection 'validate.sh'

# --- spine verification in the Linux section ---
Assert-Contains 'bootstrap-linux-doc: Linux section references session-agent spine verification' `
    $linuxSection 'session-agent'

# --- apt is documented as a pre-step, not implied as run by bootstrap.sh ---
# The playbook must NOT claim bootstrap.sh runs apt automatically.
Assert-NotContains 'bootstrap-linux-doc: Linux section does not claim bootstrap.sh invokes apt automatically' `
    $linuxSection 'bootstrap.sh falls back to apt'

# --- No real local home paths baked in ---
# Runtime-construct the sentinel from non-matching halves so the test source
# does not self-trip validate.sh's absolute-path scanner. (feedback_self_tripping_test_source)
$linuxDocPiiPrefix = '/Use'
$linuxDocPiiSuffix = 'rs/'
$linuxDocPii = $linuxDocPiiPrefix + $linuxDocPiiSuffix
Assert-NotContains 'bootstrap-linux-doc: playbook contains no macOS home paths' `
    $pb $linuxDocPii
