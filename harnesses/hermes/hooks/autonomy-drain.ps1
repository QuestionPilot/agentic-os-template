#Requires -Version 7
# Unattended-drain hook (Hermes on_session_end) — Windows twin of
# autonomy-drain.sh. WIRED, DISABLED BY DEFAULT: inert unless the operator
# created <HERMES_HOME>/agentic-os/unattended-drain.enabled (a deliberate,
# separately-recorded enablement act gated on the storage decision's Review
# Trigger). Messaging-gateway surfaces are PROPOSE-ONLY and never drain.

$ErrorActionPreference = 'SilentlyContinue'

$hhome = Split-Path -Parent $PSScriptRoot
if (-not $hhome) {
    $hhome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $HOME '.hermes' }
}
$flag = Join-Path $hhome 'agentic-os' 'unattended-drain.enabled'
$log = Join-Path $hhome 'agentic-os' 'unattended-drain.log'

$inputRaw = [Console]::In.ReadToEnd()

# Default-off: no flag, no action, no trace.
if (-not (Test-Path -LiteralPath $flag)) { exit 0 }

try { $evt = $inputRaw | ConvertFrom-Json } catch { exit 0 }
$sessionId = [string]$evt.session_id
$platform = [string]$evt.extra.platform

$stamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
if ($platform -in @('telegram', 'slack', 'discord', 'whatsapp', 'matrix', 'mattermost')) {
    Add-Content -LiteralPath $log -Value "$stamp skipped session=$sessionId platform=$platform (propose-only surface)"
    exit 0
}

Add-Content -LiteralPath $log -Value "$stamp draining session=$sessionId platform=$platform"
Start-Process -FilePath 'hermes' -ArgumentList @('--cli', '-z',
    "Invoke /closeout to drain the just-ended unattended session $sessionId — session-log write-through only; propose (do not write) any curated-note changes.") `
    -WindowStyle Hidden
exit 0
