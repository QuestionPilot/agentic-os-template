#Requires -Version 7
<#
.SYNOPSIS
    PowerShell twin of self-audit-history.sh — append + read the operator-local
    self-audit score history so the point-in-time scorecard gains a trend view.
   

.DESCRIPTION
    self-audit.sh/.ps1 is a READ-ONLY framework diagnostic; it never writes into
    the agentic-os-template tree. Score history is RUNTIME, PER-OPERATOR state, so it lives
    in an operator-local JSONL store keyed off $env:CLAUDE_CONFIG_DIR — never
    committed to the repo (matching cross-model-out/ and .build-manifest.json,
    which are also operator-local). One record per run, one JSON object per line:
      {"timestamp":"<ISO-8601 UTC>","total":<0-100>,"overall":<0-100>,
       "pillars":{"<key>":<0-20>,...}}
    `total` and `overall` carry the same value; both are written so either name
    resolves downstream.

    Usage:
      self-audit.ps1 -Json | pwsh -File scripts/self-audit-history.ps1 append [<store>]
      pwsh -File scripts/self-audit-history.ps1 trend [<store>] [<N>]

    Subcommands:
      append [<store>]      Read a self-audit --json scorecard from stdin, append
                            one record to <store>. Exits non-zero on malformed
                            JSON.
      trend  [<store>] [N]  Print a per-pillar trend table over the last N
                            records (default 5), with newest-vs-prior delta.

    <store> defaults to "$env:CLAUDE_CONFIG_DIR/self-audit-history.jsonl".

.NOTES
    Per [[reference_ps_port_traps]] trap #3 + [[feedback_powershell_set_content_crlf]]:
    file output uses [System.IO.File]::AppendAllText / WriteAllText with no-BOM
    UTF-8 + explicit "`n" so bash<->pwsh byte-parity holds. Table output is built
    line-by-line and joined with "`n" (no Set-Content / Out-File).

    Read-only w.r.t. the framework tree: the only file written is the
    operator-local <store>, which the caller chooses.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Sub = '',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
# Pin stdout to BOM-less UTF-8. Invoked directly (`pwsh -File` from the bash
# suite or an operator shell) this process inherits the console's legacy
# codepage (ibm437 observed live), which best-fits "Δ" / "—" in the trend
# header into mangled bytes and breaks bash<->pwsh byte-parity. tests/run.ps1
# pins its own console, but a direct child invocation gets no such pin.
[Console]::OutputEncoding = $utf8NoBom

function Write-Out {
    # Emit text with LF-only newlines (no trailing-CR drift on Windows).
    param([string]$Text)
    [Console]::Out.Write(($Text -replace "`r`n", "`n"))
}

function Die {
    param([string]$Msg, [int]$Code = 1)
    [Console]::Error.WriteLine("self-audit-history.ps1: $Msg")
    exit $Code
}

if ([string]::IsNullOrEmpty($Sub)) {
    [Console]::Error.WriteLine('self-audit-history.ps1: subcommand required (append | trend)')
    exit 2
}

# Resolve the store path: explicit arg wins, else $env:CLAUDE_CONFIG_DIR default.
function Resolve-Store {
    param([string]$Explicit)
    if (-not [string]::IsNullOrEmpty($Explicit)) { return $Explicit }
    if (-not [string]::IsNullOrEmpty($env:CLAUDE_CONFIG_DIR)) {
        return (Join-Path $env:CLAUDE_CONFIG_DIR 'self-audit-history.jsonl')
    }
    return $null
}

# Format a signed delta the same way the bash twin does ("+N" / "-N" / "0").
function Format-Delta {
    param([int]$Latest, [int]$Prior)
    $d = $Latest - $Prior
    if ($d -gt 0) { return "+$d" }
    elseif ($d -lt 0) { return "$d" }
    else { return '0' }
}

switch -CaseSensitive ($Sub) {

    'append' {
        $store = Resolve-Store ($(if ($Rest.Count -ge 1) { $Rest[0] } else { '' }))
        if ($null -eq $store) { Die 'no store path: pass one as an argument or set CLAUDE_CONFIG_DIR' 2 }

        # Read the full --json scorecard from stdin.
        $scorecard = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($scorecard)) { Die 'no scorecard on stdin (pipe self-audit.ps1 -Json)' 2 }

        try {
            $obj = $scorecard | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Die 'stdin is not a valid self-audit --json scorecard' 4
        }
        if ($null -eq $obj.total -or ($obj.total -isnot [int] -and $obj.total -isnot [long] -and $obj.total -isnot [double])) {
            Die 'stdin is not a valid self-audit --json scorecard' 4
        }

        # Project pillars{key:{score}} -> {key:score}, preserving key order.
        $pillarsOut = [ordered]@{}
        foreach ($prop in $obj.pillars.PSObject.Properties) {
            $pillarsOut[$prop.Name] = [int]$prop.Value.score
        }

        $ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $record = [ordered]@{
            timestamp = $ts
            total     = [int]$obj.total
            overall   = [int]$obj.total
            pillars   = $pillarsOut
        }
        # Compact single-line JSON (-Compress) so each record is exactly one line.
        $line = ($record | ConvertTo-Json -Depth 6 -Compress)

        $storeDir = Split-Path $store -Parent
        if (-not [string]::IsNullOrEmpty($storeDir) -and -not (Test-Path -LiteralPath $storeDir -PathType Container)) {
            New-Item -ItemType Directory -Path $storeDir -Force | Out-Null
        }
        # No-BOM UTF-8 append, LF terminator.
        [System.IO.File]::AppendAllText($store, $line + "`n", $utf8NoBom)
        [Console]::Error.WriteLine("self-audit-history: appended record to $store")
        exit 0
    }

    'trend' {
        $store = Resolve-Store ($(if ($Rest.Count -ge 1) { $Rest[0] } else { '' }))
        if ($null -eq $store) { Die 'no store path: pass one as an argument or set CLAUDE_CONFIG_DIR' 2 }
        $n = if ($Rest.Count -ge 2) { $Rest[1] } else { '5' }
        if ($n -notmatch '^[0-9]+$') { Die "N must be a positive integer, got: $n" 2 }
        $n = [int]$n
        if ($n -lt 1) { Die 'N must be >= 1' 2 }

        if (-not (Test-Path -LiteralPath $store -PathType Leaf)) {
            $out = @(
                '# self-audit trend — no history yet'
                ''
                "No history store at $store."
                'Run a self-audit and append it first:'
                '  bash scripts/self-audit.sh --json | bash scripts/self-audit-history.sh append'
            ) -join "`n"
            Write-Out ($out + "`n")
            exit 0
        }

        # Last N non-blank records, oldest->newest.
        $allLines = @([System.IO.File]::ReadAllLines($store) | Where-Object { $_ -match '\S' })
        if ($allLines.Count -eq 0) {
            $out = @(
                '# self-audit trend — store is empty'
                ''
                "No records in $store yet."
            ) -join "`n"
            Write-Out ($out + "`n")
            exit 0
        }
        $take = [Math]::Min($n, $allLines.Count)
        $recordLines = @($allLines | Select-Object -Last $take)
        # -AsHashtable keeps JSON primitives as their literal types: the
        # timestamp stays the raw ISO-8601 STRING rather than being coerced to a
        # [DateTime] (which would re-render in the host's culture and break
        # byte-parity with the bash twin, which never reformats the stamp).
        $records = @($recordLines | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $count = $records.Count

        # Pillar order: ORDINAL (Unicode codepoint) sort, matching the bash
        # twin's `jq 'keys'`. jq sorts object keys by codepoint, NOT by culture
        # collation — InvariantCulture collation differs from codepoint order
        # for case + punctuation (e.g. jq orders "Beta","Zebra","_under","apple";
        # collation orders "_under","apple","Beta","Zebra"). Today's keys are all
        # lowercase ASCII + hyphen so the two happen to agree, but a future
        # mixed-case/punctuation key would break byte-parity under collation.
        # StringComparer.Ordinal reproduces jq's codepoint order exactly.
        $pkeys = @([System.Linq.Enumerable]::OrderBy(
            [string[]]@($records[-1].pillars.Keys),
            [Func[string, string]] { param($k) $k },
            [System.StringComparer]::Ordinal))
        # ConvertFrom-Json auto-detects ISO-8601 strings and parses them to
        # [DateTime] (even with -AsHashtable, before the 7.5 -DateKind option).
        # The bash twin never reformats the stamp, so a DateTime would render in
        # the host culture and break byte-parity. Render any DateTime back to the
        # canonical UTC ISO-8601 string; pass real strings through untouched.
        $stamps = @($records | ForEach-Object {
            $t = $_['timestamp']
            if ($t -is [datetime]) { ([datetime]$t).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
            else { [string]$t }
        })

        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add("# self-audit trend — last $count run(s)")
        [void]$lines.Add('')
        [void]$lines.Add('| Pillar | ' + ($stamps -join ' | ') + ' | Δ (latest) |')
        [void]$lines.Add('| --- |' + (($stamps | ForEach-Object { ' --- |' }) -join '') + ' --- |')

        foreach ($p in $pkeys) {
            $cells = @($records | ForEach-Object { [string][int]$_['pillars'][$p] })
            $delta = if ($count -ge 2) { Format-Delta ([int]$records[-1]['pillars'][$p]) ([int]$records[-2]['pillars'][$p]) } else { 'n/a' }
            [void]$lines.Add('| ' + $p + ' | ' + ($cells -join ' | ') + ' | ' + $delta + ' |')
        }
        $totals = @($records | ForEach-Object { [string][int]$_['total'] })
        $tdelta = if ($count -ge 2) { Format-Delta ([int]$records[-1]['total']) ([int]$records[-2]['total']) } else { 'n/a' }
        [void]$lines.Add('| **Total** | ' + ($totals -join ' | ') + ' | ' + $tdelta + ' |')

        Write-Out (($lines -join "`n") + "`n")
        exit 0
    }

    '-h'     { Write-Out ((Get-Help $PSCommandPath | Out-String) + "`n"); exit 0 }
    '--help' { Write-Out ((Get-Help $PSCommandPath | Out-String) + "`n"); exit 0 }

    default {
        Die "unknown subcommand: $Sub (expected: append | trend)" 2
    }
}
