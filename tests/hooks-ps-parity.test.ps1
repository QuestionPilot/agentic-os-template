#Requires -Version 7
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
    $trans = Join-Path $hkps_tmpdir 'trans-sa-fwd.txt'
    Write-LfFile $trans "I read skills/session-agent/SKILL.md`nLinear gate: PROJ-1`n"
    $payload = '{"transcript_path":"' + ($trans -replace '\\', '/') + '"}'
    $out = Invoke-CodexHook -HookPath $hkps_codex_sa -Payload $payload
    if (-not $out) {
        _Pass 'hooks-ps-parity.test: codex session-agent.ps1 ALLOWS forward-slash marker'
    } else {
        _Fail 'hooks-ps-parity.test: codex session-agent.ps1 should ALLOW forward-slash marker + Linear gate' `
            "got non-empty output: $out"
    }

    # 3b — codex session-agent.ps1, BACKSLASH marker ALLOWS (F-1 fix).
    $trans = Join-Path $hkps_tmpdir 'trans-sa-bs.txt'
    # The bash test wrote `\\\\` in printf which becomes 2 literal backslashes
    # on disk; on Windows JSON-decoded transcripts the marker arrives as 2
    # backslashes between segments. Write 2 literal backslashes here.
    Write-LfFile $trans "I read skills\\session-agent\\SKILL.md`nLinear gate: PROJ-1`n"
    $payload = '{"transcript_path":"' + ($trans -replace '\\', '/') + '"}'
    $out = Invoke-CodexHook -HookPath $hkps_codex_sa -Payload $payload
    if (-not $out) {
        _Pass 'hooks-ps-parity.test: codex session-agent.ps1 ALLOWS backslash marker'
    } else {
        _Fail 'hooks-ps-parity.test: codex session-agent.ps1 should ALLOW backslash marker + Linear gate' `
            "got non-empty output: $out"
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
