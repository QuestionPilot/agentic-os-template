# Stuck-detector hook — PowerShell twin of stuck-detector.sh (behavioral parity).
# Claude Code PostToolUseFailure + PostToolUse events, matcher Bash. See the
# bash twin's header for the full design rationale (event routing verified live
# on v2.1.209, minimal normalization, one-shot fire per hash per session,
# per-session locking, emit-only-after-persist, fail-open posture). This file
# mirrors that contract exactly; the user-facing reminder string must stay
# IDENTICAL between twins (count-string drift trap).
#
# stdin:  PostToolUseFailure / PostToolUse hook event JSON
# stdout: when firing, JSON with hookSpecificOutput.additionalContext
# exit:   always 0 (surfacing hook — fails OPEN)
#
# Kill switch: CLAUDE_SKIP_STUCK_DETECTOR=1

$ErrorActionPreference = 'SilentlyContinue'
$StreakThreshold = 3

if ($env:CLAUDE_SKIP_STUCK_DETECTOR -eq '1') { exit 0 }

$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }
if (-not $payload) { exit 0 }

$hookEvent = [string]$payload.hook_event_name
$toolName  = [string]$payload.tool_name
$sessionId = [string]$payload.session_id

if ($toolName -ne 'Bash') { exit 0 }
if ($hookEvent -ne 'PostToolUse' -and $hookEvent -ne 'PostToolUseFailure') { exit 0 }

# Session id keys the state file path — sanitize to a path-safe alphabet
# (superset of UUIDs), same contract as the session-agent gate marker.
if ($sessionId -match '^\s*([A-Za-z0-9-]+)\s*$') {
    $sessionId = $Matches[1]
} else {
    exit 0
}

$installDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $installDir) { exit 0 }
$stateDir  = Join-Path $installDir 'agentic-os'
$stateFile = Join-Path $stateDir ("stuck-" + $sessionId)

# Cheap path: a success with no recorded state has nothing to reset.
if ($hookEvent -eq 'PostToolUse' -and -not (Test-Path -LiteralPath $stateFile -PathType Leaf)) { exit 0 }

# Failure qualification (see bash twin header): interrupts never count, and
# only a command that RAN and failed ("Exit code N...") counts — permission
# denials / harness-level errors carry different error text.
if ($hookEvent -eq 'PostToolUseFailure') {
    if ($payload.is_interrupt -eq $true) { exit 0 }
    $err = [string]$payload.error
    if (-not $err.StartsWith('Exit code')) { exit 0 }
}

$command = [string]$payload.tool_input.command
if (-not $command) { exit 0 }

# Normalize: collapse every whitespace run to one space, trim, cap at 2000 chars.
$norm = ($command -replace '\s+', ' ').Trim()
if ($norm.Length -gt 2000) { $norm = $norm.Substring(0, 2000) }

# SHA256 over the normalized command (hex, lowercase — matches the bash twin's
# sha256 providers; state never crosses machines, so the algorithm only needs
# to be stable within one host).
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($norm)
    $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
} finally {
    $sha.Dispose()
}
if (-not $hash) { exit 0 }

if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) { exit 0 }

# Reap stale per-session state (old sessions); never fails the hook.
Get-ChildItem -LiteralPath $stateDir -Filter 'stuck-*' -File |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

# Per-session lock (mirrors the bash twin): serialize the read-modify-write
# against concurrent hook invocations. Contention skips the event after
# bounded retries — losing one count under-fires, the safe direction. A lock
# left by a crashed holder is stolen once it is over a minute old.
$lockDir = $stateFile + '.lock'
$locked = $false
foreach ($attempt in 1..3) {
    try {
        New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop | Out-Null
        $locked = $true
        break
    } catch {
        $lockInfo = Get-Item -LiteralPath $lockDir -ErrorAction SilentlyContinue
        if ($lockInfo -and $lockInfo.LastWriteTime -lt (Get-Date).AddMinutes(-1)) {
            Remove-Item -LiteralPath $lockDir -Force -Recurse -ErrorAction SilentlyContinue
            continue
        }
        Start-Sleep -Milliseconds 200
    }
}
if (-not $locked) { exit 0 }

try {
    # Read this hash's record. State lines: "<hash> <count> <fired>".
    $count = 0; $fired = 0; $haveRec = $false
    $lines = @()
    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $stateFile -ErrorAction SilentlyContinue)
        # Pathological-size guard: >500 distinct FAILING hashes in one session
        # (successes never create records) — drop rather than scan forever.
        if ($lines.Count -gt 500) {
            Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
            $lines = @()
        } else {
            foreach ($line in $lines) {
                $parts = $line -split ' '
                if ($parts.Count -ge 3 -and $parts[0] -eq $hash) {
                    $haveRec = $true
                    if ($parts[1] -match '^[0-9]+$') { $count = [int]$parts[1] }
                    if ($parts[2] -match '^[01]$')   { $fired = [int]$parts[2] }
                    break
                }
            }
        }
    }

    if ($hookEvent -eq 'PostToolUse') {
        # Success: only an existing streak is affected — never create a record
        # for an unseen hash, and a record that fully resets to "0 0" is
        # dropped (fired stays sticky as "0 1"). Mirrors the bash twin.
        if (-not $haveRec) { exit 0 }
        $count = 0
    } else {
        $count = $count + 1
    }

    $emit = $false
    if ($hookEvent -eq 'PostToolUseFailure' -and $count -ge $StreakThreshold -and $fired -eq 0) {
        $emit = $true
        $fired = 1
    }

    # Rewrite the record (temp + move keeps the file whole under interruption).
    # Only well-formed records are preserved — blank/malformed lines are
    # filtered so corruption cannot accumulate toward the size guard.
    $kept = @($lines | Where-Object { $_ -match '^[0-9a-f]{64} [0-9]+ [01]$' -and ($_ -split ' ')[0] -ne $hash })
    if ($count -gt 0 -or $fired -eq 1) {
        $kept += ('{0} {1} {2}' -f $hash, $count, $fired)
    }
    $persisted = $false
    $tmp = $stateFile + '.tmp.' + $PID
    try {
        # BOM-less UTF-8 with LF endings on every PowerShell version (panel
        # finding: Set-Content -Encoding utf8 writes a BOM on Windows
        # PowerShell 5.1; WriteAllText with an explicit encoding never does).
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $body = if ($kept.Count -gt 0) { ($kept -join "`n") + "`n" } else { '' }
        [System.IO.File]::WriteAllText($tmp, $body, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $stateFile -Force -ErrorAction Stop
        $persisted = $true
    } catch {
        $persisted = $false
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

    # Emit ONLY after the fired flag is durably persisted (mirrors the bash
    # twin — a failed write must not become repeated alarm injection).
    if ($emit -and $persisted) {
        # Twin-parity contract: identical to the bash twin's reminder string.
        # Snippet sanitized to backtick-free printable ASCII in both twins.
        $snip = ($norm -replace '`', '') -replace '[^\x20-\x7E]', ''
        if ($snip.Length -gt 120) { $snip = $snip.Substring(0, 120) }
        $msg = 'Stuck-detector: this Bash command has now failed ' + $StreakThreshold +
            ' times this session with no intervening success: `' + $snip +
            '`. Rescue rule: stop retrying ' + [char]0x2014 + ' @@RESCUE_INVOCATION@@ (rescue lane: hand the failure to a different model family) before attempting retry 4. Kill switch: env CLAUDE_SKIP_STUCK_DETECTOR=1.'
        $out = @{
            hookSpecificOutput = [ordered]@{
                hookEventName     = 'PostToolUseFailure'
                additionalContext = $msg
            }
        } | ConvertTo-Json -Compress -Depth 4
        if ($out) { [Console]::Out.WriteLine($out) }
    }
} finally {
    Remove-Item -LiteralPath $lockDir -Force -Recurse -ErrorAction SilentlyContinue
}

exit 0
