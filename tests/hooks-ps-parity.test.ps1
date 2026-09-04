#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/hooks-ps-parity.test.ps1 — Windows-native twin of tests/hooks-ps-parity.test.sh.
#
# every harness hook.sh has a behavioral-equivalent.ps1 twin (and
# vice versa). Plus codex Windows JSON-encoded backslash marker recognition
# regression assertions.
#
# Mirrors tests/hooks-ps-parity.test.sh 1:1.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$hkps_root = Join-Path $env:REPO_ROOT 'harnesses'

# Enumerate every hook source file across all harnesses (recursive,
# `*/hooks/*` pattern). Sort for deterministic output.
function Find-HookFiles {
    param([string]$Root, [string]$Ext)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    # Walk the tree and filter on /hooks/ in the relative path.
    $all = Get-ChildItem -LiteralPath $Root -Filter "*$Ext" -File -Recurse -ErrorAction SilentlyContinue
    $hooks = @($all | Where-Object { $_.FullName -replace '\\','/' -match '/hooks/' })
    return @($hooks | Sort-Object FullName)
}

$hkps_sh_pairs  = Find-HookFiles -Root $hkps_root -Ext '.sh'
$hkps_ps1_pairs = Find-HookFiles -Root $hkps_root -Ext '.ps1'

if ($hkps_sh_pairs.Count -eq 0) {
    _Fail "hooks-ps-parity.test: no .sh hooks found under $hkps_root (expected at least one — has the layout changed?)" `
        'find returned 0 entries'
} else {
    _Pass "hooks-ps-parity.test: enumerated $($hkps_sh_pairs.Count) .sh hooks across harnesses"
}

# Every.sh hook must have a sibling.ps1.
$hkps_missing_ps1 = New-Object System.Collections.Generic.List[string]
foreach ($sh in $hkps_sh_pairs) {
    $ps1_path = $sh.FullName -replace '\.sh$', '.ps1'
    if (-not (Test-Path -LiteralPath $ps1_path -PathType Leaf)) {
        # Codex F-1 (MEDIUM): use [System.IO.Path]::GetRelativePath per
        # [[reference_ps_port_traps]] trap #11 — Substring-based relpath
        # silently miscomputes when $env:REPO_ROOT and $ps1_path differ in
        # casing/separator normalization. Forward-slash normalize the result
        # for label-output parity.
        $rel = [System.IO.Path]::GetRelativePath($env:REPO_ROOT, $ps1_path).Replace([char]'\', [char]'/')
        [void]$hkps_missing_ps1.Add($rel)
    }
}
if ($hkps_missing_ps1.Count -eq 0) {
    _Pass 'hooks-ps-parity.test: every .sh hook has a sibling .ps1 twin'
} else {
    $lines = $hkps_missing_ps1 | ForEach-Object { "  - $_" }
    _Fail 'hooks-ps-parity.test: .sh hooks missing .ps1 twins' $lines
}

# Inverse: every.ps1 hook must have a sibling.sh.
$hkps_missing_sh = New-Object System.Collections.Generic.List[string]
foreach ($ps1 in $hkps_ps1_pairs) {
    $sh_path = $ps1.FullName -replace '\.ps1$', '.sh'
    if (-not (Test-Path -LiteralPath $sh_path -PathType Leaf)) {
        # Codex F-1 (MEDIUM): GetRelativePath per trap #11; see above.
        $rel = [System.IO.Path]::GetRelativePath($env:REPO_ROOT, $sh_path).Replace([char]'\', [char]'/')
        [void]$hkps_missing_sh.Add($rel)
    }
}
if ($hkps_missing_sh.Count -eq 0) {
    _Pass 'hooks-ps-parity.test: every .ps1 hook has a sibling .sh twin'
} else {
    $lines = $hkps_missing_sh | ForEach-Object { "  - $_" }
    _Fail 'hooks-ps-parity.test: .ps1 hooks missing .sh twins' $lines
}

# --- 3. Behavioral parity: codex Windows marker recognition ---
# (The codex closeout.ps1 marker cases were removed — the closeout
# Stop hook no longer exists; closeout is manual-fire.)
$hkps_tmpdir = Join-Path ([IO.Path]::GetTempPath()) ('hkps-ps-' + [Guid]::NewGuid().Guid.Substring(0,8))
New-Item -ItemType Directory -Path $hkps_tmpdir -Force | Out-Null
try {
    $hkps_codex_sa       = Join-Path $env:REPO_ROOT 'harnesses' 'codex' 'hooks' 'session-agent.ps1'

    function Invoke-CodexHook {
        param([string]$HookPath, [string]$Payload)
        $tmp = [IO.Path]::GetTempFileName()
        try {
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($tmp, $Payload, $utf8NoBom)
            $out = Get-Content -LiteralPath $tmp -Raw | & pwsh -NoProfile -File $HookPath 2>$null
            if ($out -is [array]) { $out = $out -join "`n" }
            return [string]$out
        } finally {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        }
    }

    function Write-LfFile {
        param([string]$Path, [string]$Content)
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
    }

    # 3a — codex session-agent.ps1, forward-slash marker ALLOWS.
    # <TEAM>-360: the hook now parses rollout RECORDS (an assistant function_call
    # reading the SKILL.md path + an assistant-authored line-anchored gate), so
    # these synthetic transcripts are real JSONL, not bare text.
    $trans = Join-Path $hkps_tmpdir 'trans-sa-fwd.jsonl'
    Write-LfFile $trans (@(
        '{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cat skills/session-agent/SKILL.md\"}","call_id":"c1"}}'
        '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Routing: x\nLessons: none match\nLinear gate: PROJ-1"}]}}'
    ) -join "`n")
    $payload = '{"transcript_path":"' + ($trans -replace '\\', '/') + '"}'
    $out = Invoke-CodexHook -HookPath $hkps_codex_sa -Payload $payload
    if (-not $out) {
        _Pass 'hooks-ps-parity.test: codex session-agent.ps1 ALLOWS forward-slash marker'
    } else {
        _Fail 'hooks-ps-parity.test: codex session-agent.ps1 should ALLOW forward-slash marker + Linear gate' `
            "got non-empty output: $out"
    }

    # 3b — codex session-agent.ps1, BACKSLASH marker ALLOWS (F-1 fix).
    # A Windows path in the doubly-encoded arguments string reaches the parsed
    # .arguments value with TWO literal backslashes per separator; the raw JSONL
    # bytes below carry four. The function_call branch's [/\\]+ class must match.
    $trans = Join-Path $hkps_tmpdir 'trans-sa-bs.jsonl'
    Write-LfFile $trans (@(
        '{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cat skills\\\\session-agent\\\\SKILL.md\"}","call_id":"c1"}}'
        '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Routing: x\nLessons: none match\nLinear gate: PROJ-1"}]}}'
    ) -join "`n")
    $payload = '{"transcript_path":"' + ($trans -replace '\\', '/') + '"}'
    $out = Invoke-CodexHook -HookPath $hkps_codex_sa -Payload $payload
    if (-not $out) {
        _Pass 'hooks-ps-parity.test: codex session-agent.ps1 ALLOWS backslash marker'
    } else {
        _Fail 'hooks-ps-parity.test: codex session-agent.ps1 should ALLOW backslash marker + Linear gate' `
            "got non-empty output: $out"
    }

    # 3b2 — codex session-agent.ps1, lowercase declaration DENIES (<TEAM>-360
    # cross-model panel): PS -match is case-insensitive by default, so a plain
    # -match would open the gate on `linear gate:` on Windows only. The hook
    # uses -cmatch; this locks the bash<->PS case-sensitivity parity.
    $trans = Join-Path $hkps_tmpdir 'trans-sa-lc.jsonl'
    Write-LfFile $trans (@(
        '{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cat skills/session-agent/SKILL.md\"}","call_id":"c1"}}'
        '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Routing: x\nLessons: none match\nlinear gate: PROJ-1"}]}}'
    ) -join "`n")
    $payload = '{"transcript_path":"' + ($trans -replace '\\', '/') + '"}'
    $out = Invoke-CodexHook -HookPath $hkps_codex_sa -Payload $payload
    if ($out -match '"deny"|"block"') {
        _Pass 'hooks-ps-parity.test: codex session-agent.ps1 DENIES lowercase declaration (case parity)'
    } else {
        _Fail 'hooks-ps-parity.test: codex session-agent.ps1 should DENY lowercase ''linear gate:''' `
            "got: $(if ($out) { $out } else { '<empty = allow>' })"
    }

    # --- 3c/3d — claude framework-surface.ps1 compaction-aware directive ---
    # SessionStart re-fires with source=compact|resume after a compaction. On
    # those sources the directive must be the idempotent re-orient, not the
    # kickoff. MCP + freshness probes disabled for a deterministic SA-only
    # payload; @@AI_CONFIG_DIR@@ stays unsubstituted so the git block is empty.
    $hkps_fs = Join-Path $env:REPO_ROOT 'harnesses' 'claude' 'hooks' 'framework-surface.ps1'
    $env:CLAUDE_SKIP_MCP_PROBE = '1'
    $env:CLAUDE_SKIP_FRESHNESS_CHECK = '1'
    try {
        $out = Invoke-CodexHook -HookPath $hkps_fs -Payload '{"source":"compact"}'
        if ($out -match 're-orient after compacted session') {
            _Pass 'hooks-ps-parity.test: claude framework-surface.ps1 emits re-orient directive on source=compact'
        } else {
            _Fail 'hooks-ps-parity.test: claude framework-surface.ps1 should emit re-orient directive on source=compact' `
                "got: $out"
        }

        $out = Invoke-CodexHook -HookPath $hkps_fs -Payload '{"source":"startup"}'
        if (($out -match 'invoke now') -and ($out -notmatch 're-orient after')) {
            _Pass 'hooks-ps-parity.test: claude framework-surface.ps1 keeps kickoff directive on source=startup'
        } else {
            _Fail 'hooks-ps-parity.test: claude framework-surface.ps1 should keep kickoff directive on source=startup' `
                "got: $out"
        }
    } finally {
        Remove-Item Env:\CLAUDE_SKIP_MCP_PROBE -ErrorAction SilentlyContinue
        Remove-Item Env:\CLAUDE_SKIP_FRESHNESS_CHECK -ErrorAction SilentlyContinue
    }

    # --- 3c2/3d2 — codex framework-surface.ps1 compaction-aware directive ---
    # (<TEAM>-360): same contract as the Claude twin — source=compact emits the
    # idempotent re-orient, source=startup keeps the kickoff.
    $hkps_cxfs = Join-Path $env:REPO_ROOT 'harnesses' 'codex' 'hooks' 'framework-surface.ps1'
    $env:CLAUDE_SKIP_FRESHNESS_CHECK = '1'
    try {
        $out = Invoke-CodexHook -HookPath $hkps_cxfs -Payload '{"source":"compact"}'
        if ($out -match 're-orient after compacted session') {
            _Pass 'hooks-ps-parity.test: codex framework-surface.ps1 emits re-orient directive on source=compact'
        } else {
            _Fail 'hooks-ps-parity.test: codex framework-surface.ps1 should emit re-orient directive on source=compact' `
                "got: $out"
        }

        $out = Invoke-CodexHook -HookPath $hkps_cxfs -Payload '{"source":"startup"}'
        if (($out -match 'invoke now') -and ($out -notmatch 're-orient after')) {
            _Pass 'hooks-ps-parity.test: codex framework-surface.ps1 keeps kickoff directive on source=startup'
        } else {
            _Fail 'hooks-ps-parity.test: codex framework-surface.ps1 should keep kickoff directive on source=startup' `
                "got: $out"
        }
    } finally {
        Remove-Item Env:\CLAUDE_SKIP_FRESHNESS_CHECK -ErrorAction SilentlyContinue
    }

    # --- 3e. hermes skill-gate.ps1 — mutation-only gate parity (<TEAM>-300) ------
    # skill_manage is MUTATION-ONLY (reads are the separate, ungated skill_view/
    # skills_list tools the matcher never fires on), so the gate has NO read-only
    # fast-path: EVERY skill_manage call BLOCKS pending a per-use operator approval
    # marker that the hook CONSUMES. Assert both on the PS twin (mirroring the bash
    # twin in the .sh sibling's section 3i): (a) block-by-default for every payload
    # shape, incl. the read-only verbs an earlier version fast-pathed, malformed
    # input, and a non-object tool_input; (b) the allow-once-then-consume marker
    # flow. Run against a COPY under a throwaway HHOME so the marker write never
    # touches the repo. (This replaced a read-only-allowlist table whose JSON parsing
    # was the source of a clutch of bash<->PS divergences; gating every call removes
    # that surface whole.)
    $hkps_sgdir = Join-Path $hkps_tmpdir 'sg'
    New-Item -ItemType Directory -Path (Join-Path $hkps_sgdir 'hooks') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $hkps_sgdir 'agentic-os') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $env:REPO_ROOT 'harnesses' 'hermes' 'hooks' 'skill-gate.ps1') `
        -Destination (Join-Path $hkps_sgdir 'hooks' 'skill-gate.ps1')
    $hkps_sg = Join-Path $hkps_sgdir 'hooks' 'skill-gate.ps1'
    $hkps_sgmk = Join-Path $hkps_sgdir 'agentic-os' 'allow-skill-manage'
    $hkps_sg_payloads = @(
        '{"tool_input":{"action":"create","name":"x"}}'
        '{"tool_input":{"action":"delete"}}'
        '{"tool_input":{"action":"list"}}'
        '{"tool_input":{"operation":"list"}}'
        '{"tool_input":{"action":"list","operation":"delete"}}'
        '{"tool_input":{}}'
        '{}'
        '{"tool_input":[{"action":"list"}]}'
        'not valid json'
    )
    foreach ($hkps_pl in $hkps_sg_payloads) {
        Remove-Item -LiteralPath $hkps_sgmk -ErrorAction SilentlyContinue
        $out = Invoke-CodexHook -HookPath $hkps_sg -Payload $hkps_pl
        if ($out -match '"decision":"block"') {
            _Pass "hooks-ps-parity.test: skill-gate.ps1 gates (blocks) $hkps_pl"
        } else {
            _Fail "hooks-ps-parity.test: skill-gate.ps1 should BLOCK $hkps_pl" "got: $(if ($out) { $out } else { '<allow>' })"
        }
    }
    # approval marker: allows exactly one call, then is consumed.
    New-Item -ItemType File -Path $hkps_sgmk -Force | Out-Null
    $out = Invoke-CodexHook -HookPath $hkps_sg -Payload '{"tool_input":{"action":"create"}}'
    if ((-not $out) -and (-not (Test-Path -LiteralPath $hkps_sgmk))) {
        _Pass 'hooks-ps-parity.test: skill-gate.ps1 approval marker allows ONE call and is consumed'
    } else {
        _Fail 'hooks-ps-parity.test: skill-gate.ps1 approval marker should allow+consume' "out='$(if ($out) { $out } else { '<allow>' })' marker_present=$(Test-Path -LiteralPath $hkps_sgmk)"
    }
    # A DIRECTORY at the marker path is NOT an approval — Test-Path -PathType Leaf
    # (matching bash `[[ -f ]]`) must reject it. Without that qualifier the PS twin
    # would treat the dir as an approval and a non-empty dir would survive the
    # delete (standing allow). Parity regression for the -PathType Leaf fix.
    Remove-Item -LiteralPath $hkps_sgmk -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $hkps_sgmk -Force | Out-Null
    $out = Invoke-CodexHook -HookPath $hkps_sg -Payload '{"tool_input":{"action":"create"}}'
    if ($out -match '"decision":"block"') {
        _Pass 'hooks-ps-parity.test: skill-gate.ps1 treats a DIRECTORY at the marker path as NO approval (blocks)'
    } else {
        _Fail 'hooks-ps-parity.test: skill-gate.ps1 should BLOCK when the marker path is a directory' "got: $(if ($out) { $out } else { '<allow>' })"
    }
    Remove-Item -LiteralPath $hkps_sgmk -Recurse -Force -ErrorAction SilentlyContinue

} finally {
    Remove-Item -LiteralPath $hkps_tmpdir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 4. <TEAM>-295 source guards: Windows hook-twin divergence fixes -------------
# Lock the F3/F4 fixes that cannot be reproduced on a UTF-8 / pwsh-on-PATH dev
# box (the bugs only bite on Windows). Pure source-text checks.
$hkps_ms = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'harnesses' 'hermes' 'hooks' 'memory-sanitize.ps1') -Raw
Assert-Contains 'hooks-ps-parity.test: memory-sanitize.ps1 resolves the running pwsh via $PID' $hkps_ms '(Get-Process -Id $PID).Path'
Assert-NotContains "hooks-ps-parity.test: memory-sanitize.ps1 has no bare '& pwsh -NoProfile -File'" $hkps_ms '& pwsh -NoProfile -File'
$hkps_hfs = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'harnesses' 'hermes' 'hooks' 'framework-surface.ps1') -Raw
Assert-Contains 'hooks-ps-parity.test: hermes framework-surface.ps1 resolves the running pwsh via $PID' $hkps_hfs '(Get-Process -Id $PID).Path'
Assert-NotContains "hooks-ps-parity.test: hermes framework-surface.ps1 has no bare '& pwsh -NoProfile -File'" $hkps_hfs '& pwsh -NoProfile -File'
$hkps_cfs = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'harnesses' 'claude' 'hooks' 'framework-surface.ps1') -Raw
Assert-Contains "hooks-ps-parity.test: claude framework-surface.ps1 MCP probe parses the Connected status word (-ceq)" $hkps_cfs "-ceq 'Connected'"
# Block 1c (orphaned operator-local hook check) — PS twin must carry it so the
# .ps1 cannot diverge from the .sh behavioral coverage in hooks-behavior.test.sh.
Assert-Contains "hooks-ps-parity.test: claude framework-surface.ps1 carries the orphaned-local-hook kill switch" $hkps_cfs 'CLAUDE_SKIP_LOCAL_HOOK_CHECK'
Assert-Contains "hooks-ps-parity.test: claude framework-surface.ps1 reads settings.local.json hook commands" $hkps_cfs 'settings.local.json'
Assert-Contains "hooks-ps-parity.test: claude framework-surface.ps1 emits the orphaned-local-hook warning" $hkps_cfs 'Operator-local hook is missing'

# <TEAM>-300: skill_manage is mutation-only, so the gate has NO read-only fast-path
# — it gates EVERY call. Lock that source-side so a revert re-introducing a
# read-only fast-path fails on every lane. Robust invariant: the gate does not
# PARSE the verb out of the payload — any fast-path (a jq pipe-regex like
# ^(list|...)$ or a JSON-array allowlist) must read .tool_input on bash /
# ConvertFrom-Json on PS. The simple gate references neither (it only ENCODES its
# block output via jq -nc / ConvertTo-Json), so the absent input-parse is the tripwire.
$hkps_sgsh = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'harnesses' 'hermes' 'hooks' 'skill-gate.sh') -Raw
Assert-NotContains 'hooks-ps-parity.test: skill-gate.sh does not parse the verb (no .tool_input read)' $hkps_sgsh '.tool_input'
Assert-Contains 'hooks-ps-parity.test: skill-gate.sh consumes stdin without inspecting it (cat >/dev/null)' $hkps_sgsh 'cat >/dev/null'
$hkps_sgps = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'harnesses' 'hermes' 'hooks' 'skill-gate.ps1') -Raw
Assert-NotContains 'hooks-ps-parity.test: skill-gate.ps1 does not parse the verb (no ConvertFrom-Json)' $hkps_sgps 'ConvertFrom-Json'
Assert-Contains 'hooks-ps-parity.test: skill-gate.ps1 consumes stdin without inspecting it (ReadToEnd)' $hkps_sgps '[Console]::In.ReadToEnd()'

# --- 5. <TEAM>-364 distillation-lag nudge — claude framework-surface.ps1 ----
# Windows-native mirror of the .sh sibling's section 5: lapse -> header +
# note name; distilled -> nudge absent; kill switch -> nudge absent;
# unresolvable vault -> silent (checker exit 2, fail-open). The repo source
# hook still carries the @@AI_CONFIG_DIR@@ placeholder (this file runs
# sources, not a build), so run a COPY with the placeholder substituted to
# REPO_ROOT — the same substitution install performs — so the block can find
# scripts/check-distillation-completeness.ps1. Other probe blocks are
# disabled via their kill switches for a deterministic payload; ambient env
# is saved/restored so later test files see it unchanged.
$hkdn_tmp = Join-Path ([IO.Path]::GetTempPath()) ('hkdn-ps-' + [Guid]::NewGuid().Guid.Substring(0,8))
try {
    New-Item -ItemType Directory -Path (Join-Path $hkdn_tmp 'hooks') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $hkdn_tmp 'cfg' 'projects' 'x' 'memory') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $hkdn_tmp 'vault' '04-Lessons') -Force | Out-Null
    $hkdn_utf8 = [System.Text.UTF8Encoding]::new($false)
    $hkdn_hook = Join-Path $hkdn_tmp 'hooks' 'framework-surface.ps1'
    $hkdn_src = Get-Content -LiteralPath (Join-Path $env:REPO_ROOT 'harnesses' 'claude' 'hooks' 'framework-surface.ps1') -Raw
    # .Replace() (ordinal), not -replace: REPO_ROOT must land literally even if
    # the path contains regex-substitution metacharacters.
    [System.IO.File]::WriteAllText($hkdn_hook, $hkdn_src.Replace('@@AI_CONFIG_DIR@@', $env:REPO_ROOT), $hkdn_utf8)
    # In-scope note: kebab slug + frontmatter `metadata:`-nested `type: feedback`
    # (the shape the checker's frontmatter scan recognizes).
    [System.IO.File]::WriteAllText((Join-Path $hkdn_tmp 'cfg' 'projects' 'x' 'memory' 'feedback-test-lapse-note.md'),
        "---`ntitle: test lapse note`nmetadata:`n  type: feedback`n---`nA feedback note that has not been distilled into 04-Lessons.`n", $hkdn_utf8)
    [System.IO.File]::WriteAllText((Join-Path $hkdn_tmp 'cfg' 'projects' 'x' 'memory' 'MEMORY.md'), "# Memory index`n", $hkdn_utf8)
    [System.IO.File]::WriteAllText((Join-Path $hkdn_tmp 'vault' '04-Lessons' 'unrelated.md'), "# Unrelated lesson`n", $hkdn_utf8)

    # Invoke-DistHook — run the substituted hook with the probe kill switches +
    # the given vault path, saving/restoring the ambient env around the call.
    function Invoke-DistHook {
        param([string]$Vault, [string]$ExtraSwitch = '')
        $keys = @('CLAUDE_SKIP_MCP_PROBE', 'CLAUDE_SKIP_FRESHNESS_CHECK', 'CLAUDE_SKIP_LOCAL_HOOK_CHECK',
                  'CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE', 'CLAUDE_CONFIG_DIR', 'OBSIDIAN_VAULT_PATH')
        if ($ExtraSwitch) { $keys += $ExtraSwitch }
        $prev = @{}
        foreach ($k in $keys) { $prev[$k] = [Environment]::GetEnvironmentVariable($k) }
        try {
            $env:CLAUDE_SKIP_MCP_PROBE = '1'
            $env:CLAUDE_SKIP_FRESHNESS_CHECK = '1'
            $env:CLAUDE_SKIP_LOCAL_HOOK_CHECK = '1'
            $env:CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE = '1'
            $env:CLAUDE_CONFIG_DIR = (Join-Path $hkdn_tmp 'cfg')
            $env:OBSIDIAN_VAULT_PATH = $Vault
            if ($ExtraSwitch) { [Environment]::SetEnvironmentVariable($ExtraSwitch, '1') }
            $out = '{"source":"startup"}' | & pwsh -NoProfile -File $hkdn_hook 2>$null
            $rc = $LASTEXITCODE
            if ($out -is [array]) { $out = $out -join "`n" }
            return @{ Out = [string]$out; Rc = $rc }
        } finally {
            foreach ($k in $keys) { [Environment]::SetEnvironmentVariable($k, $prev[$k]) }
        }
    }
    $hkdn_vault = Join-Path $hkdn_tmp 'vault'

    # lapse -> exit 0, header names the count, list names the note.
    $hkdn_r = Invoke-DistHook -Vault $hkdn_vault
    if ($hkdn_r.Rc -eq 0) {
        _Pass 'hooks-ps-parity.test: claude framework-surface.ps1 distillation lapse exits 0'
    } else {
        _Fail 'hooks-ps-parity.test: claude framework-surface.ps1 distillation lapse exits 0' "exit $($hkdn_r.Rc)"
    }
    if ($hkdn_r.Out.Contains('Distillation lag — 1 feedback/decision note(s) not yet distilled') -and $hkdn_r.Out.Contains('feedback-test-lapse-note')) {
        _Pass 'hooks-ps-parity.test: claude framework-surface.ps1 surfaces the distillation lapse + note name'
    } else {
        _Fail 'hooks-ps-parity.test: claude framework-surface.ps1 should surface the distillation lapse + note name' "got: $($hkdn_r.Out)"
    }

    # distilled (name recorded in a lessons note) -> nudge absent.
    $hkdn_lesson = Join-Path $hkdn_tmp 'vault' '04-Lessons' 'thematic-lesson.md'
    [System.IO.File]::WriteAllText($hkdn_lesson, "# Thematic lesson`n`n## Source Notes`n`n- feedback-test-lapse-note`n", $hkdn_utf8)
    $hkdn_r = Invoke-DistHook -Vault $hkdn_vault
    if ($hkdn_r.Out.Contains('Distillation lag')) {
        _Fail 'hooks-ps-parity.test: claude framework-surface.ps1 distilled note should drop the nudge' "got: $($hkdn_r.Out)"
    } else {
        _Pass 'hooks-ps-parity.test: claude framework-surface.ps1 distilled note drops the nudge'
    }

    # kill switch (lapse restored) -> nudge absent.
    Remove-Item -LiteralPath $hkdn_lesson -Force -ErrorAction SilentlyContinue
    $hkdn_r = Invoke-DistHook -Vault $hkdn_vault -ExtraSwitch 'CLAUDE_SKIP_DISTILLATION_NUDGE'
    if ($hkdn_r.Out.Contains('Distillation lag')) {
        _Fail 'hooks-ps-parity.test: claude framework-surface.ps1 CLAUDE_SKIP_DISTILLATION_NUDGE=1 should drop the nudge' "got: $($hkdn_r.Out)"
    } else {
        _Pass 'hooks-ps-parity.test: claude framework-surface.ps1 CLAUDE_SKIP_DISTILLATION_NUDGE=1 drops the nudge'
    }

    # unresolvable vault (nonexistent dir) -> checker exit 2 -> fail-open silent.
    $hkdn_r = Invoke-DistHook -Vault (Join-Path $hkdn_tmp 'nope')
    if ($hkdn_r.Rc -eq 0) {
        _Pass 'hooks-ps-parity.test: claude framework-surface.ps1 unresolvable vault exits 0'
    } else {
        _Fail 'hooks-ps-parity.test: claude framework-surface.ps1 unresolvable vault exits 0' "exit $($hkdn_r.Rc)"
    }
    if ($hkdn_r.Out.Contains('Distillation lag')) {
        _Fail 'hooks-ps-parity.test: claude framework-surface.ps1 unresolvable vault should stay silent' "got: $($hkdn_r.Out)"
    } else {
        _Pass 'hooks-ps-parity.test: claude framework-surface.ps1 unresolvable vault stays silent'
    }
} finally {
    Remove-Item -LiteralPath $hkdn_tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 4. Cursor PS hook behavior (panel fix A9) -------------------------------
# The cursor .ps1 hooks' runtime logic (payload parse, fail-closed error paths,
# gate detection, smuggling refusal, directive emission) was previously
# untested on every lane — install-cursor.test.ps1 _Skips it pointing here.
# Stage the SOURCE hooks in a temp home (<home>/hooks/) so the hook's
# config-home resolution (parent of $PSScriptRoot) lands in the temp dir and
# gate-marker writes stay out of the repo. framework-surface.ps1 carries the
# @@AI_CONFIG_DIR@@ build placeholder — substitute it the way install.ps1 does.
$hkcu_tmp = Join-Path ([IO.Path]::GetTempPath()) ('hkcu-ps-' + [Guid]::NewGuid().Guid.Substring(0,8))
$hkcu_hooks = Join-Path $hkcu_tmp 'hooks'
New-Item -ItemType Directory -Path $hkcu_hooks -Force | Out-Null
try {
    $hkcu_src = Join-Path $env:REPO_ROOT 'harnesses' 'cursor' 'hooks'
    Copy-Item (Join-Path $hkcu_src 'session-agent.ps1') $hkcu_hooks
    $hkcu_fs_body = [System.IO.File]::ReadAllText((Join-Path $hkcu_src 'framework-surface.ps1'))
    $hkcu_fs_body = $hkcu_fs_body.Replace('@@AI_CONFIG_DIR@@', $env:REPO_ROOT)
    $hkcu_fs = Join-Path $hkcu_hooks 'framework-surface.ps1'
    [System.IO.File]::WriteAllText($hkcu_fs, $hkcu_fs_body, [System.Text.UTF8Encoding]::new($false))

    $hkcu_gatehook = Join-Path $hkcu_hooks 'session-agent.ps1'
    $hkcu_cid = 'pstestconv01'
    $hkcu_state = Join-Path $hkcu_tmp 'agentic-os'
    $hkcu_gatefile = Join-Path $hkcu_state "gate-$hkcu_cid"

    function Get-CursorGateDecision {
        param([string]$Payload)
        $out = $Payload | & pwsh -NoProfile -File $hkcu_gatehook 2>$null
        if ($out -is [array]) { $out = $out -join "`n" }
        try { return ([string]$out | ConvertFrom-Json).permission } catch { return "unparseable:[$out]" }
    }

    # The two halves of the decision: user_message is what the Cursor operator
    # reads, agent_message is what the model reads.
    function Get-CursorGateMessage {
        param([string]$Payload)
        $out = $Payload | & pwsh -NoProfile -File $hkcu_gatehook 2>$null
        if ($out -is [array]) { $out = $out -join "`n" }
        try { return [string]([string]$out | ConvertFrom-Json).user_message } catch { return "unparseable:[$out]" }
    }
    function Get-CursorGateAgentMessage {
        param([string]$Payload)
        $out = $Payload | & pwsh -NoProfile -File $hkcu_gatehook 2>$null
        if ($out -is [array]) { $out = $out -join "`n" }
        try { return [string]([string]$out | ConvertFrom-Json).agent_message } catch { return "unparseable:[$out]" }
    }

    # 4a. plain Write, gate closed -> deny.
    $p = @{ conversation_id = $hkcu_cid; tool_name = 'Write'
            tool_input = @{ file_path = '/tmp/x.txt'; content = 'hi' }; cwd = '/tmp' } |
        ConvertTo-Json -Compress -Depth 5
    Assert-Eq 'hooks-ps-parity.test: cursor gate denies a Write before the gate is open' 'deny' (Get-CursorGateDecision $p)

    # 4b. the gate-declaration write itself (destination == gate file, both
    # contract lines in content) -> allow.
    $p = @{ conversation_id = $hkcu_cid; tool_name = 'Write'
            tool_input = @{ file_path = $hkcu_gatefile
                            content = "Routing: x`nLessons: none match`nLinear gate: none - single-step" }
            cwd = '/tmp' } | ConvertTo-Json -Compress -Depth 5
    Assert-Eq 'hooks-ps-parity.test: cursor gate allows the declaration write' 'allow' (Get-CursorGateDecision $p)

    # 4c. CONTENT SMUGGLING denied (panel fix A3): file_path present and
    # pointing elsewhere while the content merely mentions the gate path + lines.
    $p = @{ conversation_id = $hkcu_cid; tool_name = 'Write'
            tool_input = @{ file_path = '/tmp/unrelated.js'
                            content = "// $hkcu_gatefile`n// Linear gate: none - single-step`n// Lessons: none match" }
            cwd = '/tmp' } | ConvertTo-Json -Compress -Depth 5
    Assert-Eq 'hooks-ps-parity.test: cursor gate denies a smuggled gate path in unrelated content' 'deny' (Get-CursorGateDecision $p)

    # 4d. marker on disk with both lines -> subsequent writes allowed.
    New-Item -ItemType Directory -Path $hkcu_state -Force | Out-Null
    [System.IO.File]::WriteAllText($hkcu_gatefile,
        "Routing: x`nLessons: none match`nLinear gate: none - single-step`n",
        [System.Text.UTF8Encoding]::new($false))
    $p = @{ conversation_id = $hkcu_cid; tool_name = 'Write'
            tool_input = @{ file_path = '/tmp/x.txt'; content = 'hi' } } |
        ConvertTo-Json -Compress -Depth 5
    Assert-Eq 'hooks-ps-parity.test: cursor gate opens once the marker is declared' 'allow' (Get-CursorGateDecision $p)

    # 4e. error paths DENY (fail-closed; Cursor default is fail-open).
    Assert-Eq 'hooks-ps-parity.test: cursor gate denies a payload with no conversation_id' 'deny' `
        (Get-CursorGateDecision '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}')
    Assert-Eq 'hooks-ps-parity.test: cursor gate denies an unparseable payload' 'deny' `
        (Get-CursorGateDecision 'not json at all')
    Assert-Eq 'hooks-ps-parity.test: cursor gate denies a path-separator conversation_id' 'deny' `
        (Get-CursorGateDecision '{"conversation_id":"../../etc","tool_name":"Write"}')

    # 4f. kill switch -> allow.
    $env:CLAUDE_SKIP_SESSION_AGENT = '1'
    try {
        Assert-Eq 'hooks-ps-parity.test: cursor gate kill switch allows' 'allow' `
            (Get-CursorGateDecision '{"conversation_id":"otherconv","tool_name":"Write"}')
    } finally { Remove-Item Env:CLAUDE_SKIP_SESSION_AGENT -ErrorAction SilentlyContinue }

    # 4g. framework-surface emits a directive with valid JSON + real session id
    # interpolated into the gate path (panel fix A1).
    $fsOut = ('{"session_id":"' + $hkcu_cid + '","is_background_agent":false,"composer_mode":"agent"}') |
        & pwsh -NoProfile -File $hkcu_fs 2>$null
    if ($fsOut -is [array]) { $fsOut = $fsOut -join "`n" }
    $fsCtx = ''
    try { $fsCtx = ([string]$fsOut | ConvertFrom-Json).additional_context } catch {}
    if ($fsCtx -and $fsCtx.Contains("gate-$hkcu_cid")) {
        _Pass 'hooks-ps-parity.test: cursor framework-surface interpolates the real session id into the gate path'
    } else {
        _Fail 'hooks-ps-parity.test: cursor framework-surface interpolates the real session id into the gate path' `
            "additional_context: $fsCtx"
    }

    # 4h. ask-mode composer suppresses the kickoff directive.
    $fsAsk = ('{"session_id":"' + $hkcu_cid + '","composer_mode":"ask"}') |
        & pwsh -NoProfile -File $hkcu_fs 2>$null
    if ($fsAsk -is [array]) { $fsAsk = $fsAsk -join "`n" }
    $fsAskCtx = ''
    try { $fsAskCtx = ([string]$fsAsk | ConvertFrom-Json).additional_context } catch {}
    if ($fsAskCtx -and $fsAskCtx.Contains('kickoff orient')) {
        _Fail 'hooks-ps-parity.test: cursor framework-surface suppresses the directive in ask-mode' "got: $fsAskCtx"
    } else {
        _Pass 'hooks-ps-parity.test: cursor framework-surface suppresses the directive in ask-mode'
    }

    # 4i. whole-hook kill switch silences the surfacing hook (fail-open by design).
    $env:CLAUDE_SKIP_FRAMEWORK_SURFACE = '1'
    try {
        $fsQuiet = '{"session_id":"x"}' | & pwsh -NoProfile -File $hkcu_fs 2>$null
        if ($fsQuiet -is [array]) { $fsQuiet = $fsQuiet -join "`n" }
        Assert-Eq 'hooks-ps-parity.test: cursor framework-surface kill switch silences it' '' ([string]$fsQuiet)
    } finally { Remove-Item Env:CLAUDE_SKIP_FRAMEWORK_SURFACE -ErrorAction SilentlyContinue }

    # 4j. THE DENY NAMES THE MARKER PATH. `user_message` is the only half the
    # operator sees; a fixed "blocked, see the agent message" text made every
    # fresh conversation spend a sacrificial deny discovering where to write.
    # BOTH halves must carry it — the model reads agent_message, and that copy is
    # what the realization's "one deliberate gate-less Write" step relies on.
    $hkcu_cid2 = 'pstestconv02'
    $p = @{ conversation_id = $hkcu_cid2; tool_name = 'Write'
            tool_input = @{ file_path = '/tmp/other.txt'; content = 'hi' }; cwd = '/tmp' } |
        ConvertTo-Json -Compress -Depth 5
    Assert-Contains 'hooks-ps-parity.test: cursor deny user_message names the literal gate-marker path' `
        (Get-CursorGateMessage $p) (Join-Path $hkcu_state "gate-$hkcu_cid2")
    Assert-Contains 'hooks-ps-parity.test: cursor deny agent_message names the same gate-marker path' `
        (Get-CursorGateAgentMessage $p) (Join-Path $hkcu_state "gate-$hkcu_cid2")

    # 4k. EARLY denies cannot key ANY marker — there is no usable conversation
    # id, so no path would unblock the call. The message names the CAUSE and the
    # kill switch instead of sending the reader to a dead-end file.
    foreach ($hkcu_early in @(
            '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}',
            '{"conversation_id":"../../etc","tool_name":"Write"}',
            'not json at all')) {
        $hkcu_early_msg = Get-CursorGateMessage $hkcu_early
        Assert-Contains 'hooks-ps-parity.test: cursor early deny names the no-usable-id cause' `
            $hkcu_early_msg 'no usable conversation id'
        Assert-Contains 'hooks-ps-parity.test: cursor early deny names the kill switch' `
            $hkcu_early_msg 'CLAUDE_SKIP_SESSION_AGENT=1'
    }

    # 4l. the conversation-id side file. sessionStart publishes the id to
    # <config>/agentic-os/current-session so a model that lost the injected
    # directive can read it back. The write must never change this hook's exit
    # or stdout — it is fail-OPEN, and a broken state write may not break a
    # session.
    $hkcu_side = Join-Path $hkcu_state 'current-session'
    Remove-Item -LiteralPath $hkcu_side -Force -ErrorAction SilentlyContinue
    $sideOut = '{"session_id":"abc123","composer_mode":"agent"}' | & pwsh -NoProfile -File $hkcu_fs 2>$null
    $sideRc = $LASTEXITCODE
    if ($sideOut -is [array]) { $sideOut = $sideOut -join "`n" }
    Assert-Eq 'hooks-ps-parity.test: cursor sessionStart still exits 0 while writing the side file' '0' "$sideRc"
    Assert-Contains 'hooks-ps-parity.test: cursor sessionStart still emits additional_context' `
        ([string]$sideOut) 'additional_context'
    $sideBytes = @()
    if (Test-Path -LiteralPath $hkcu_side) { $sideBytes = [System.IO.File]::ReadAllBytes($hkcu_side) }
    Assert-Eq 'hooks-ps-parity.test: cursor sessionStart writes session_id to the side file' 'abc123' `
        (([string]([System.Text.Encoding]::UTF8.GetString($sideBytes))).TrimEnd("`n"))
    # LF + no BOM + exactly one line: byte-identical to the bash twin's printf.
    Assert-Eq 'hooks-ps-parity.test: cursor side file is 7 bytes, LF-terminated, no BOM' '7' "$($sideBytes.Count)"
    Assert-Contains 'hooks-ps-parity.test: cursor directive names the side file as the id re-read path' `
        ([string]$sideOut) 'agentic-os/current-session'

    # OVERWRITE + the preToolUse spelling in one fixture: the file is NOT deleted
    # between the two runs, so this also pins last-writer-wins — and it is the
    # only coverage of `Move-Item -Force` over an EXISTING destination.
    '{"conversation_id":"def456","composer_mode":"agent"}' | & pwsh -NoProfile -File $hkcu_fs 2>$null | Out-Null
    $sideBytes2 = @()
    if (Test-Path -LiteralPath $hkcu_side) { $sideBytes2 = [System.IO.File]::ReadAllBytes($hkcu_side) }
    Assert-Eq 'hooks-ps-parity.test: cursor second sessionStart overwrites the side file' 'def456' `
        (([string]([System.Text.Encoding]::UTF8.GetString($sideBytes2))).TrimEnd("`n"))
    Assert-Eq 'hooks-ps-parity.test: cursor overwritten side file is 7 bytes, LF, no BOM' '7' `
        "$($sideBytes2.Count)"

    # An id the gate would refuse never forms a usable marker path, so
    # publishing it would hand the model a broken one — write nothing, and say
    # nothing about a side file (a directive naming a path holding some OTHER
    # conversation's id is worse than no sentence at all).
    Remove-Item -LiteralPath $hkcu_side -Force -ErrorAction SilentlyContinue
    $badOut = '{"session_id":"a/b","composer_mode":"agent"}' | & pwsh -NoProfile -File $hkcu_fs 2>$null
    $badRc = $LASTEXITCODE
    if ($badOut -is [array]) { $badOut = $badOut -join "`n" }
    Assert-Eq 'hooks-ps-parity.test: cursor unsafe session id still exits 0' '0' "$badRc"
    Assert-Contains 'hooks-ps-parity.test: cursor unsafe session id still emits additional_context' `
        ([string]$badOut) 'additional_context'
    Assert-NotContains 'hooks-ps-parity.test: cursor unsafe session id emits no side-file sentence' `
        ([string]$badOut) 'current-session'
    if (Test-Path -LiteralPath $hkcu_side) {
        _Fail 'hooks-ps-parity.test: cursor unsafe session id is never published to the side file' `
            "wrote: $([System.IO.File]::ReadAllText($hkcu_side))"
    } else {
        _Pass 'hooks-ps-parity.test: cursor unsafe session id is never published to the side file'
    }

    # WRITE FAILURE: a usable id whose write cannot land must not produce a
    # directive claiming it did. Force it by putting a regular FILE where the
    # state dir belongs, then restore the directory.
    Remove-Item -LiteralPath $hkcu_state -Recurse -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($hkcu_state, '', [System.Text.UTF8Encoding]::new($false))
    $failOut = '{"session_id":"xyz789","composer_mode":"agent"}' | & pwsh -NoProfile -File $hkcu_fs 2>$null
    $failRc = $LASTEXITCODE
    if ($failOut -is [array]) { $failOut = $failOut -join "`n" }
    Assert-Eq 'hooks-ps-parity.test: cursor failed side-file write still exits 0' '0' "$failRc"
    Assert-Contains 'hooks-ps-parity.test: cursor failed side-file write still emits additional_context' `
        ([string]$failOut) 'additional_context'
    Assert-NotContains 'hooks-ps-parity.test: cursor failed side-file write claims no side file' `
        ([string]$failOut) 'current-session'
    Remove-Item -LiteralPath $hkcu_state -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $hkcu_state -Force | Out-Null
} finally {
    Remove-Item -LiteralPath $hkcu_tmp -Recurse -Force -ErrorAction SilentlyContinue
}
