#Requires -Version 7
<#
.SYNOPSIS
    PowerShell twin of check-state-currentness.sh — advisory SEMANTIC-currentness
    signal.

.DESCRIPTION
    Windows-native port of scripts/check-state-currentness.sh.

    Answers the question the mechanical audit cannot: "is what the durable
    layers SAY about tracker state still TRUE?" Every other checker in scripts/
    proves a structural property of the filesystem — an index resolves, a
    manifest is fresh, a heading exists. All of them can pass while a memory
    note or a vault project note confidently asserts an issue state that the
    tracker changed hours ago. That failure mode is invisible to a structural
    gate and expensive in practice: an agent orients off the stale claim and
    acts on it.

    Two finding classes:

      1. CLAIM MISMATCH. A note asserts a state for a tracker issue
         (`<PREFIX>-<N>`) that disagrees with the issue's live state. Each
         finding is sub-classed by whether the claim carried an explicit
         as-of date:
           stale-claim     — an UNDATED present-tense assertion. The real
                             defect: the note reads as current and is wrong.
           stale-snapshot  — a claim under an explicitly dated heading/bullet
                             ("Open issues as of 2026-08-04"). Aging is
                             expected; the finding says the snapshot needs a
                             refresh, not that the note lied. Reported
                             separately so a refresh backlog never masquerades
                             as a correctness bug.
         History LOGS are not claims at all and are skipped outright — a
         `## State Deltas` bullet records what was true on a past date and
         stays correct as written forever.

      2. PROJECT/CHILD CONTRADICTION. A project's own status disagrees with
         the states of its child issues:
           project-closed-with-open-children   Completed/Canceled, >=1 open child
           project-idle-with-active-children   Backlog/Planned, >=1 In Progress child
           project-active-with-no-open-children In Progress, 0 open children

    ADVISORY, WARN-only — never a gate, and it never edits memory, vault
    notes, or tracker state. Deliberately NOT wired into `make verify`: CI has
    no tracker token, and tracker state is workspace state, not repo state.
    `self-audit` invokes it and reports the findings in a section separate
    from the mechanical pillar scores, so a semantically stale system can no
    longer present as an unqualified 100/100.

    FALSE POSITIVES ARE THE ENEMY. This is a heuristic text scanner, not a
    parser, and it is deliberately tuned to under-report: a missed stale claim
    costs one audit cycle, a false accusation costs operator trust in the
    whole signal. Claim extraction therefore only fires on a `<PREFIX>-<N>`
    token that owns a state word by proximity, skips fenced code, and skips
    history sections entirely. The restraint rules below are ported
    rule-for-rule from the bash twin's awk scanner; loosening either side
    without the other is twin divergence.

.PARAMETER MemoryDir
    A memory store to scan (repeatable via --memory-dir). Default: resolved
    from local.env CLAUDE_CONFIG_DIR (its projects/*/memory stores) unless
    -Isolated.

.PARAMETER VaultDir
    Durable-knowledge vault root. Active project notes under 01-Projects/ are
    scanned. Default: local.env OBSIDIAN_VAULT_PATH unless -Isolated.

.PARAMETER IssuePrefix
    Tracker issue prefix (e.g. the team key). Default: local.env
    TRACKER_ISSUE_PREFIX. Without one, claim scanning cannot run and the check
    skips.

    Named `IssuePrefix`, not `Prefix`, on purpose: PowerShell's binder resolves
    a bare `--prefix` token to a parameter named `Prefix`, so the POSIX flag
    would be consumed natively and a REPEATED `--prefix` (which the bash twin
    accepts, last-wins) would hard-error "specified more than once" instead of
    reaching the parser below. `IssuePrefix` is not prefix-matched by
    `--prefix`, so the flag falls through to $Rest where the twin's semantics
    are implemented. Same reasoning for IssueLimit vs `--limit`.

.PARAMETER IssueLimit
    Max issues pulled in the bulk state-map call (default 250). A payload
    that comes back AT the limit is treated as
    possibly truncated: unmatched identifiers fall back to per-issue reads
    rather than being silently reported as unknown.

.PARAMETER MaxReads
    Cap on per-issue/per-project follow-up read calls (default 40;
    0 = bulk-list evidence only). Must be non-negative in this native form
    too — a negative value exits 2 like any other bad argument.

.PARAMETER NoProjects
    Skip finding class 2 (claim scanning only).

.PARAMETER List
    Machine mode: one TSV finding per line, for self-audit.

.PARAMETER Isolated
    No local.env / ambient-env fallbacks (tests).

.NOTES
    --list record shape (tab-separated, stable field order):
      claim<TAB>class<TAB>identifier<TAB>stored<TAB>live<TAB>observed_at<TAB>file:line
      project<TAB>class<TAB>name<TAB>status<TAB>open_children<TAB>active_children
    `observed_at` is `-` when the claim carried no date.

    Exit codes (BOTH modes), parity with the bash twin:
      0  clean — no mismatch found among the evidence that could be checked
      1  findings — at least one mismatch or contradiction (advisory WARN)
      2  skip — could not determine (no linear CLI / prefix, bulk call failed,
                unparseable payload, no sources to scan, bad argument).
                Callers preserve their own score; the reason is named on
                STDERR in BOTH modes as `SKIP <reason>` so the skip is never
                anonymous.

    Requires the schpet/linear-cli `linear` binary (linear/linear-setup.md
    §3.2). Override the binary with $env:LINEAR_CLI_BIN — the hermetic tests
    inject a stub .ps1 that serves fixture JSON, so this check is testable
    without live credentials.

    The bash twin's `jq`/`awk` skip cases have no PS analogue — this port
    parses with ConvertFrom-Json and scans with .NET regex — so those two
    skip paths are absent by construction, not by omission.

    POSIX-style --memory-dir / --vault-dir / --prefix / --limit / --max-reads /
    --no-projects / --list / --isolated flags pass through $Rest so
    bash-trained operators get muscle-memory parity (mirrors
    check-linear-hygiene.ps1's parser). `--list` and `--isolated` DO
    prefix-match their native switches and bind there; that is harmless
    (identical effect), unlike the value-taking flags above.
#>

# PositionalBinding=$false: without it the leading `[string[]]$MemoryDir` would
# swallow the first bare `--flag` token positionally before $Rest ever sees it,
# and the POSIX parser below would never run.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]]$MemoryDir = @(),
    [string]$VaultDir = '',
    [string]$IssuePrefix = '',
    [int]$IssueLimit = 250,
    [int]$MaxReads = 40,
    [switch]$NoProjects,
    [switch]$List,
    [switch]$Isolated,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$global:LASTEXITCODE = 0

$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

# --- argv ---------------------------------------------------------------------
# POSIX-style flag pass-through (mirror the bash twin's `while [ $# -gt 0 ]`).
# Every value-taking flag guards its argument BEFORE consuming two slots — a
# value-less flag would otherwise re-loop on itself forever.
$memDirs = [System.Collections.Generic.List[string]]::new()
foreach ($m in $MemoryDir) { if ($m) { $memDirs.Add($m) } }

$i = 0
while ($i -lt $Rest.Count) {
    switch -CaseSensitive ($Rest[$i]) {
        '--memory-dir' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('check-state-currentness: --memory-dir needs a path')
                exit 2
            }
            $memDirs.Add($Rest[$i + 1]); $i += 2
        }
        '--vault-dir' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('check-state-currentness: --vault-dir needs a path')
                exit 2
            }
            $VaultDir = $Rest[$i + 1]; $i += 2
        }
        '--prefix' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('check-state-currentness: --prefix needs a value')
                exit 2
            }
            $IssuePrefix = $Rest[$i + 1]; $i += 2
        }
        '--limit' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('check-state-currentness: --limit needs a value')
                exit 2
            }
            $lv = $Rest[$i + 1]
            if ($lv -notmatch '^\d+$') {
                [Console]::Error.WriteLine('check-state-currentness: --limit must be a non-negative integer')
                exit 2
            }
            $IssueLimit = [int]$lv; $i += 2
        }
        '--max-reads' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('check-state-currentness: --max-reads needs a value')
                exit 2
            }
            $rv = $Rest[$i + 1]
            if ($rv -notmatch '^\d+$') {
                [Console]::Error.WriteLine('check-state-currentness: --max-reads must be a non-negative integer')
                exit 2
            }
            $MaxReads = [int]$rv; $i += 2
        }
        '--no-projects' { $NoProjects = [switch]$true; $i += 1 }
        '--list'        { $List = [switch]$true; $i += 1 }
        '--isolated'    { $Isolated = [switch]$true; $i += 1 }
        default {
            [Console]::Error.WriteLine("check-state-currentness: unknown argument: $($Rest[$i])")
            exit 2
        }
    }
}

# The native -Limit / -MaxReads forms bypass the $Rest regex — validate them too,
# or a negative cap silently changes the evidence base and returns a false PASS.
if ($IssueLimit -lt 0) {
    [Console]::Error.WriteLine('check-state-currentness: --limit must be a non-negative integer')
    exit 2
}
if ($MaxReads -lt 0) {
    [Console]::Error.WriteLine('check-state-currentness: --max-reads must be a non-negative integer')
    exit 2
}

# skip <reason> — emit the reason and exit 2 (indeterminate).
#
# The reason goes to STDERR in BOTH modes, so `--list` stdout stays pure TSV
# while the caller can still report a NAMED skip rather than a bare exit 2. That
# naming is the point: "linear CLI not found" and "no comparable evidence found"
# are different operator actions, and an unnamed skip collapses them.
function Skip-Currentness([string]$reason) {
    [Console]::Error.WriteLine("SKIP $reason")
    exit 2
}

# Get-LocalEnvValue — read ONE key from local.env WITHOUT importing the whole
# file. Verbatim-equivalent to self-audit.ps1's Get-SaLocalEnvValue and the bash
# twin's _localenv_get: importing would push EVERY key (incl. a hostile PATH=)
# into the process env, and this script resolves the linear CLI via Get-Command AFTER
# this point. Reads config as DATA only. Mirrors bash sourcing semantics for a
# key: a later assignment of the same key wins; one matching surrounding quote
# pair is stripped; an unquoted backslash-escape collapses (\<c> -> <c>).
function Get-LocalEnvValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $pat = '^(?:export\s+)?' + [regex]::Escape($Key) + '=(.*)$'
    $result = ''
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $t = $line.Trim()
        if ($t.Length -eq 0 -or $t.StartsWith('#', [StringComparison]::Ordinal)) { continue }
        if ($t -match $pat) {
            $v = $matches[1]
            if ($v.Length -ge 2) {
                $f = $v[0]; $l = $v[$v.Length - 1]
                if (($f -ceq '"' -and $l -ceq '"') -or ($f -ceq "'" -and $l -ceq "'")) {
                    $v = $v.Substring(1, $v.Length - 2)
                } elseif ($v.Contains([char]'\')) {
                    $v = [regex]::Replace($v, '\\(.)', '$1')
                }
            }
            $result = $v  # last assignment wins
        }
    }
    return $result
}

# --- source + prefix resolution (flag > local.env > ambient env) -------------
if (-not $Isolated) {
    $localEnv = Join-Path $RepoRoot 'local.env'
    if ($IssuePrefix -eq '') {
        $IssuePrefix = Get-LocalEnvValue -Path $localEnv -Key 'TRACKER_ISSUE_PREFIX'
        if ($IssuePrefix -eq '' -and $env:TRACKER_ISSUE_PREFIX) { $IssuePrefix = $env:TRACKER_ISSUE_PREFIX }
    }
    if ($VaultDir -eq '') {
        $VaultDir = Get-LocalEnvValue -Path $localEnv -Key 'OBSIDIAN_VAULT_PATH'
        if ($VaultDir -eq '' -and $env:OBSIDIAN_VAULT_PATH) { $VaultDir = $env:OBSIDIAN_VAULT_PATH }
    }
    if ($memDirs.Count -eq 0) {
        $cfg = Get-LocalEnvValue -Path $localEnv -Key 'CLAUDE_CONFIG_DIR'
        if ($cfg -eq '' -and $env:CLAUDE_CONFIG_DIR) { $cfg = $env:CLAUDE_CONFIG_DIR }
        if ($cfg -ne '') {
            $projRoot = Join-Path $cfg 'projects'
            if (Test-Path -LiteralPath $projRoot -PathType Container) {
                # Every per-project auto-memory store under the harness config
                # dir. A store with no notes is harmless — the scanner just finds
                # no claims.
                $found = @(Get-ChildItem -LiteralPath $projRoot -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        Get-ChildItem -LiteralPath $_.FullName -Directory -Filter 'memory' -ErrorAction SilentlyContinue
                    } | Sort-Object FullName)
                foreach ($d in $found) { $memDirs.Add($d.FullName) }
            }
        }
    }
}

# Strip one trailing slash from directory inputs so joined paths never double up.
$VaultDir = $VaultDir -replace '[/\\]$', ''

if ($IssuePrefix -eq '') {
    Skip-Currentness 'no tracker issue prefix (--prefix, or TRACKER_ISSUE_PREFIX in local.env) — claim scanning cannot run'
}
if ($IssuePrefix -notmatch '^[A-Za-z0-9_]+$') {
    Skip-Currentness "tracker prefix '$IssuePrefix' is not alphanumeric — refusing to build a scan pattern from it"
}

# Binary seam: $env:LINEAR_CLI_BIN, default `linear`.
$linearCli = if ($env:LINEAR_CLI_BIN) { $env:LINEAR_CLI_BIN }
             else { 'linear' }
if (-not (Get-Command $linearCli -ErrorAction SilentlyContinue)) {
    Skip-Currentness 'linear CLI not found ($env:LINEAR_CLI_BIN or PATH) — see linear/linear-setup.md §3.2'
}

# --- collect the files to scan ------------------------------------------------
# Memory stores: every note. Vault: active project notes only (frontmatter
# `status: active`) — an archived or completed project note is a historical
# record by definition and its claims are not present-tense assertions.

# Test-VaultActive — `status: active` must appear in the FRONTMATTER block, not
# anywhere in the body, so only the leading block is inspected (mirrors the bash
# twin's awk: count `---` fences, bail at the second).
function Test-VaultActive([string]$path) {
    try { $lines = [System.IO.File]::ReadAllLines($path) } catch { return $false }
    $n = 0
    foreach ($l in $lines) {
        if ($l -cmatch '^---\s*$') {
            $n++
            if ($n -eq 2) { break }
            continue
        }
        if ($n -eq 1 -and $l.ToLowerInvariant() -cmatch '^status:\s*active\s*$') { return $true }
    }
    return $false
}

$scanFiles = [System.Collections.Generic.List[string]]::new()
foreach ($md in $memDirs) {
    if (-not (Test-Path -LiteralPath $md -PathType Container)) { continue }
    $files = @(Get-ChildItem -LiteralPath $md -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object FullName)
    foreach ($f in $files) { $scanFiles.Add($f.FullName) }
}
if ($VaultDir -ne '') {
    $projDir = Join-Path $VaultDir '01-Projects'
    if (Test-Path -LiteralPath $projDir -PathType Container) {
        $vfiles = @(Get-ChildItem -LiteralPath $projDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object FullName)
        foreach ($f in $vfiles) {
            if (Test-VaultActive $f.FullName) { $scanFiles.Add($f.FullName) }
        }
    }
}

if ($scanFiles.Count -eq 0) {
    Skip-Currentness 'no memory or vault sources to scan (--memory-dir / --vault-dir)'
}

# --- live state map -----------------------------------------------------------
# ONE bulk call carries every issue's identifier + state, so the common case
# costs a single request no matter how many claims are scanned.

# Get-Field <obj> <name> — flatten a payload field to a display string: '' for
# missing/null, the `name` property for object-shaped fields (schpet/linear-cli
# returns nested objects — state {name,type,...}, status {name,type,...} — which
# this flattens to the flat strings the downstream logic expects; parity with
# the bash twin's jq s() helper).
function Get-Field($obj, [string]$name) {
    if ($null -eq $obj) { return '' }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    $v = $p.Value
    if ($v -is [PSCustomObject]) {
        $np = $v.PSObject.Properties['name']
        if ($null -ne $np -and $null -ne $np.Value) { return "$($np.Value)" }
        return "$v"
    }
    return "$v"
}

# Invoke-LinearCli — run the tracker CLI and return @{ Ok; Raw }. $ErrorActionPreference
# is 'Stop', so a binary that fails to EXECUTE (wrong arch, not executable, missing
# loader) throws a terminating error rather than setting $LASTEXITCODE — which would
# crash out with PowerShell's own exit code and be read by self-audit as "findings"
# instead of a skip. Every call site goes through here so the fail-soft contract
# holds for exec failures too, not just non-zero exits.
function Invoke-LinearCli([string[]]$CliArgs) {
    try {
        $raw = (& $linearCli @CliArgs 2>$null | Out-String)
        return @{ Ok = ($LASTEXITCODE -eq 0); Raw = $raw }
    } catch {
        return @{ Ok = $false; Raw = '' }
    }
}

# ConvertTo-NodesArray — schpet/linear-cli list payloads are OBJECTS
# {nodes:[...]}; unwrap .nodes. A bare array is accepted too; any other shape
# returns $null (= the call failed). Parity with the bash twin's jq unwrap.
function ConvertTo-NodesArray([string]$raw) {
    $t = $raw.TrimStart()
    if ($t.StartsWith('[')) {
        try { return , @($raw | ConvertFrom-Json) } catch { return $null }
    }
    if ($t.StartsWith('{')) {
        $obj = $null
        try { $obj = $raw | ConvertFrom-Json } catch { return $null }
        if ($null -eq $obj) { return $null }
        $np = $obj.PSObject.Properties['nodes']
        if ($null -ne $np -and $np.Value -is [System.Array]) { return , @($np.Value) }
    }
    return $null
}

# schpet/linear-cli returns ALL states (incl. Done/Canceled) by DEFAULT — there
# is no --show-done analogue and none is needed; do NOT add open-state filters
# here or the state map loses exactly the closed issues stale claims point at.
$bulk = Invoke-LinearCli @('issue', 'query', '--all-teams', '--limit', "$IssueLimit", '--json')
if (-not $bulk.Ok) {
    Skip-Currentness 'linear CLI issue query failed — tracker unreachable or unauthenticated'
}
$bulkIssues = ConvertTo-NodesArray $bulk.Raw
if ($null -eq $bulkIssues) {
    Skip-Currentness 'unexpected issue-query payload (neither {nodes:[...]} nor a JSON array)'
}

$bulkCount = $bulkIssues.Count
# A payload returned AT the ceiling may be truncated — record it so unmatched
# identifiers fall back to a per-issue read instead of being reported unknown.
$possiblyTruncated = ($IssueLimit -gt 0 -and $bulkCount -ge $IssueLimit)

$stateMap = @{}
foreach ($it in $bulkIssues) {
    $ident = Get-Field $it 'identifier'
    if ($ident -eq '') { continue }
    if (-not $stateMap.ContainsKey($ident)) { $stateMap[$ident] = (Get-Field $it 'state') }
}

$script:Reads = 0
# Get-LiveState <ident> — the live state name, or '' when unknown.
function Get-LiveState([string]$ident) {
    if ($stateMap.ContainsKey($ident)) { return $stateMap[$ident] }
    # Not in the bulk payload. If the payload may have been truncated, spend a
    # read; otherwise the identifier genuinely does not exist in the workspace.
    if ($possiblyTruncated -and $script:Reads -lt $MaxReads) {
        $script:Reads++
        # `issue view` returns a single OBJECT (not nodes-wrapped); its state is
        # an object {name,type,...} which Get-Field flattens to the name.
        $r = Invoke-LinearCli @('issue', 'view', $ident, '--json')
        if ($r.Ok) {
            $robj = $null
            try { $robj = $r.Raw | ConvertFrom-Json } catch { $robj = $null }
            if ($null -ne $robj -and $robj -is [PSCustomObject]) { return (Get-Field $robj 'state') }
        }
    }
    return ''
}

# --- claim extraction ---------------------------------------------------------
# PROXIMITY IN PROSE IS NOT A CLAIM. The first cut of this scanner assigned a
# state to any identifier that merely shared a line with a state word, and the
# live corpus buried it in false positives: "mixes effective and cancelled
# actions" made an issue Canceled; a frontmatter headline whose "In Progress"
# described the PROJECT was pinned onto all seven issues it went on to list;
# "Phase 2 exits only after all four child issues are Done" — a future
# CONDITION — read as a present assertion. Every one of those is a state word
# within a few words of an identifier, and every one is noise.
#
# So the scanner recognizes only the shapes a genuine state claim actually takes
# in this corpus, and treats everything else as prose:
#
#   A. TIGHT ADJACENCY (the primary rule). The state word must appear in the
#      window immediately after the identifier, within $AdjMax characters, and
#      everything between the identifier and the state word must be "light" —
#      punctuation, emphasis marks, one parenthetical, or a copula
#      (is/was/are/remains/stays/now/->). A full clause of prose in between
#      means the state word belongs to the sentence, not to the identifier.
#   B. LABEL LEAD. A SHORT state label ending in a colon at the head of the line
#      ("**Done:** ABC-1 …; ABC-2 …") distributes to identifiers that rule A did
#      not resolve. Bounded to $LeadMax characters and required to be
#      substantially just the state word.
#   C. CONJUNCTION INHERITANCE. "ABC-1 and ABC-2 remain Backlog" — an identifier
#      separated from the next only by conjunction/punctuation inherits that
#      neighbor's rule-A state.
#
# Anything unresolved yields NO claim. Under-reporting is the deliberate bias.
$AdjMax = 44        # chars after an identifier that can still carry its state
$LeadMax = 34       # max length of a distributing "State:" label
# A light connector: what may sit between an identifier and its state word. The
# optional ADVERB slot after the copula is load-bearing — without it
# "ABC-1 is now Done" and "ABC-1 is currently Done" (both ordinary phrasings)
# resolve to NO claim, which is a silent miss, not restraint.
$LightPat = '^[\s*_`:;,.=—–>\-]*((((has|have|had)\s+been)|(is|was|are|were|remains|remain|stays|stay|now|moved|set))\s+((now|currently|still|already|again)\s+)?((moved|set|changed|switched|flipped)\s+)?(to\s+)?)?[\s*_`:;,.=—–>\-]*$'
# A state word FOLLOWED BY one of these is not a state assertion but the head of
# a longer phrase: a deadline ("Done by Friday"), a condition ("Done when the
# memo lands"), or a noun compound ("open questions", "done criteria").
$StateAlt = '(in[ _-]progress|in[ _-]review|backlog|to[ _-]?do|cancell?ed|completed|complete|closed|done|still\s+open|remains\s+open|outstanding|unresolved|blocked|open)'
$NotStatePat = '^' + $StateAlt + '\s+(by|until|till|when|after|before|once|unless|if|for|to|as|about|regarding|criteria|questions?|items?|tasks?|work|list|state|status|column|label|issues?)([^a-z]|$)'
# Same token set with the separators already stripped — Rule B compares against
# this AFTER collapsing punctuation out of the label.
$StateBarePat = '^(inprogress|inreview|backlog|todo|cancell?ed|completed|complete|closed|done|stillopen|remainsopen|outstanding|unresolved|blocked|open)$'

# Get-StateAt — canonical state named at the START of a window, else ''.
function Get-StateAt([string]$w) {
    $t = $w.ToLowerInvariant()
    if ($t -cmatch '^in[ _-]progress([^a-z]|$)')                  { return 'In Progress' }
    if ($t -cmatch '^in[ _-]review([^a-z]|$)')                    { return 'In Review' }
    if ($t -cmatch '^backlog([^a-z]|$)')                          { return 'Backlog' }
    if ($t -cmatch '^to[ _-]?do([^a-z]|$)')                       { return 'Todo' }
    if ($t -cmatch '^cancell?ed([^a-z]|$)')                       { return 'Canceled' }
    if ($t -cmatch '^(done|completed|complete|closed)([^a-z]|$)') { return 'Done' }
    if ($t -cmatch '^(still +open|remains +open|open|outstanding|unresolved|blocked)([^a-z]|$)') { return 'OPEN' }
    return ''
}

# Rule A, inner: scan the window for a state word reachable through light text.
function Get-AdjacentStateRaw([string]$w) {
    for ($k = 0; $k -lt $w.Length; $k++) {
        $rest = $w.Substring($k)
        $st = Get-StateAt $rest
        if ($st -eq '') { continue }
        $pre = $w.Substring(0, $k)
        if ($pre -cnotmatch $LightPat) { return '' }   # prose separates it
        # The state word is adjacent — but is it the CLAIM, or the head of a
        # longer phrase? "Done by Friday" / "open questions" are not states.
        if ($rest.ToLowerInvariant() -cmatch $NotStatePat) { return '' }
        return $st
    }
    return ''
}

# Rule A: window truncation + one leading parenthetical stripped
# ("(memory-store consolidation) Done").
function Get-AdjacentState([string]$win) {
    $w = if ($win.Length -gt $AdjMax) { $win.Substring(0, $AdjMax) } else { $win }
    $m = [regex]::Match($w, '^\s*\([^)]*\)')
    if ($m.Success) {
        $st = Get-AdjacentStateRaw $w.Substring($m.Length)
        if ($st -ne '') { return $st }
    }
    return Get-AdjacentStateRaw $w
}

# Rule B: is the lead a short, bare "State:" label?
function Get-LabelState([string]$lead) {
    $t = [regex]::Replace($lead, '^[\s*_>#\-]+', '')
    if ($t.Length -gt $LeadMax) { return '' }
    if ($t -cnotmatch ':[\s*_]*$') { return '' }
    $st = Get-StateAt $t
    if ($st -eq '') { return '' }
    # The label must be the state word and NOTHING else. A length budget is not
    # enough: "Done except:" strips to "Doneexcept" (10 chars) and used to
    # distribute a Done claim across every identifier on the line — the exact
    # inversion of what the label means. Compare against the canonical token set
    # instead of counting characters.
    $bare = [regex]::Replace($t, '[\s*_`:\-]', '')
    if ($bare.ToLowerInvariant() -cnotmatch $StateBarePat) { return '' }
    return $st
}

function Test-Conjunction([string]$w) {
    $t = $w.ToLowerInvariant()
    $t = [regex]::Replace($t, '[\s,;/&*_`()\-]|and|plus|through|thru|then', '')
    return ($t -eq '')
}

function Get-DateIn([string]$s) {
    $m = [regex]::Match($s, '20[0-9][0-9]-[01][0-9]-[0-3][0-9]')
    if ($m.Success) { return $m.Value }
    return ''
}

# Get-Claims <path> <idPattern> — one record per resolved claim:
# @{File; Line; Ident; Claim; Obs}. Obs is '-' when the claim carried no date.
function Get-Claims([string]$path, [string]$idPattern) {
    $out = [System.Collections.Generic.List[object]]::new()
    try { $lines = [System.IO.File]::ReadAllLines($path) } catch { return $out }
    $fence = $false
    $section = ''
    $secdate = ''
    for ($ln = 0; $ln -lt $lines.Count; $ln++) {
        # NBSP -> space. The awk [[:space:]] class is ASCII-only under the C
        # locale while .NET \s matches U+00A0, so an editor-inserted non-breaking
        # space made the twins disagree. Normalizing on BOTH sides fixes the
        # divergence in the direction that keeps the claim visible.
        $line = $lines[$ln].Replace([char]0x00A0, ' ')
        # Fenced code is documentation of syntax, never a state claim.
        if ($line -cmatch '^\s*(```|~~~)') { $fence = -not $fence; continue }
        if ($fence) { continue }
        if ($line -cmatch '^#{1,6}\s') {
            $section = $line.ToLowerInvariant()
            # A heading date only dates the claims beneath it when the heading
            # explicitly frames a snapshot; an incidental date in a title does not.
            $secdate = if ($section -cmatch 'as of|verified|snapshot|state at') { Get-DateIn $line } else { '' }
        }
        # History LOGS record what was true then; they are not present claims.
        if ($section -cmatch 'state[ \-]delta' -or $section -cmatch 'audit log' -or
            $section -cmatch 'changelog' -or $section -cmatch '^#+\s*history') { continue }

        # A DATE-LED line is a log entry, not a present-tense assertion — the
        # `- 2026-08-04 (…): TEAM-1 was In Progress` shape that closeout writes.
        # Section-level history detection only covers it when the writer used a
        # recognized heading; this covers the bullet wherever it lands.
        if ($line -cmatch '^[\s*_>#\-]*20[0-9][0-9]-[01][0-9]-[0-3][0-9]') { continue }

        $ms = @([regex]::Matches($line, $idPattern))
        if ($ms.Count -eq 0) { continue }

        $dflt = Get-LabelState $line.Substring(0, $ms[0].Index)

        $obs = ''
        if ($line -cmatch '(as of|verified|snapshot|confirmed)') { $obs = Get-DateIn $line }
        if ($obs -eq '') { $obs = $secdate }

        for ($ix = 0; $ix -lt $ms.Count; $ix++) {
            $wstart = $ms[$ix].Index + $ms[$ix].Length
            $wend = if ($ix -lt $ms.Count - 1) { $ms[$ix + 1].Index - 1 } else { $line.Length - 1 }
            $win = if ($wend -ge $wstart) { $line.Substring($wstart, $wend - $wstart + 1) } else { '' }
            $st = Get-AdjacentState $win
            if ($st -eq '' -and $dflt -ne '') { $st = $dflt }
            if ($st -eq '' -and $ix -lt $ms.Count - 1 -and (Test-Conjunction $win)) {
                for ($jx = $ix + 1; $jx -lt $ms.Count; $jx++) {
                    $js = $ms[$jx].Index + $ms[$jx].Length
                    $je = if ($jx -lt $ms.Count - 1) { $ms[$jx + 1].Index - 1 } else { $line.Length - 1 }
                    $jw = if ($je -ge $js) { $line.Substring($js, $je - $js + 1) } else { '' }
                    $fs = Get-AdjacentState $jw
                    if ($fs -ne '') { $st = $fs; break }
                    if (-not (Test-Conjunction $jw)) { break }
                }
            }
            if ($st -eq '') { continue }
            $out.Add([pscustomobject]@{
                File  = $path
                Line  = $ln + 1
                Ident = $ms[$ix].Value
                Claim = $st
                Obs   = $(if ($obs -eq '') { '-' } else { $obs })
            })
        }
    }
    return $out
}

# --- compare ------------------------------------------------------------------
# Test-Mismatch — $true when the stored claim contradicts the live state.
function Test-Mismatch([string]$claimed, [string]$live) {
    switch -CaseSensitive ($claimed) {
        'OPEN'     { return ($live -ceq 'Done' -or $live -ceq 'Canceled') }
        'Done'     { return ($live -cne 'Done') }
        'Canceled' { return ($live -cne 'Canceled') }
        default    { return ($live -cne $claimed) }
    }
}

$idPattern = [regex]::Escape($IssuePrefix) + '-[0-9]+'

$findings = 0
$staleClaims = 0
$staleSnapshots = 0
$unknownIdents = ''
$checkedClaims = 0

foreach ($sf in $scanFiles) {
    foreach ($c in (Get-Claims $sf $idPattern)) {
        $live = Get-LiveState $c.Ident
        if ($live -eq '') {
            if (-not $unknownIdents.Contains(" $($c.Ident) ")) {
                $unknownIdents = "$unknownIdents $($c.Ident) "
            }
            continue
        }
        $checkedClaims++
        if (-not (Test-Mismatch $c.Claim $live)) { continue }
        if ($c.Obs -eq '-') {
            $klass = 'stale-claim'; $staleClaims++
        } else {
            $klass = 'stale-snapshot'; $staleSnapshots++
        }
        $findings++
        if ($List) {
            Write-Output ("claim`t{0}`t{1}`t{2}`t{3}`t{4}`t{5}:{6}" -f `
                $klass, $c.Ident, $c.Claim, $live, $c.Obs, $c.File, $c.Line)
        } else {
            Write-Output ('WARN {0} {1}: note says "{2}", tracker says "{3}" (as-of {4}) — {5}:{6}' -f `
                $klass, $c.Ident, $c.Claim, $live, $c.Obs, $c.File, $c.Line)
        }
    }
}

# --- project / child contradictions -------------------------------------------
$projectsChecked = 0
$projectsSkipped = ''
if (-not $NoProjects) {
    $pl = Invoke-LinearCli @('project', 'list', '--json')
    $projects = $null
    if ($pl.Ok) { $projects = ConvertTo-NodesArray $pl.Raw }
    if ($null -eq $projects) {
        $projectsSkipped = ' (projects list failed);'
    } else {
        foreach ($p in $projects) {
            $projId = Get-Field $p 'id'
            if ($projId -eq '') { continue }
            $pname = Get-Field $p 'name'
            if ($pname -eq '') { $pname = '-' }

            # Project state rides the list payload in schpet/linear-cli (each
            # row carries a status object) — no per-project read is needed.
            $pstatus = Get-Field $p 'status'
            if ($pstatus -eq '') { $projectsSkipped = "$projectsSkipped $pname;"; continue }

            if ($script:Reads -ge $MaxReads) { $projectsSkipped = "$projectsSkipped $pname;"; continue }
            $script:Reads++
            # schpet/linear-cli has no hiding default — the open-issue cut must
            # be EXPLICIT via the open state types, so this IS the open-issue cut.
            $pi = Invoke-LinearCli @('issue', 'query', '--all-teams', '--project', $projId,
                '-s', 'triage', '-s', 'backlog', '-s', 'unstarted', '-s', 'started',
                '--limit', "$IssueLimit", '--json')
            $pissues = $null
            if ($pi.Ok) { $pissues = ConvertTo-NodesArray $pi.Raw }
            if ($null -eq $pissues) { $projectsSkipped = "$projectsSkipped $pname;"; continue }
            $openN = $pissues.Count
            # A child list returned AT the ceiling may be truncated, and every
            # class below is a statement about the WHOLE child set — an active
            # child on page two would silently produce "PASS ... projects agree".
            # Unknown evidence is a skip, never a pass.
            if ($IssueLimit -gt 0 -and $openN -ge $IssueLimit) {
                $projectsSkipped = "$projectsSkipped $pname (child list may be truncated at --limit=$IssueLimit);"
                continue
            }
            $activeN = @($pissues | Where-Object {
                $s = Get-Field $_ 'state'
                $s -ceq 'In Progress' -or $s -ceq 'In Review'
            }).Count
            $projectsChecked++

            $pclass = ''
            switch -CaseSensitive ($pstatus) {
                'Completed'   { if ($openN -gt 0) { $pclass = 'project-closed-with-open-children' } }
                'Canceled'    { if ($openN -gt 0) { $pclass = 'project-closed-with-open-children' } }
                'Backlog'     { if ($activeN -gt 0) { $pclass = 'project-idle-with-active-children' } }
                'Planned'     { if ($activeN -gt 0) { $pclass = 'project-idle-with-active-children' } }
                'In Progress' { if ($openN -eq 0) { $pclass = 'project-active-with-no-open-children' } }
            }
            if ($pclass -eq '') { continue }
            $findings++
            if ($List) {
                Write-Output ("project`t{0}`t{1}`t{2}`t{3}`t{4}" -f $pclass, $pname, $pstatus, $openN, $activeN)
            } else {
                Write-Output ('WARN {0} "{1}": status "{2}" with {3} open child issue(s), {4} active' -f `
                    $pclass, $pname, $pstatus, $openN, $activeN)
            }
        }
    }
}

# --- verdict ------------------------------------------------------------------
# Never let an empty scan read as a clean bill of health: if not a single claim
# could be compared and no project was evaluated, there is no evidence at all.
if ($checkedClaims -eq 0 -and $projectsChecked -eq 0) {
    Skip-Currentness 'no comparable evidence found (0 claims matched a live issue, 0 projects evaluated) — check --prefix and the scanned sources'
}

if (-not $List) {
    if ($unknownIdents -ne '') {
        Write-Output ("NOTE identifier(s) named in notes but absent from the tracker payload:{0}" -f $unknownIdents)
    }
    if ($projectsSkipped -ne '') {
        Write-Output ("NOTE project(s) not evaluated (read cap --max-reads={0}, or a failed read):{1}" -f $MaxReads, $projectsSkipped)
    }
}

if ($findings -eq 0) {
    if (-not $List) {
        Write-Output ("PASS {0} claim(s) and {1} project(s) agree with live tracker state" -f $checkedClaims, $projectsChecked)
    }
    exit 0
}

if (-not $List) {
    Write-Output ("SUMMARY {0} finding(s): {1} stale claim(s), {2} stale snapshot(s), across {3} compared claim(s) and {4} project(s) — advisory; reconcile the note or the tracker" -f `
        $findings, $staleClaims, $staleSnapshots, $checkedClaims, $projectsChecked)
}
exit 1
