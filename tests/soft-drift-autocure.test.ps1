#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/soft-drift-autocure.test.ps1 — Windows-native twin of
# tests/soft-drift-autocure.test.sh.
#
# check-drift.ps1 --cure-soft-drift behavior. Tests the opt-in auto-cure for
# settings.json soft drift. theme/effortLevel are operator-local preference keys
# the spine-only base does NOT ship (carried by install.ps1 preserve-live); the
# soft envelope is simulated by ADDING operator-set soft keys the opinion-free
# canonical base lacks.
#
# Mirrors tests/soft-drift-autocure.test.sh 1:1, using pwsh install.ps1
# check-drift.ps1 instead of bash counterparts.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$INSTALL_PS1     = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$CHECK_DRIFT_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'check-drift.ps1'
Assert-File 't-106.test: scripts/install.ps1 exists' $INSTALL_PS1
Assert-File 't-106.test: scripts/check-drift.ps1 exists' $CHECK_DRIFT_PS1

function New-Q106Target {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('q106-' + [Guid]::NewGuid().Guid.Substring(0,8))
    $out = Join-Path $tmp 'target'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $envFile = Join-Path $tmp 'local.env'
    Write-LocalEnvFixture -EnvFile $envFile -ConfigDir $out -VaultDir (Join-Path $tmp 'vault')
    $env:AI_CONFIG_LOCAL_ENV = $envFile
    try {
        & pwsh -NoProfile -File $INSTALL_PS1 --harness claude *>$null
    } finally {
        Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
    }
    return @{ Root = $tmp; Out = $out; Env = $envFile }
}

function Invoke-Jq-File {
    param([string]$Path, [string]$Filter)
    $tmp = $Path + '.tmp'
    # Capture jq output and then rename atomically.
    $out = & jq $Filter $Path 2>$null
    if ($out -is [array]) { $out = $out -join "`n" }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tmp, $out, $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Read one scalar out of a JSON file with `jq -r`. pwsh hands back a string[]
# when the child writes more than one line, so coerce with the file's -join
# idiom before comparing.
function Invoke-Jq-Read {
    param([string]$Path, [string]$Filter)
    $out = & jq -r $Filter $Path 2>$null
    if ($out -is [array]) { $out = $out -join '' }
    return "$out"
}

# Re-render an already-built target through install.ps1 (the bash twin's second
# `install.sh` run). AI_CONFIG_LOCAL_ENV must point at the target's fixture
# local.env for the render to find it — set before, removed in `finally`,
# exactly as New-Q106Target does.
function Invoke-Q106Reinstall {
    param([Parameter(Mandatory)][hashtable]$Target)
    $code = -1
    $env:AI_CONFIG_LOCAL_ENV = $Target.Env
    try {
        & pwsh -NoProfile -File $INSTALL_PS1 --harness claude *>$null
        $code = $LASTEXITCODE
    } finally {
        Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
    }
    # A swallowed re-render failure leaves the manifest at the FIRST render
    # while the live settings.json already carries the operator keys — the
    # setup assertion would then pass while proving nothing. Fail loudly.
    if ($code -ne 0) { throw "install.ps1 re-render failed (exit $code) for $($Target.Out)" }
}

# realpath semantics for a directory path. The bash twin compares `pwd -P`
# output; Resolve-Path does NOT resolve symlinks, so a /tmp-style alias would
# make a plain checkout look like a linked worktree (or vice versa). Walk the
# components substituting link targets, restarting after every substitution
# (a target may itself be spelled through other links). Mirrors
# Get-PhysicalDirPath in scripts/validate.ps1, including its bounded pass
# count and its fail-CLOSED behavior when that bound is exhausted.
function Get-Q106PhysicalPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    try { $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { return '' }
    $seps = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    for ($pass = 0; $pass -lt 40; $pass++) {
        $root = [IO.Path]::GetPathRoot($full)
        $cur = $root
        $comps = $full.Substring($root.Length).Split($seps, [StringSplitOptions]::RemoveEmptyEntries)
        $substituted = $false
        for ($i = 0; $i -lt $comps.Length; $i++) {
            $cur = Join-Path $cur $comps[$i]
            $item = Get-Item -LiteralPath $cur -Force -ErrorAction SilentlyContinue
            if (-not $item -or -not $item.PSObject.Properties['LinkTarget'] -or [string]::IsNullOrEmpty($item.LinkTarget)) { continue }
            $t = $item.LinkTarget
            # IsPathFullyQualified, not IsPathRooted: a Windows ROOT-RELATIVE
            # target (\config on drive D:) passes IsPathRooted, and GetFullPath
            # would bind it to the PROCESS's current drive — resolve it against
            # the LINK's own path root instead.
            if (-not [IO.Path]::IsPathFullyQualified($t)) {
                if ([IO.Path]::IsPathRooted($t)) {
                    $t = Join-Path ([IO.Path]::GetPathRoot($cur)) ($t.TrimStart('\', '/'))
                } else {
                    # Split-Path '/var' -Parent yields '' (not '/') on Unix pwsh
                    # — a FIRST-LEVEL symlink (macOS /var, /tmp, /etc) would
                    # bind an empty -Path to Join-Path. Fall back to the root.
                    $parent = Split-Path -Path $cur -Parent
                    if ([string]::IsNullOrEmpty($parent)) { $parent = $root }
                    $t = Join-Path $parent $t
                }
            }
            $full = [IO.Path]::GetFullPath($t)
            for ($j = $i + 1; $j -lt $comps.Length; $j++) { $full = Join-Path $full $comps[$j] }
            $substituted = $true
            break
        }
        if (-not $substituted) { return $full }
    }
    # Bound exhausted (cycle or a 40+ link chain): the path still holds an
    # unresolved component. Returning it would leak a non-physical spelling
    # from a function whose contract is physical — fail closed with the same
    # '' the not-found path returns, exactly as validate.ps1 does.
    return ''
}

# ---------- Test 1: Default behavior unchanged on soft drift -----------------
$Q106 = New-Q106Target
$settingsPath = Join-Path $Q106.Out 'settings.json'
# Add operator-set soft keys (spine-only base ships neither) — the soft envelope.
Invoke-Jq-File -Path $settingsPath -Filter '. + {theme: "auto", effortLevel: "xhigh"}'

Assert-Exit 't-106.test: default behavior unchanged: soft-drift still fails without --cure-soft-drift' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106.Out
# The read-only failure names the one-line cure (operator hint only — no write).
$q106NoteOut = (& pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106.Out 2>&1 | Out-String)
Assert-Contains 't-106.test: soft-drift without the flag names the one-line cure' $q106NoteOut '--cure-soft-drift --manifest'
# ...and the hint NEVER writes. Hash settings.json across a no-cure run and
# require byte-identity — the read-only gate must stay read-only.
$q106HashBefore = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
& pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106.Out *>$null
$q106HashAfter = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
Assert-Eq 't-106.test: the no-cure NOTE run never writes settings.json' $q106HashBefore $q106HashAfter

# ---------- Test 2: --cure-soft-drift cures the soft-drift case --------------
# Same fixture (operator-set soft keys) — adding the flag MUST cure via
# install.ps1 re-render and exit 0.
$env:AI_CONFIG_LOCAL_ENV = $Q106.Env
try {
    Assert-Exit 't-106.test: --cure-soft-drift cures soft keys (theme + effortLevel)' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106.Out --cure-soft-drift
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}

# Verify the cure CARRIED the operator's soft keys via preserve-live: the cure
# re-render reads the live settings.json as the overlay source, so the
# operator's theme/effortLevel survive — preserved from the live file, NOT
# restored from base (the spine-only base no longer ships them).
Assert-Eq "t-106.test: post-cure: operator theme preserved as 'auto'" 'auto' (Invoke-Jq-Read -Path $settingsPath -Filter '.theme // "MISSING"')
Assert-Eq "t-106.test: post-cure: operator effortLevel preserved as 'xhigh'" 'xhigh' (Invoke-Jq-Read -Path $settingsPath -Filter '.effortLevel // "MISSING"')

# Final state: clean drift check now passes (post-cure verification).
Assert-Exit 't-106.test: post-cure: drift check passes from scratch' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106.Out

Remove-Item -LiteralPath $Q106.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Test 2b: app-strip of operator soft keys cures to converged state -
# Pins the post-spine-only contract: a stripped operator soft key is NOT
# resurrected by the cure (operator-local, no base source). The operator's soft
# keys are preserved into a prior render (recorded in the manifest via
# preserve-live), then the app STRIPS them from the live settings.json; because
# the spine-only base ships neither key, the cure's opinion-free canonical also
# lacks them, so the cure converges the manifest to the stripped state.
$Q106M = New-Q106Target
$settingsPath = Join-Path $Q106M.Out 'settings.json'
Invoke-Jq-File -Path $settingsPath -Filter '. + {theme: "dark", effortLevel: "xhigh"}'
# Re-render so the manifest records the operator soft keys (preserve-live).
Invoke-Q106Reinstall -Target $Q106M
# "Recorded" is a claim about the MANIFEST, so read it from there, not from the
# live file the fixture wrote. The manifest stores generated outputs as
# {path: sha256} — no values — so the manifest-side proof is that its
# settings.json hash matches the live file's bytes (the re-render recorded THIS
# file); the live file's operator key is then the second assertion below.
# (Invoke-Q106Reinstall already throws on a non-zero re-render exit — the .sh
# twin's `assert_exit ... 0` on its second install.sh run is that same guard.)
$q106mManifest = Join-Path $Q106M.Out '.build-manifest.json'
$q106mRecorded = Invoke-Jq-Read -Path $q106mManifest -Filter '.generated["settings.json"] // "MISSING"'
$q106mLiveHash = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Eq 't-106.test: preserve-live re-render recorded the live settings.json in the manifest' $q106mRecorded $q106mLiveHash
Assert-Eq 't-106.test: preserve-live recorded operator effortLevel before strip' 'xhigh' (Invoke-Jq-Read -Path $settingsPath -Filter '.effortLevel // "MISSING"')

# The Claude Code app strips both soft keys from the live file.
Invoke-Jq-File -Path $settingsPath -Filter 'del(.theme, .effortLevel)'
# Cure: soft envelope matches (canonical also lacks the keys); cure converges.
$env:AI_CONFIG_LOCAL_ENV = $Q106M.Env
try {
    Assert-Exit 't-106.test: app-strip of operator soft keys cures (soft envelope)' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106M.Out --cure-soft-drift
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}
# Post-cure: the stripped keys are NOT resurrected (operator-local, no base source).
Assert-Eq 't-106.test: post-cure: stripped theme not resurrected (operator-local)' 'MISSING' (Invoke-Jq-Read -Path $settingsPath -Filter '.theme // "MISSING"')
Assert-Eq 't-106.test: post-cure: stripped effortLevel not resurrected (operator-local)' 'MISSING' (Invoke-Jq-Read -Path $settingsPath -Filter '.effortLevel // "MISSING"')
# And the drift check now passes (manifest converged to the stripped render).
Assert-Exit 't-106.test: post-cure: drift check passes after app-strip cure' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106M.Out

Remove-Item -LiteralPath $Q106M.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Test 2c: app-written notification keys cure as soft drift --------
# Mirrors the .sh twin: agentPushNotifEnabled + inputNeededNotifEnabled are
# app-written operator-local preference keys the spine-only base does not ship,
# so every real-world machine drifts on exactly these two. The cure must absorb
# them and the cure re-render must CARRY both via preserve-live — a dropped key
# would just be re-written by the app and restart the drift cycle.
$Q106P = New-Q106Target
$settingsPath = Join-Path $Q106P.Out 'settings.json'
Invoke-Jq-File -Path $settingsPath -Filter '. + {agentPushNotifEnabled: false, inputNeededNotifEnabled: true}'

$env:AI_CONFIG_LOCAL_ENV = $Q106P.Env
try {
    Assert-Exit 't-106.test: --cure-soft-drift absorbs app-written notification keys' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106P.Out --cure-soft-drift
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}

Assert-Eq 't-106.test: post-cure: agentPushNotifEnabled preserved through cure re-render' 'false' (Invoke-Jq-Read -Path $settingsPath -Filter 'if has("agentPushNotifEnabled") then (.agentPushNotifEnabled | tostring) else "DROPPED" end')
Assert-Eq 't-106.test: post-cure: inputNeededNotifEnabled preserved through cure re-render' 'true' (Invoke-Jq-Read -Path $settingsPath -Filter 'if has("inputNeededNotifEnabled") then (.inputNeededNotifEnabled | tostring) else "DROPPED" end')

Assert-Exit 't-106.test: post-cure: drift check passes after notification-key cure' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106P.Out

Remove-Item -LiteralPath $Q106P.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Test 2d: app-written tui mode cures as soft drift ----------------
# Mirrors the .sh twin: `tui` ("default" | "fullscreen") is written into the
# live settings.json by the harness app when the operator toggles the TUI mode
# — an operator-local preference of the same class as theme/effortLevel and the
# notification flags. The cure must absorb it and the cure re-render must carry
# it via preserve-live.
$Q106T = New-Q106Target
$settingsPath = Join-Path $Q106T.Out 'settings.json'
Invoke-Jq-File -Path $settingsPath -Filter '. + {tui: "fullscreen"}'

$env:AI_CONFIG_LOCAL_ENV = $Q106T.Env
try {
    Assert-Exit 't-106.test: --cure-soft-drift absorbs the app-written tui mode' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106T.Out --cure-soft-drift
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}

# Caveat mirrored from the .sh twin: the cure deliberately re-renders via the
# MAIN repo's install script when it runs from a linked worktree (Gate 4,
# pinned by Test 11), so from a worktree these two would measure MAIN's overlay
# rather than this tree's. They are SKIPPED there with the reason named — never
# silently — and the overlay itself is pinned by compiler.test.ps1's
# preserve-live round-trip, which renders with THIS tree's install.ps1. On a
# normal checkout (CI's clean clone) they run for real.
$q106tTop = ''
$q106tMain = ''
if (Get-Command git -ErrorAction SilentlyContinue) {
    Push-Location $env:REPO_ROOT
    try {
        $q106tTop = & git rev-parse --show-toplevel 2>$null
        if ($q106tTop -is [array]) { $q106tTop = $q106tTop -join '' }
        $q106tTop = Get-Q106PhysicalPath "$q106tTop"
        $q106tCommon = & git rev-parse --git-common-dir 2>$null
        if ($q106tCommon -is [array]) { $q106tCommon = $q106tCommon -join '' }
        if ($q106tCommon) {
            if (-not [IO.Path]::IsPathRooted($q106tCommon)) {
                $q106tCommon = Join-Path $env:REPO_ROOT $q106tCommon
            }
            $q106tCommon = Get-Q106PhysicalPath $q106tCommon
            if ($q106tCommon) {
                $q106tMain = Get-Q106PhysicalPath (Split-Path -Parent $q106tCommon)
            }
        }
    } finally {
        Pop-Location
    }
}

if ($q106tTop -and $q106tMain -and ($q106tTop -ne $q106tMain)) {
    _Skip 't-106.test: post-cure: tui preserved through cure re-render' `
        "linked worktree — the cure re-renders via the MAIN repo's install script, so this would measure main's preserve-live overlay, not this tree's (compiler.test pins this tree's overlay)"
    _Skip 't-106.test: post-cure: drift check passes after tui cure' `
        "linked worktree — same reason: a pass here would measure main's render, not this tree's"
} else {
    Assert-Eq 't-106.test: post-cure: tui preserved through cure re-render' 'fullscreen' (Invoke-Jq-Read -Path $settingsPath -Filter 'if has("tui") then (.tui | tostring) else "DROPPED" end')
    Assert-Exit 't-106.test: post-cure: drift check passes after tui cure' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106T.Out
}

Remove-Item -LiteralPath $Q106T.Root -Recurse -Force -ErrorAction SilentlyContinue
Remove-Variable -Name q106tTop, q106tMain, q106tCommon -ErrorAction SilentlyContinue

# ---------- Test 3: Real drift still errors even with --cure-soft-drift ------
# (Uses the PreToolUse hook — the only capability-wired hook after the closeout
# Stop gate was removed.)
$Q106B = New-Q106Target
$settingsPath = Join-Path $Q106B.Out 'settings.json'
Invoke-Jq-File -Path $settingsPath -Filter '.hooks.PreToolUse[0].hooks[0].command = "/tmp/malicious-hook.sh"'

Assert-Exit 't-106.test: real drift (hook command mutated) still fails with --cure-soft-drift' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106B.Out --cure-soft-drift

$cmdAfter = & jq -r '.hooks.PreToolUse[0].hooks[0].command' $settingsPath 2>$null
if ($cmdAfter -is [array]) { $cmdAfter = $cmdAfter -join '' }
Assert-Eq 't-106.test: real-drift case: install.sh re-render did NOT silently run' '/tmp/malicious-hook.sh' "$cmdAfter"

Remove-Item -LiteralPath $Q106B.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Test 4: Multi-file drift envelope rejects auto-cure --------------
$Q106C = New-Q106Target
$settingsPath = Join-Path $Q106C.Out 'settings.json'
Invoke-Jq-File -Path $settingsPath -Filter '. + {theme: "auto"}'
# Codex F-2 (MEDIUM): AppendAllText + UTF8NoBOM for byte-determinism on Windows.
[System.IO.File]::AppendAllText((Join-Path $Q106C.Out 'skills' 'session-agent' 'SKILL.md'), "`nHAND EDIT`n", [System.Text.UTF8Encoding]::new($false))

Assert-Exit 't-106.test: multi-file drift envelope (settings.json + skill) rejects --cure-soft-drift' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106C.Out --cure-soft-drift

Remove-Item -LiteralPath $Q106C.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Test 5: New non-soft top-level key rejects soft-cure -------------
$Q106D = New-Q106Target
$settingsPath = Join-Path $Q106D.Out 'settings.json'
Invoke-Jq-File -Path $settingsPath -Filter '. + {unexpectedKey: "operator wrote this"}'

Assert-Exit 't-106.test: non-soft top-level key (unexpectedKey) rejects --cure-soft-drift' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106D.Out --cure-soft-drift

$hasKey = & jq -r 'has("unexpectedKey")' $settingsPath 2>$null
if ($hasKey -is [array]) { $hasKey = $hasKey -join '' }
Assert-Eq 't-106.test: non-soft-drift case: cure did NOT silently overwrite' 'true' "$hasKey"

Remove-Item -LiteralPath $Q106D.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Test 6: --cure-soft-drift is position-insensitive ----------------
# The flag must work both before and after --manifest, so operator muscle
# memory does not matter.
$Q106E = New-Q106Target
$settingsPath = Join-Path $Q106E.Out 'settings.json'
Invoke-Jq-File -Path $settingsPath -Filter '. + {theme: "auto", effortLevel: "xhigh"}'

# Flag BEFORE --manifest.
$env:AI_CONFIG_LOCAL_ENV = $Q106E.Env
try {
    Assert-Exit 't-106.test: --cure-soft-drift accepts flag BEFORE --manifest' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --cure-soft-drift --manifest $Q106E.Out
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath $Q106E.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Test 7: Default mode (no --manifest) is unaffected ---------------
Assert-Exit 't-106.test: broad scan mode unaffected by --cure-soft-drift flag' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --cure-soft-drift

# ---------- Test 8: Type-change real drift on enabledPlugins rejected --------
$Q106F = New-Q106Target
$settingsPath = Join-Path $Q106F.Out 'settings.json'
Invoke-Jq-File -Path $settingsPath -Filter '.enabledPlugins = "malicious-value"'

Assert-Exit 't-106.test: type-change attack on enabledPlugins (object -> string) rejects --cure-soft-drift' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106F.Out --cure-soft-drift

$type = & jq -r '.enabledPlugins | type' $settingsPath 2>$null
if ($type -is [array]) { $type = $type -join '' }
Assert-Eq 't-106.test: type-change attack: cure did NOT silently restore object' 'string' "$type"

Remove-Item -LiteralPath $Q106F.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Test 9: Top-level non-object JSON rejected -----------------------
$Q106G = New-Q106Target
$settingsPath = Join-Path $Q106G.Out 'settings.json'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($settingsPath, "[]`n", $utf8NoBom)

Assert-Exit 't-106.test: top-level non-object settings.json rejects --cure-soft-drift' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106G.Out --cure-soft-drift

Remove-Item -LiteralPath $Q106G.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Test 10: Reorder-only positive case (extraKnownMarketplaces) -----
# Pins reorder-tolerance: a reorder-tolerant object whose keys are present in a
# DIFFERENT ORDER with identical values must be accepted as soft drift.
# extraKnownMarketplaces (framework-managed, two entries in settings.base.json)
# is the right surface — enabledPlugins is empty in the spine-only base and an
# enabledPlugins change is a detectable non-soft difference (Test 14).
$Q106H = New-Q106Target
$settingsPath = Join-Path $Q106H.Out 'settings.json'
# Reverse the extraKnownMarketplaces keys (SAME keys + values, different order).
# jq's from_entries preserves insertion order, so this produces a real reorder.
Invoke-Jq-File -Path $settingsPath -Filter '.extraKnownMarketplaces = (.extraKnownMarketplaces | to_entries | sort_by(.key) | reverse | from_entries)'

$env:AI_CONFIG_LOCAL_ENV = $Q106H.Env
try {
    Assert-Exit 't-106.test: extraKnownMarketplaces key reorder accepted as soft drift' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106H.Out --cure-soft-drift
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath $Q106H.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Test 14: enabledPlugins value-add is NOT silently cured ---------
# enabledPlugins is operator-owned, but --cure-soft-drift must NOT silently
# absorb a value-ADD into the canonical/manifest. The classifier builds its
# baseline opinion-free (AI_CONFIG_SKIP_PRESERVE_LIVE), so the add is a non-soft
# difference => cure refused => the operator resolves via a normal re-render.
$Q106L = New-Q106Target
$settingsPath = Join-Path $Q106L.Out 'settings.json'
# Hand/hostile edit: enable a plugin in the live config.
Invoke-Jq-File -Path $settingsPath -Filter '.enabledPlugins["injected@claude-plugins-official"] = true'

$env:AI_CONFIG_LOCAL_ENV = $Q106L.Env
try {
    Assert-Exit 't-106.test: enabledPlugins value-add is NOT cured by --cure-soft-drift (refused)' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106L.Out --cure-soft-drift
} finally {
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
}

# The cure must NOT have rewritten the manifest to bless the add — the default
# drift check still flags it.
Assert-Exit 't-106.test: post-refusal: injected plugin still flagged by default drift check' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106L.Out

# And the cure did not clobber the operator's live file either.
Assert-Eq 't-106.test: post-refusal: injected plugin still present in live settings.json' 'true' (Invoke-Jq-Read -Path $settingsPath -Filter '.enabledPlugins["injected@claude-plugins-official"] // false')

Remove-Item -LiteralPath $Q106L.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Test 11: Worktree guard --------------------------------------
$gitMarker1 = Join-Path $env:REPO_ROOT '.git'
$inGitRepo = (Test-Path -LiteralPath $gitMarker1)
if ($inGitRepo) {
    Push-Location $env:REPO_ROOT
    try {
        # Physical paths on BOTH sides. Resolve-Path does NOT resolve symlinks,
        # so a symlinked checkout (macOS /var -> /private/var) yields two
        # spellings of the same dir and the worktree/main comparison below — and
        # the rendered-path assertions — compare unequal strings for equal
        # directories. Get-Q106PhysicalPath is the file's existing `pwd -P`
        # equivalent, already used by Test 2d.
        $TOPLEVEL = & git rev-parse --show-toplevel 2>$null
        if ($TOPLEVEL -is [array]) { $TOPLEVEL = $TOPLEVEL -join '' }
        $TOPLEVEL = Get-Q106PhysicalPath "$TOPLEVEL"
        $COMMON_DIR = & git rev-parse --git-common-dir 2>$null
        if ($COMMON_DIR -is [array]) { $COMMON_DIR = $COMMON_DIR -join '' }
        if ($COMMON_DIR -and -not [IO.Path]::IsPathRooted($COMMON_DIR)) {
            $COMMON_DIR = Join-Path $env:REPO_ROOT $COMMON_DIR
        }
        if ($COMMON_DIR) { $COMMON_DIR = Get-Q106PhysicalPath $COMMON_DIR }
        $MAIN_ROOT_EXPECTED = ''
        if ($COMMON_DIR) {
            $MAIN_ROOT_EXPECTED = Get-Q106PhysicalPath (Split-Path -Parent $COMMON_DIR)
        }
    } finally {
        Pop-Location
    }

    if ($TOPLEVEL -and $MAIN_ROOT_EXPECTED -and ($TOPLEVEL -ne $MAIN_ROOT_EXPECTED)) {
        # We ARE in a linked worktree. Verify the cure works AND restored canonical.
        $Q106I = New-Q106Target
        $settingsPath = Join-Path $Q106I.Out 'settings.json'
        Invoke-Jq-File -Path $settingsPath -Filter '. + {theme: "auto", effortLevel: "xhigh"}'

        $env:AI_CONFIG_LOCAL_ENV = $Q106I.Env
        try {
            Assert-Exit 't-106.test: worktree case: --cure-soft-drift sources install.sh from main repo (still cures)' 0 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106I.Out --cure-soft-drift
        } finally {
            Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
        }

        # Exit 0 alone only proves SOME install script cured. Prove it was
        # MAIN's: the install script substitutes @@AI_CONFIG_DIR@@ with its OWN
        # repo root into the rendered hook scripts, so
        # hooks/framework-surface.ps1 carries the repo root of whichever script
        # ran. (settings.json cannot witness this — its hook commands are
        # target-relative.) Two spellings of the worktree are excluded: the
        # physical one, and REPO_ROOT as spelled — the latter is what a broken
        # Gate 4 would actually bake, since check-drift.ps1 derives its fallback
        # install-script path from its own location.
        # Fail-loud pins FIRST. Assert-Contains with an empty needle is a
        # tautology (String.Contains('') is always true) and Assert-NotContains
        # against an empty haystack is another, so an unresolved
        # MAIN_ROOT_EXPECTED / TOPLEVEL or a missing hook file would green the
        # main-root witness below. Pin every input non-empty, same shape as the
        # q106k* allowlist-extraction pins.
        $q106iHookPath = Join-Path $Q106I.Out 'hooks' 'framework-surface.ps1'
        Assert-Eq 't-106.test: worktree case: MAIN_ROOT_EXPECTED resolved non-empty' '1' ([string][int](([string]$MAIN_ROOT_EXPECTED).Length -gt 0))
        Assert-Eq 't-106.test: worktree case: TOPLEVEL resolved non-empty' '1' ([string][int](([string]$TOPLEVEL).Length -gt 0))
        Assert-File 't-106.test: worktree case: cure rendered the framework-surface hook' $q106iHookPath
        $q106iHook = ''
        if (Test-Path -LiteralPath $q106iHookPath) {
            $q106iHook = [string](Get-Content -LiteralPath $q106iHookPath -Raw)
        }
        Assert-Eq 't-106.test: worktree case: rendered hook body non-empty' '1' ([string][int]($q106iHook.Length -gt 0))
        # Needles are the FULL delimited assignment, not a raw substring: the PS
        # hook source line is `$AI_CONFIG_DIR = '@@AI_CONFIG_DIR@@'`, so the
        # rendered form is  $AI_CONFIG_DIR = '<root>'  and the closing quote
        # follows the path. A raw substring would false-RED a correct main root
        # at .../os-template against a worktree at .../os, and false-GREEN a
        # nested worktree whose path contains the main root.
        Assert-Contains 't-106.test: worktree case: cured hook carries the MAIN repo root' $q106iHook "`$AI_CONFIG_DIR = '$MAIN_ROOT_EXPECTED'"
        Assert-NotContains 't-106.test: worktree case: cured hook carries no worktree path (physical)' $q106iHook "`$AI_CONFIG_DIR = '$TOPLEVEL'"
        Assert-NotContains 't-106.test: worktree case: cured hook carries no worktree path (as spelled in REPO_ROOT)' $q106iHook "`$AI_CONFIG_DIR = '$env:REPO_ROOT'"

        Remove-Item -LiteralPath $Q106I.Root -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        _Skip 't-106.test: worktree guard test — not running in a linked worktree' `
            "TOPLEVEL=$TOPLEVEL MAIN_ROOT_EXPECTED=$MAIN_ROOT_EXPECTED"
    }
} else {
    _Skip 't-106.test: worktree guard test — no .git in REPO_ROOT' "REPO_ROOT=$env:REPO_ROOT"
}

# ---------- Test 12: Adversarial A-1 harness mismatch rejected ---------------
$Q106J = New-Q106Target
$manifestPath = Join-Path $Q106J.Out '.build-manifest.json'
$settingsPath = Join-Path $Q106J.Out 'settings.json'
Invoke-Jq-File -Path $manifestPath -Filter '.harness = "codex"'
Invoke-Jq-File -Path $settingsPath -Filter '. + {theme: "auto"}'

Assert-Exit 't-106.test: adversarial A-1: forged harness=codex on Claude-shaped target rejects cure' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106J.Out --cure-soft-drift

Remove-Item -LiteralPath $Q106J.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Test 13: Adversarial A-3 duplicate JSON keys rejected ------------
$Q106K = New-Q106Target
$settingsPath = Join-Path $Q106K.Out 'settings.json'
# Add operator soft keys theme + effortLevel, then craft a duplicate-key file via string ops.
$origObj = & jq '. + {theme: "auto", effortLevel: "xhigh"}' $settingsPath 2>$null
if ($origObj -is [array]) { $origObj = $origObj -join "`n" }
$compact = & jq -c '.' --argjson placeholder 0 -n --slurpfile slurp /dev/null 2>$null  # noop
$compact = $origObj | & jq -c '.' 2>$null
if ($compact -is [array]) { $compact = $compact -join '' }
# Append a malicious duplicate key by replacing the trailing `}` with `, "hooks": {...}}`.
$fragment = ', "hooks": {"Stop": [{"matcher": "MALICIOUS", "hooks": []}]}}'
$dup = $compact -replace '\}\s*$', $fragment
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($settingsPath, ($dup + "`n"), $utf8NoBom)

# Sanity-check: jq sees the file as parseable.
& jq empty $settingsPath 2>$null
if ($LASTEXITCODE -eq 0) {
    Assert-Exit 't-106.test: adversarial A-3: duplicate-key settings.json rejects cure' 1 -- pwsh -NoProfile -File $CHECK_DRIFT_PS1 --manifest $Q106K.Out --cure-soft-drift
} else {
    _Skip 't-106.test: adversarial A-3 test — duplicate-key fixture not valid JSON for jq' 'jq could not parse'
}

Remove-Item -LiteralPath $Q106K.Root -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Twin parity: the soft-key allowlists are byte-identical ----------
# Mirrors the .sh twin: pin check-drift.ps1's $softKeys to check-drift.sh's
# soft_keys so a one-sided allowlist edit fails here, on every lane.
$q106kShPath = Join-Path (Split-Path -Parent $CHECK_DRIFT_PS1) 'check-drift.sh'
$q106kSh = [regex]::Match((Get-Content -LiteralPath $q106kShPath -Raw), "soft_keys='(\[[^\]]*\])'").Groups[1].Value
$q106kPs = [regex]::Match((Get-Content -LiteralPath $CHECK_DRIFT_PS1 -Raw), "\`$softKeys = '(\[[^\]]*\])'").Groups[1].Value
# Both extractions can match NOTHING (a renamed variable, a reformatted literal),
# and '' -ceq '' would then pass the equality assertion below while comparing two
# absences. Pin each side non-empty first, so a silently-broken regex FAILS here
# instead of greening the parity claim.
Assert-Eq 't-106.test: soft-key allowlist extraction from check-drift.sh is non-empty' '1' ([string][int](([string]$q106kSh).Length -gt 0))
Assert-Eq 't-106.test: soft-key allowlist extraction from check-drift.ps1 is non-empty' '1' ([string][int](([string]$q106kPs).Length -gt 0))
Assert-Eq 't-106.test: soft-key allowlist is byte-identical across the bash and PowerShell twins' $q106kSh $q106kPs
Assert-Contains 't-106.test: soft-key allowlist names tui' $q106kPs '"tui"'
