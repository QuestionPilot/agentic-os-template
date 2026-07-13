#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/hooks-cross-harness-parity.test.ps1 — Windows-native twin of
# tests/hooks-cross-harness-parity.test.sh (<TEAM>-364 item 3).
#
# Same contract: DECISION parity — one semantic scenario, rendered into each
# harness's native input shape, must produce the SAME allow/deny decision in
# every harness realization (claude / codex / hermes). The matrix is the seed
# detector: a seeded behavioral divergence in any ONE twin fails its
# per-harness expected-decision row (localizing which twin diverged) AND the
# cross-harness agreement row (the parity contract itself).
#
# Lane split per [[feedback_port_parity_vs_regression_split]] (the sibling
# decisions in tests/hooks-behavior.test.ps1 + tests/codex.test.ps1):
#   - the install.sh-rendered .sh lanes are _Skip here — install.ps1 emits
#     .ps1 hooks, and the bash engine runs on the macOS/Linux lanes;
#   - the .ps1-twin lanes run LIVE natively (pwsh IS this lane's engine),
#     mirroring the bash twin's ps1-engine matrix 1:1 — same fixtures, same
#     state.db modeling, same expected-decision table.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

# --- bash-engine lanes: _Skip with rationale (count + label parity) ---------
$xh_sh_reason = 'bash-engine lanes — install.ps1 emits .ps1 hooks; the .sh matrix runs on the macOS/Linux bash suite'
_Skip 'xh: rendered claude session-agent.sh' $xh_sh_reason
_Skip 'xh: rendered codex session-agent.sh'  $xh_sh_reason
_Skip 'xh: rendered hermes session-agent.sh' $xh_sh_reason
foreach ($xh_sc in @('S1 no-orient', 'S2 orient-declared', 'S3 orient-undeclared-with-noise', 'S4 kill-switch', 'S5 orient-lessons-less')) {
    _Skip "xh[sh] ${xh_sc}: claude decision"      $xh_sh_reason
    _Skip "xh[sh] ${xh_sc}: codex decision"       $xh_sh_reason
    _Skip "xh[sh] ${xh_sc}: parity claude==codex" $xh_sh_reason
    _Skip "xh[sh] ${xh_sc}: hermes decision"      $xh_sh_reason
    _Skip "xh[sh] ${xh_sc}: parity codex==hermes" $xh_sh_reason
}

# --- pwsh-engine lanes: live native mirror -----------------------------------
# The claude/codex .ps1 gate hooks fail CLOSED without jq (their deny channel
# is rendered through jq), so a jq-less box cannot distinguish a genuine deny
# from the fail-closed deny — S2's expected allow would be unfalsifiable noise.
# Skip the whole native matrix with the reason in that case.
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    $xh_jq_reason = 'jq not on PATH — the claude/codex gate hooks fail closed without it'
    _Skip 'xh: hermes S3 state models the injected template line' $xh_jq_reason
    _Skip 'xh: hermes S3 state models the Lessons template line'  $xh_jq_reason
    _Skip 'xh: hermes S3 state models a prior deny quote'         $xh_jq_reason
    foreach ($xh_sc in @('S1 no-orient', 'S2 orient-declared', 'S3 orient-undeclared-with-noise', 'S4 kill-switch', 'S5 orient-lessons-less')) {
        _Skip "xh[ps1] ${xh_sc}: claude decision"      $xh_jq_reason
        _Skip "xh[ps1] ${xh_sc}: codex decision"       $xh_jq_reason
        _Skip "xh[ps1] ${xh_sc}: parity claude==codex" $xh_jq_reason
        _Skip "xh[ps1] ${xh_sc}: hermes decision"      $xh_jq_reason
        _Skip "xh[ps1] ${xh_sc}: parity codex==hermes" $xh_jq_reason
    }
    return
}

$xh_root = Join-Path ([IO.Path]::GetTempPath()) ('xh-parity-' + [Guid]::NewGuid().Guid.Substring(0, 8))
try {
    # Stage each harness's session-agent.ps1 into a throwaway per-harness home
    # (the copy-into-throwaway-layout pattern of hooks-ps-parity 3h): the
    # claude/hermes hooks resolve their state (marker dir, state.db) relative
    # to $PSScriptRoot's parent, so marker reaps and db reads never touch the
    # repo. install.ps1 is not needed — the session-agent sources carry no
    # placeholders, and the install-render path is covered by install.test.ps1.
    $xh_cl = Join-Path $xh_root 'claude-home'
    $xh_cx = Join-Path $xh_root 'codex-home'
    $xh_hm = Join-Path $xh_root 'hermes-home'
    foreach ($xh_pair in @(@($xh_cl, 'claude'), @($xh_cx, 'codex'), @($xh_hm, 'hermes'))) {
        New-Item -ItemType Directory -Path (Join-Path $xh_pair[0] 'hooks') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $env:REPO_ROOT 'harnesses' $xh_pair[1] 'hooks' 'session-agent.ps1') `
            -Destination (Join-Path $xh_pair[0] 'hooks' 'session-agent.ps1')
    }
    $xh_fix = Join-Path $env:REPO_ROOT 'tests' 'fixtures'

    # Hermes state modeling — same rows as the bash twin, byte for byte: the
    # schema the hook queries (messages: session_id/role/content/tool_calls),
    # xh-s1 = benign chatter, xh-s2 = injected body + prior-deny noise + an
    # ASSISTANT line-anchored declaration, xh-s3 = the same noise undeclared.
    $xh_have_sqlite = [bool](Get-Command sqlite3 -ErrorAction SilentlyContinue)
    $xh_db = Join-Path $xh_hm 'state.db'
    if ($xh_have_sqlite) {
        $xh_sql = @'
CREATE TABLE messages (session_id TEXT, role TEXT, content TEXT, tool_calls TEXT, timestamp REAL);
INSERT INTO messages VALUES ('xh-s1','user','hello',NULL,1);
INSERT INTO messages VALUES ('xh-s1','assistant','hi',NULL,2);
INSERT INTO messages VALUES ('xh-s2','user','# Session Agent — Session Kickoff Orient + Routing
injected body: skills/session-agent/SKILL.md
Routing: <one-sentence task surface>
Lessons: <matched lesson/note names> | none match | index unreachable
Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted',NULL,1);
INSERT INTO messages VALUES ('xh-s2','tool','blocked: The session-agent capability ran but no complete routing declaration was found this session — both the `Linear gate:` line AND the `Lessons:` line are required. Emit the full declaration.',NULL,2);
INSERT INTO messages VALUES ('xh-s2','assistant','Routing: infra change
Lessons: none match
Linear gate: PROJ-1',NULL,3);
INSERT INTO messages VALUES ('xh-s3','user','# Session Agent — Session Kickoff Orient + Routing
injected body: skills/session-agent/SKILL.md
Routing: <one-sentence task surface>
Lessons: <matched lesson/note names> | none match | index unreachable
Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted',NULL,1);
INSERT INTO messages VALUES ('xh-s3','tool','blocked: The session-agent capability ran but no complete routing declaration was found this session — both the `Linear gate:` line AND the `Lessons:` line are required. Emit the full declaration.',NULL,2);
INSERT INTO messages VALUES ('xh-s3','assistant','Routing: infra change',NULL,3);
INSERT INTO messages VALUES ('xh-s5','user','# Session Agent — Session Kickoff Orient + Routing
injected body: skills/session-agent/SKILL.md
Routing: <one-sentence task surface>
Lessons: <matched lesson/note names> | none match | index unreachable
Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted',NULL,1);
INSERT INTO messages VALUES ('xh-s5','tool','blocked: The session-agent capability ran but no complete routing declaration was found this session — both the `Linear gate:` line AND the `Lessons:` line are required. Emit the full declaration.',NULL,2);
INSERT INTO messages VALUES ('xh-s5','assistant','Routing: infra change
Linear gate: PROJ-1',NULL,3);
'@
        & sqlite3 $xh_db $xh_sql 2>$null
        # Scenario-realism guard: S3's deny must be earned against both
        # vacuousness triggers sitting in NON-assistant rows.
        $xh_s3_noise = (@(& sqlite3 -readonly $xh_db "SELECT content FROM messages WHERE session_id='xh-s3' AND role <> 'assistant';" 2>$null) -join "`n")
        Assert-Contains 'xh: hermes S3 state models the injected template line' $xh_s3_noise 'Linear gate: <ISSUE-ID'
        Assert-Contains 'xh: hermes S3 state models the Lessons template line'  $xh_s3_noise 'Lessons: <matched'
        Assert-Contains 'xh: hermes S3 state models a prior deny quote'         $xh_s3_noise 'no complete routing declaration'
    } else {
        _Skip 'xh: hermes S3 state models the injected template line' 'sqlite3 not installed'
        _Skip 'xh: hermes S3 state models the Lessons template line'  'sqlite3 not installed'
        _Skip 'xh: hermes S3 state models a prior deny quote'         'sqlite3 not installed'
    }

    # Get-XhDecision <harness> <hook> <payload> [<extra-env>] -> deny|allow|error-N
    # Feeds the payload on stdin (UTF-8 no-BOM temp file, the Invoke-CodexHook
    # idiom) and classifies stdout through the harness's own decision channel:
    #   claude — only hookSpecificOutput.permissionDecision "deny" denies (the
    #            legacy top-level {"decision":"block"} is a no-op there);
    #   codex  — BOTH shapes deny (modern runtime path + legacy jq-missing
    #            static path; Codex honors both on PreToolUse);
    #   hermes — legacy {"decision":"block"} denies; allow is silent stdout.
    # A non-zero exit becomes error-N: every gate hook's contract is
    # exit-0-always, so an execution error must never classify as allow.
    function Get-XhDecision {
        param(
            [string]$Harness,
            [string]$HookPath,
            [string]$Payload,
            [hashtable]$ExtraEnv = @{}
        )
        $saved = @{}
        foreach ($k in $ExtraEnv.Keys) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            [Environment]::SetEnvironmentVariable($k, $ExtraEnv[$k])
        }
        $tmp = [IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($tmp, $Payload, [System.Text.UTF8Encoding]::new($false))
            $out = Get-Content -LiteralPath $tmp -Raw | & pwsh -NoProfile -File $HookPath 2>$null
            $code = $LASTEXITCODE
        } finally {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            foreach ($k in $ExtraEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
        if ($code -ne 0) { return "error-$code" }
        $text = (@($out) -join "`n")
        switch ($Harness) {
            'claude' { if ($text -like '*"permissionDecision":"deny"*') { 'deny' } else { 'allow' } }
            'codex'  { if (($text -like '*"permissionDecision":"deny"*') -or ($text -like '*"decision":"block"*')) { 'deny' } else { 'allow' } }
            'hermes' { if ($text -like '*"decision":"block"*') { 'deny' } else { 'allow' } }
        }
    }

    # One matrix row (mirrors the bash twin's xh_scenario): per-harness
    # expected-decision assertions localize the diverging twin; the pairwise
    # agreement assertions (claude==codex, codex==hermes — transitive) are the
    # parity contract itself.
    function Test-XhScenario {
        param(
            [string]$Id,          # S1..S4
            [string]$Name,
            [string]$Want,        # deny | allow
            [hashtable]$ExtraEnv = @{}
        )
        switch ($Id) {
            'S2' { $clFix = Join-Path $xh_fix 'transcript-session-agent-ok.jsonl'
                   $cxFix = Join-Path $xh_fix 'codex-transcript-session-agent-ok.jsonl' }
            'S3' { $clFix = Join-Path $xh_fix 'transcript-session-agent-no-linear.jsonl'
                   $cxFix = Join-Path $xh_fix 'codex-transcript-session-agent-no-linear.jsonl' }
            'S5' { $clFix = Join-Path $xh_fix 'transcript-session-agent-no-lessons.jsonl'
                   $cxFix = Join-Path $xh_fix 'codex-transcript-session-agent-no-lessons.jsonl' }
            # S1 + S4 share the no-orient input — S4 proves the kill switch
            # flips exactly that deny to an allow in every harness.
            default { $clFix = Join-Path $xh_fix 'transcript-empty.jsonl'
                      $cxFix = Join-Path $xh_fix 'codex-transcript-empty.jsonl' }
        }
        $sid = 'xh-s' + $Id.Substring(1)
        # Forward-slash the embedded paths: JSON string values must not carry
        # raw backslashes (codex.test.ps1's ConvertTo-Slash convention).
        $clPayload = '{"transcript_path":"' + ($clFix -replace '\\', '/') + '","tool_name":"Write","session_id":"' + $sid + '"}'
        $cxPayload = '{"transcript_path":"' + ($cxFix -replace '\\', '/') + '","tool_name":"apply_patch"}'
        $hmPayload = '{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"/tmp/xh-target.txt","content":"hi"},"session_id":"' + $sid + '","cwd":"/tmp"}'

        $dCl = Get-XhDecision -Harness claude -HookPath (Join-Path $xh_cl 'hooks' 'session-agent.ps1') -Payload $clPayload -ExtraEnv $ExtraEnv
        $dCx = Get-XhDecision -Harness codex  -HookPath (Join-Path $xh_cx 'hooks' 'session-agent.ps1') -Payload $cxPayload -ExtraEnv $ExtraEnv
        Assert-Eq "xh[ps1] $Id ${Name}: claude decision"      $Want $dCl
        Assert-Eq "xh[ps1] $Id ${Name}: codex decision"       $Want $dCx
        Assert-Eq "xh[ps1] $Id ${Name}: parity claude==codex" $dCl  $dCx
        # Hermes S1-S3 model session state in state.db; S4 short-circuits on
        # the kill switch before any state read, so it runs even without
        # sqlite3 (matching the bash twin's guard).
        if ($xh_have_sqlite -or $Id -eq 'S4') {
            $dHm = Get-XhDecision -Harness hermes -HookPath (Join-Path $xh_hm 'hooks' 'session-agent.ps1') -Payload $hmPayload -ExtraEnv $ExtraEnv
            Assert-Eq "xh[ps1] $Id ${Name}: hermes decision"      $Want $dHm
            Assert-Eq "xh[ps1] $Id ${Name}: parity codex==hermes" $dCx  $dHm
        } else {
            _Skip "xh[ps1] $Id ${Name}: hermes decision"      'sqlite3 not installed - cannot model state.db'
            _Skip "xh[ps1] $Id ${Name}: parity codex==hermes" 'sqlite3 not installed - cannot model state.db'
        }
    }

    Test-XhScenario -Id S1 -Name 'no-orient'                    -Want deny
    Test-XhScenario -Id S2 -Name 'orient-declared'              -Want allow
    Test-XhScenario -Id S3 -Name 'orient-undeclared-with-noise' -Want deny
    Test-XhScenario -Id S4 -Name 'kill-switch'                  -Want allow -ExtraEnv @{ CLAUDE_SKIP_SESSION_AGENT = '1' }
    Test-XhScenario -Id S5 -Name 'orient-lessons-less'          -Want deny
} finally {
    Remove-Item -LiteralPath $xh_root -Recurse -Force -ErrorAction SilentlyContinue
}
