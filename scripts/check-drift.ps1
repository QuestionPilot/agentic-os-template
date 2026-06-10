#Requires -Version 7
<#
.SYNOPSIS
    PowerShell port of check-drift.sh — manifest-mode + repo-mode portability scans.

.DESCRIPTION
    <TEAM>-112 — Windows-native twin of scripts/check-drift.sh. Two modes:

    1. -Manifest <target-dir>: verify the target's .build-manifest.json hashes
       match current files. Used by install.sh / install.ps1 drift detection
       and the acceptance suite. Also runs the post-render extra-file check
       and (optionally) the <TEAM>-106 cure-soft-drift opt-in auto-cure.

    2. (default): scan the repo root for portability + denylist violations:
       - required core/playbooks/verification/dir files present
       - harness entrypoints reference README + core/
       - no machine-specific absolute paths
       - no operator-class personal naming (<TEAM>-51 denylist; sourced fragment)
       - no device-dependent review-lane mentions in skills/
       - no single-harness tokens leaking into shared content

    Per the Issue 5B bash↔pwsh byte-parity contract (after LF-only normalization
    and tmp-path masking), output is byte-identical to the bash twin on common
    inputs.

.PARAMETER Manifest
    Target directory containing .build-manifest.json. Switches to manifest-verify mode.

.PARAMETER CureSoftDrift
    <TEAM>-106 opt-in: if manifest drift is limited to settings.json's
    user-preference keys (theme, effortLevel, agentPushNotifEnabled,
    inputNeededNotifEnabled, reorderings inside
    enabledPlugins / extraKnownMarketplaces), trigger a transparent
    install.ps1 re-render instead of erroring out. ANY drift outside that
    envelope still errors. Default behavior unchanged.

.NOTES
    Per [[reference_ps_port_traps]] trap #3: all file output uses
    [System.IO.File]::WriteAllText with no-BOM UTF-8 + explicit LF.

    Per [[feedback_powershell_set_content_crlf]]: Set-Content / Out-File are
    avoided for byte-significant output.

    Per [[feedback_ps_port_path_capture_at_precheck]]: this script does NOT
    import operator-supplied local.env directly. The cure-soft-drift branch
    invokes install.ps1 / install.sh which does its own jq-binary
    precheck-capture. No PATH-poisoning window in this script.

    Per [[reference_stat_bsd_vs_gnu]]: this script uses .NET FileInfo + sha256
    via [System.Security.Cryptography.SHA256], which is platform-portable;
    no `stat -c` vs `stat -f` divergence.

    Per [[reference_bash_3_2_compat]]: bash twin uses parallel arrays + while-
    read loops for bash 3.2 compat; PS uses native arrays / hashtables which
    PS 7+ supports cleanly.

    Per [[feedback_self_tripping_test_source]]: the path-scan regex
    /(Users|home)/[^/]+/?|[A-Za-z]:\\Users\\[^\\]+\\?
    is constructed at runtime from non-trip halves so this file does not
    self-trip the very scan it runs. Comments + sentinel literals also
    runtime-split for the <TEAM>-87 extension class.

    Per [[reference_lineark_no_comment_subcommand]]: not relevant — this
    script does not touch lineark.
#>

[CmdletBinding()]
param(
    [string]$Manifest = '',
    [switch]$CureSoftDrift,
    [Alias('h')][switch]$Help,

    # Remaining args — POSIX-style --manifest / --cure-soft-drift / --help
    # so bash-trained operators get muscle-memory parity with check-drift.sh's
    # `while [ $# -gt 0 ]; case "$1" in ...` parser. Pattern mirrors install.ps1.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$global:LASTEXITCODE = 0

# POSIX-style flag pass through $Rest (mirror bash twin's flag parser at
# scripts/check-drift.sh:14-19).
$i = 0
while ($i -lt $Rest.Count) {
    $arg = $Rest[$i]
    switch -CaseSensitive ($arg) {
        '--cure-soft-drift' { $CureSoftDrift = [switch]$true; $i += 1 }
        '--manifest' {
            if ($i + 1 -ge $Rest.Count) {
                [Console]::Error.WriteLine('check-drift.ps1: --manifest needs a target directory')
                exit 2
            }
            $Manifest = $Rest[$i + 1]
            $i += 2
        }
        '-h'     { $Help = [switch]$true; $i += 1 }
        '--help' { $Help = [switch]$true; $i += 1 }
        default {
            [Console]::Error.WriteLine("check-drift.ps1: unknown argument: $arg")
            exit 2
        }
    }
}

if ($Help.IsPresent) {
    Write-Host @'
check-drift.ps1 [-Manifest <target-dir> [-CureSoftDrift]] [-Help]

Modes:
  -Manifest <dir>   Verify the target's .build-manifest.json against current
                    file hashes. Errors on drift unless -CureSoftDrift and the
                    drift fits the <TEAM>-106 soft envelope (settings.json
                    user-preference keys only).

  (default)         Run repo-portability + denylist scans on the repo this
                    script lives in.

Exit codes:
  0   clean
  1   drift / portability violation detected
'@
    exit 0
}

# ---------------------------------------------------------------------------
# Resolve repo root
# ---------------------------------------------------------------------------
if ($PSScriptRoot) {
    $repoRoot = Split-Path $PSScriptRoot -Parent
} else {
    $repoRoot = (Resolve-Path (Join-Path $PWD '..')).Path
}
if (Test-Path -LiteralPath $repoRoot -PathType Container) {
    $repoRoot = (Resolve-Path -LiteralPath $repoRoot).Path
}

# <TEAM>-213: choose the enumeration mode ONCE (mirror of the bash twin). In a git
# work tree, Test-ScanPath scans the COMMITTABLE set (skips gitignored runtime
# artifacts). OUTSIDE a git work tree — e.g. a leak scan run against a plain-copy
# staging/export tree, which has no .git and no gitignored runtime state — it
# falls back to a Get-ChildItem filesystem walk so those scans still run.
#
# Detection uses TOPLEVEL-EQUALITY, not --is-inside-work-tree (Codex adversarial
# F1): is-inside walks ancestors, so a staging tree nested under an unrelated
# parent repo would take the git path and `ls-files -- .` (relative to that
# untracked staging dir) would return empty — the entire leak scan silently
# passes. We take the git path only when --show-toplevel resolves to $repoRoot
# itself (true for the live repo + linked worktrees; false for a nested staging
# tree → correct fallback). $repoRoot is already Resolve-Path'd above.
$script:IsGitWorkTree = $false
$gitTop = (& git -C $repoRoot rev-parse --show-toplevel 2>$null | Select-Object -First 1)
if ($LASTEXITCODE -eq 0 -and $gitTop) {
    $topResolved = Resolve-Path -LiteralPath $gitTop -ErrorAction SilentlyContinue
    if ($topResolved -and $topResolved.Path -eq $repoRoot) { $script:IsGitWorkTree = $true }
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------
function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-FileSha256 {
    # Cross-platform sha256 via .NET, no `stat`/`shasum` shell-out.
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hashBytes = $sha.ComputeHash($stream)
            return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

function Write-Fail {
    param([string]$Msg)
    [Console]::Error.WriteLine("FAIL $Msg")
}
function Write-Note {
    param([string]$Msg)
    [Console]::Error.WriteLine("NOTE $Msg")
}
function Write-InfoErr {
    param([string]$Msg)
    [Console]::Error.WriteLine("INFO $Msg")
}

# ---------------------------------------------------------------------------
# MANIFEST MODE
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrEmpty($Manifest)) {
    # F-1 fix: $target is what the user passed (preserved verbatim for display
    # parity with bash twin, which echoes the input string in its PASS/FAIL
    # summary line). $targetAbs is the canonical absolute path used for
    # internal relpath computation against $full (which Get-ChildItem returns
    # already canonicalized).
    #
    # The split is required because canonicalizing $target itself would diverge
    # bash↔pwsh byte-parity in the user-visible output: bash twin's
    # "PASS no manifest drift in $target" preserves a relative input like
    # "./fixture" verbatim; canonicalizing $target on the PS side would emit
    # the absolute path instead, breaking the byte-identity contract.
    #
    # Internal-correctness change ($full.Substring($target.Length) →
    # GetRelativePath) addresses the Codex F-1 finding without bleeding into
    # the display surface. See [[feedback_port_parity_vs_regression_split]] for
    # the port-parity-vs-correctness split lesson; this is a fresh sub-class
    # (internal canonicalization safe; display canonicalization NOT safe).
    $target = $Manifest
    if (Test-Path -LiteralPath $target -PathType Container) {
        $targetAbs = (Resolve-Path -LiteralPath $target).Path
    } else {
        $targetAbs = $target
    }
    $manifestPath = Join-Path $target '.build-manifest.json'

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Write-Fail "no .build-manifest.json in $target"
        exit 1
    }
    if (-not (Test-Command 'jq')) {
        Write-Fail 'jq unavailable; cannot verify build manifest'
        exit 1
    }

    # Walk manifest entries: for each generated.<rel> = <wanted-sha256>, hash
    # the target file and compare. Track drifted files for <TEAM>-106 envelope.
    $drift = $false
    $driftedFiles = New-Object System.Collections.Generic.List[string]

    # Get the manifest entries from jq (matches bash's `jq -r '...to_entries[]...'`).
    $entriesRaw = & jq -r '.generated | to_entries[] | "\(.key)\t\(.value)"' $manifestPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'failed to parse manifest .generated entries'
        exit 1
    }
    if ($null -eq $entriesRaw) { $entriesRaw = @() }
    if ($entriesRaw -isnot [array]) { $entriesRaw = @($entriesRaw) }

    foreach ($line in $entriesRaw) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -lt 2) { continue }
        $rel  = $parts[0]
        $want = $parts[1]
        $full = Join-Path $target $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            Write-Fail "manifest drift: generated file missing: $rel"
            $drift = $true
            [void]$driftedFiles.Add($rel)
            continue
        }
        $got = Get-FileSha256 -Path $full
        if ($got -ne $want) {
            Write-Fail "manifest drift: $rel was hand-edited"
            $drift = $true
            [void]$driftedFiles.Add($rel)
        }
    }

    # Extra-file detection: a file in skills/<managed>/ + hooks/ + settings.json
    # that the manifest doesn't list is drift. Shape C operator-local skills
    # (unmanaged subdirs under skills/) are exempt.
    $managedRaw = & jq -r '.generated | keys[] | select(startswith("skills/")) | split("/")[1]' $manifestPath 2>$null
    if ($null -eq $managedRaw) { $managedRaw = @() }
    if ($managedRaw -isnot [array]) { $managedRaw = @($managedRaw) }
    $managedSkills = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($s in $managedRaw) {
        if (-not [string]::IsNullOrEmpty($s)) { [void]$managedSkills.Add($s) }
    }

    # Build the candidate list: every file under $target/skills + $target/hooks
    # + $target/settings.json (if present). All entries are absolute paths so
    # GetRelativePath($targetAbs, ...) works uniformly regardless of whether
    # the user passed -Manifest as relative or absolute (F-1 follow-on: the
    # settingsPath case previously used $target via Join-Path which preserved
    # relative-ness, breaking GetRelativePath when $PWD diverged from $target's
    # parent. $targetAbs sourcing fixes this defense-in-depth.)
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($sub in 'skills', 'hooks') {
        $subDir = Join-Path $targetAbs $sub
        if (Test-Path -LiteralPath $subDir -PathType Container) {
            foreach ($f in (Get-ChildItem -LiteralPath $subDir -Recurse -File -ErrorAction SilentlyContinue)) {
                [void]$candidates.Add($f.FullName)
            }
        }
    }
    $settingsPath = Join-Path $targetAbs 'settings.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        [void]$candidates.Add($settingsPath)
    }

    # Build a hashset of manifest-managed relpaths for fast lookup.
    $managedRel = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($line in $entriesRaw) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        $rel = ($line -split "`t", 2)[0]
        if (-not [string]::IsNullOrEmpty($rel)) { [void]$managedRel.Add($rel) }
    }

    foreach ($full in $candidates) {
        if (-not (Test-Path -LiteralPath $full)) { continue }
        # F-1 fix: compute rel via [System.IO.Path]::GetRelativePath using the
        # canonicalized $targetAbs (NOT $target — see the display/internal
        # split comment at line 153). GetRelativePath is length-safe regardless
        # of whether the user's input was relative or absolute. Forward-slash
        # normalization matches bash output.
        $rel = [System.IO.Path]::GetRelativePath($targetAbs, $full).Replace([char]'\', [char]'/')
        # Hermes writes its own bundled-skills bookkeeping file directly into
        # the managed skills/ tree at runtime — app-written state, not a hand
        # edit. Exempt by exact name (twin of the bash exemption).
        if ($rel -eq 'skills/.bundled_manifest') { continue }
        # Shape C exemption: unmanaged skills/<sub>/... are operator-local
        # and ALLOWED. Subdir-structured only; bare files under skills/
        # remain subject to the manifest gate.
        if ($rel -like 'skills/*/*') {
            $sub = ($rel.Substring('skills/'.Length) -split '/', 2)[0]
            if (-not $managedSkills.Contains($sub)) { continue }
        }
        if (-not $managedRel.Contains($rel)) {
            Write-Fail "manifest drift: untracked file in generated tree: $rel"
            $drift = $true
            [void]$driftedFiles.Add("untracked:$rel")
        }
    }

    if ($drift) {
        # <TEAM>-106 soft-drift cure (opt-in).
        if ($CureSoftDrift.IsPresent -and `
            $driftedFiles.Count -eq 1 -and `
            $driftedFiles[0] -eq 'settings.json' -and `
            (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {

            # Settings must parse as JSON.
            $sJsonProbe = & jq empty $settingsPath 2>$null
            if ($LASTEXITCODE -ne 0) {
                exit 1
            }

            # Gate 4: install script must come from MAIN repo (not the worktree).
            # bash twin uses `git rev-parse --show-toplevel` vs `--git-common-dir`.
            $installScript = Join-Path $repoRoot 'scripts' 'install.ps1'
            $bashInstall   = Join-Path $repoRoot 'scripts' 'install.sh'
            if (Test-Command 'git') {
                $prevExitCode = $LASTEXITCODE
                $toplevel = (& git -C $repoRoot rev-parse --show-toplevel 2>$null | Select-Object -First 1)
                $commonDir = (& git -C $repoRoot rev-parse --git-common-dir 2>$null | Select-Object -First 1)
                $LASTEXITCODE = $prevExitCode
                if (-not [string]::IsNullOrEmpty($toplevel) -and -not [string]::IsNullOrEmpty($commonDir)) {
                    # Canonicalize toplevel.
                    try { $toplevel = (Resolve-Path -LiteralPath $toplevel).Path } catch {}
                    # Normalize common_dir to absolute path.
                    if (-not [System.IO.Path]::IsPathRooted($commonDir)) {
                        $commonDir = Join-Path $repoRoot $commonDir
                    }
                    if (Test-Path -LiteralPath $commonDir -PathType Container) {
                        try { $commonDir = (Resolve-Path -LiteralPath $commonDir).Path } catch {}
                    }
                    # common_dir is <main>/.git — main = parent.
                    $mainRoot = Split-Path $commonDir -Parent
                    if (-not [string]::IsNullOrEmpty($mainRoot)) {
                        try { $mainRoot = (Resolve-Path -LiteralPath $mainRoot).Path } catch {}
                        if ($toplevel -ne $mainRoot) {
                            # We're in a linked worktree.
                            $mainInstallPs = Join-Path $mainRoot 'scripts' 'install.ps1'
                            $mainInstallSh = Join-Path $mainRoot 'scripts' 'install.sh'
                            if (Test-Path -LiteralPath $mainInstallPs -PathType Leaf) {
                                $installScript = $mainInstallPs
                            } elseif (Test-Path -LiteralPath $mainInstallSh -PathType Leaf) {
                                $bashInstall = $mainInstallSh
                                $installScript = $null
                            } else {
                                Write-Note "soft-drift envelope matched but cure refused: in linked worktree ($repoRoot)"
                                Write-Note "     and main repo install script not found at $mainRoot/scripts/"
                                Write-Note "     Re-run from main: cd $mainRoot && bash scripts/install.sh --harness <h>"
                                exit 1
                            }
                        }
                    }
                }
            }

            # Gate 5: read harness from manifest + cross-check against target shape.
            $prevExitCode = $LASTEXITCODE
            $harness = (& jq -r '.harness // empty' $manifestPath 2>$null | Select-Object -First 1)
            $LASTEXITCODE = $prevExitCode
            if ([string]::IsNullOrEmpty($harness)) {
                Write-Note 'soft-drift envelope matched but cure refused: manifest has no harness field'
                exit 1
            }
            switch ($harness) {
                'claude' {
                    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf) -or `
                        -not (Test-Path -LiteralPath (Join-Path $target 'CLAUDE.md') -PathType Leaf)) {
                        Write-Note 'soft-drift envelope matched but cure refused: manifest claims claude but target lacks settings.json/CLAUDE.md'
                        exit 1
                    }
                    if ((Test-Path -LiteralPath (Join-Path $target 'AGENTS.md') -PathType Leaf) -or `
                        (Test-Path -LiteralPath (Join-Path $target 'hooks.json') -PathType Leaf)) {
                        Write-Note 'soft-drift envelope matched but cure refused: manifest claims claude but target also has codex artifacts (AGENTS.md/hooks.json)'
                        exit 1
                    }
                }
                'codex' {
                    Write-Note 'soft-drift envelope matched but cure refused: settings.json drift but manifest claims codex (codex does not manage settings.json)'
                    exit 1
                }
                default {
                    Write-Note "soft-drift envelope matched but cure refused: unknown harness in manifest: $harness"
                    exit 1
                }
            }

            # Adversarial A-3: duplicate-key defense via python3.
            if (Test-Command 'python3') {
                $pyCode = @'
import json, sys
def hook(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        sys.exit(1)
    return dict(pairs)
with open(sys.argv[1]) as f:
    json.load(f, object_pairs_hook=hook)
'@
                $prevExitCode = $LASTEXITCODE
                & python3 -c $pyCode $settingsPath 2>$null | Out-Null
                $pyRc = $LASTEXITCODE
                $LASTEXITCODE = $prevExitCode
                if ($pyRc -ne 0) {
                    Write-Note 'soft-drift envelope matched but cure refused: settings.json contains duplicate object keys (rejected per A-3 adversarial defense)'
                    exit 1
                }
            }

            # Adversarial A-2 (TOCTOU): capture pre-cure hashes.
            $preCureSettingsHash = Get-FileSha256 -Path $settingsPath
            $preCureManifestHash = Get-FileSha256 -Path $manifestPath

            # Gate 6: build canonical settings.json via install --build-only to tmp.
            $tmpOut = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "check-drift-ps-" + [System.IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $tmpOut -Force | Out-Null
            try {
                $tmpBuild = $null
                # Bash twin invokes install.sh --build-only and captures its stdout
                # (the path to the build dir). For pwsh parity, prefer install.ps1
                # if present; otherwise fall back to install.sh.
                $prevExitCode = $LASTEXITCODE
                # Build the canonical baseline OPINION-FREE (see check-drift.sh):
                # AI_CONFIG_SKIP_PRESERVE_LIVE suppresses preserve-live so
                # enabledPlugins/agentPushNotifEnabled value-changes stay
                # detectable instead of self-matching canonical and being cured.
                $env:AI_CONFIG_SKIP_PRESERVE_LIVE = '1'
                try {
                    if ($null -ne $installScript -and (Test-Path -LiteralPath $installScript -PathType Leaf)) {
                        $tmpBuildRaw = & pwsh -NoProfile -File $installScript -Harness $harness -Out $target -BuildOnly 2>$null
                    } else {
                        $tmpBuildRaw = & bash $bashInstall --harness $harness --out $target --build-only 2>$null
                    }
                } finally {
                    Remove-Item Env:AI_CONFIG_SKIP_PRESERVE_LIVE -ErrorAction SilentlyContinue
                }
                $LASTEXITCODE = $prevExitCode
                if ($null -ne $tmpBuildRaw) {
                    if ($tmpBuildRaw -is [array]) { $tmpBuild = ($tmpBuildRaw | Select-Object -Last 1) }
                    else { $tmpBuild = $tmpBuildRaw }
                }
                if ([string]::IsNullOrEmpty($tmpBuild) -or -not (Test-Path -LiteralPath (Join-Path $tmpBuild 'settings.json') -PathType Leaf)) {
                    Write-Note 'soft-drift envelope matched but cure refused: canonical settings.json not built'
                    exit 1
                }

                $canSettings = Join-Path $tmpBuild 'settings.json'

                # Type-shape preflight (Codex confirmation F-1).
                $prevExitCode = $LASTEXITCODE
                & jq -e 'type == "object"' $settingsPath 2>$null | Out-Null
                $rc1 = $LASTEXITCODE
                & jq -e 'type == "object"' $canSettings 2>$null | Out-Null
                $rc2 = $LASTEXITCODE
                $LASTEXITCODE = $prevExitCode
                if ($rc1 -ne 0) {
                    Write-Note 'soft-drift envelope NOT matched: current settings.json is not a JSON object'
                    exit 1
                }
                if ($rc2 -ne 0) {
                    Write-Note 'soft-drift envelope matched but cure refused: canonical settings.json is not a JSON object'
                    exit 1
                }
                foreach ($reordKey in 'enabledPlugins', 'extraKnownMarketplaces') {
                    foreach ($sf in $settingsPath, $canSettings) {
                        $prevExitCode = $LASTEXITCODE
                        & jq -e --arg k $reordKey 'has($k)' $sf 2>$null | Out-Null
                        $hasIt = ($LASTEXITCODE -eq 0)
                        $LASTEXITCODE = $prevExitCode
                        if ($hasIt) {
                            $prevExitCode = $LASTEXITCODE
                            & jq -e --arg k $reordKey '.[$k] | type == "object"' $sf 2>$null | Out-Null
                            $isObj = ($LASTEXITCODE -eq 0)
                            $LASTEXITCODE = $prevExitCode
                            if (-not $isObj) {
                                Write-Note "soft-drift envelope NOT matched: $reordKey is not an object in $sf"
                                exit 1
                            }
                        }
                    }
                }

                # Compute non-soft keys via jq classifier (same expression as bash).
                $softKeys = '["theme","effortLevel","agentPushNotifEnabled","inputNeededNotifEnabled"]'
                $reorderTolerant = '["enabledPlugins","extraKnownMarketplaces"]'
                $jqExpr = @'
  ($cur[0] // {}) as $C
| ($can[0] // {}) as $K
| ($C | keys) + ($K | keys) | unique
| map(select(
      . as $k
    | ($C[$k] != $K[$k])
    | . and (
        ($C | has($k)) and ($K | has($k)) and ($reord | index($k))
        | if . then
            ($C[$k] | keys | sort) != ($K[$k] | keys | sort)
            or any(($C[$k] | keys[]); $C[$k][.] != $K[$k][.])
          else true end
      )
  ))
| map(select((. as $k | $soft | index($k)) | not))
| .[]
'@
                $prevExitCode = $LASTEXITCODE
                $nonSoftRaw = & jq -nr `
                    --slurpfile cur $settingsPath `
                    --slurpfile can $canSettings `
                    --argjson soft $softKeys `
                    --argjson reord $reorderTolerant `
                    $jqExpr 2>$null
                $jqStatus = $LASTEXITCODE
                $LASTEXITCODE = $prevExitCode
                if ($jqStatus -ne 0) {
                    Write-Note "soft-drift envelope matched but cure refused: jq classifier errored (exit $jqStatus)"
                    exit 1
                }
                if (-not [string]::IsNullOrEmpty($nonSoftRaw)) {
                    if ($nonSoftRaw -is [array]) {
                        $nonSoftFlat = ($nonSoftRaw -join ' ')
                    } else {
                        $nonSoftFlat = ($nonSoftRaw -replace "`n", ' ').TrimEnd()
                    }
                    Write-Note "soft-drift envelope NOT matched: non-soft keys differ: $nonSoftFlat "
                    exit 1
                }

                # Adversarial A-2: TOCTOU re-check.
                if ((Get-FileSha256 -Path $settingsPath) -ne $preCureSettingsHash) {
                    Write-Note 'soft-drift envelope matched but cure refused: settings.json changed between classification and cure (TOCTOU)'
                    exit 1
                }
                if ((Get-FileSha256 -Path $manifestPath) -ne $preCureManifestHash) {
                    Write-Note 'soft-drift envelope matched but cure refused: manifest changed between classification and cure (TOCTOU)'
                    exit 1
                }

                Write-InfoErr "soft-drift detected on settings.json (only user-preference keys); curing via install.sh --harness $harness"
                # Re-render. Prefer install.ps1 if present; otherwise install.sh.
                $cureRc = 0
                $prevExitCode = $LASTEXITCODE
                if ($null -ne $installScript -and (Test-Path -LiteralPath $installScript -PathType Leaf)) {
                    & pwsh -NoProfile -File $installScript -Harness $harness -Out $target *>$null
                } else {
                    & bash $bashInstall --harness $harness --out $target *>$null
                }
                $cureRc = $LASTEXITCODE
                $LASTEXITCODE = $prevExitCode
                if ($cureRc -ne 0) {
                    Write-Fail 'soft-drift cure: install.sh re-render failed'
                    exit 1
                }
                # Re-verify via main-repo check-drift.
                $verifyScript = $null
                if ($null -ne $installScript -and (Test-Path -LiteralPath $installScript -PathType Leaf)) {
                    $verifyScript = Join-Path (Split-Path $installScript -Parent) 'check-drift.ps1'
                } elseif (-not [string]::IsNullOrEmpty($bashInstall) -and (Test-Path -LiteralPath $bashInstall -PathType Leaf)) {
                    $verifyScript = Join-Path (Split-Path $bashInstall -Parent) 'check-drift.sh'
                }
                if ($null -ne $verifyScript -and (Test-Path -LiteralPath $verifyScript -PathType Leaf)) {
                    $prevExitCode = $LASTEXITCODE
                    if ($verifyScript -like '*.ps1') {
                        & pwsh -NoProfile -File $verifyScript -Manifest $target *>$null
                    } else {
                        & bash $verifyScript --manifest $target *>$null
                    }
                    $verifyRc = $LASTEXITCODE
                    $LASTEXITCODE = $prevExitCode
                    if ($verifyRc -ne 0) {
                        Write-Fail 'soft-drift cure: post-cure drift check still fails'
                        exit 1
                    }
                }
                Write-Host "PASS soft-drift cured; manifest now matches canonical render"
                exit 0
            } finally {
                # Cleanup tmp dirs.
                if (Test-Path -LiteralPath $tmpOut -PathType Container) {
                    Remove-Item -LiteralPath $tmpOut -Recurse -Force -ErrorAction SilentlyContinue
                }
                if (-not [string]::IsNullOrEmpty($tmpBuild) -and (Test-Path -LiteralPath $tmpBuild -PathType Container)) {
                    Remove-Item -LiteralPath $tmpBuild -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        exit 1
    }

    Write-Host "PASS no manifest drift in $target"
    exit 0
}

# ---------------------------------------------------------------------------
# REPO MODE
# ---------------------------------------------------------------------------

# Helper: run a regex scan over the repo with exclude lists, fail if any hits.
# Bash twin uses `grep -rEn --exclude=... --exclude-dir=... -e <regex>`. Mirror
# with native PS file enumeration + regex match.

function Test-ScanPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs  = @(),
        [Parameter(Mandatory)][string]$Pattern,
        [switch]$CaseInsensitive
    )
    # Returns @() of "file:lineno:line" hits (matching grep -n output format).
    $hits = New-Object System.Collections.Generic.List[string]
    $excludeDirsLower = @($ExcludeDirs | ForEach-Object { $_.ToLowerInvariant() })
    $excludeFilesSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $ExcludeFiles) { [void]$excludeFilesSet.Add($f) }

    $opts = [System.Text.RegularExpressions.RegexOptions]::Compiled
    if ($CaseInsensitive.IsPresent) { $opts = $opts -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
    $re = [System.Text.RegularExpressions.Regex]::new($Pattern, $opts)

    # <TEAM>-213: outside a git work tree (a plain-copy staging/export tree — no
    # .git, hence no gitignored runtime state), fall back to the pre-<TEAM>-213
    # Get-ChildItem -Recurse -Force walk so those scans still run. Byte-equivalent
    # to the original Test-ScanPath body.
    if (-not $script:IsGitWorkTree) {
        # Capture directory-traversal errors so an unreadable dir fails closed
        # (see the post-walk check below). -EA SilentlyContinue still records into
        # -ErrorVariable (unlike -EA Ignore).
        $gciErr = @()
        Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable gciErr |
            ForEach-Object {
                $f = $_
                if ($excludeFilesSet.Contains($f.Name)) { return }
                $rel = $f.FullName.Substring($Root.Length).TrimStart([char]'/', [char]'\').Replace([char]'\', [char]'/')
                $segments = $rel -split '/'
                foreach ($s in $segments) {
                    if ($excludeDirsLower -contains $s.ToLowerInvariant()) { return }
                }
                if ($segments -contains '.git') { return }
                try {
                    $lineno = 0
                    foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
                        $lineno++
                        if ($re.IsMatch($line)) {
                            [void]$hits.Add("$($f.FullName):${lineno}:${line}")
                        }
                    }
                } catch {
                    # A listed file we cannot read must FAIL closed to match the
                    # bash twin (grep exit >1 -> FAIL), not be silently skipped
                    # into a PASS. exit aborts the script (Test-ScanPath runs at
                    # top level via Assert-Absent), as the git-quoted-path guard
                    # below already does.
                    Write-Fail "content scan: could not read listed file ($($f.FullName)); not treating as pass"
                    exit 1
                }
            }
        # A permission-denied DIRECTORY makes the walk error (captured above);
        # its files are never enumerated, so a secret/marker inside would hide and
        # the scan would fail OPEN. Fail closed to match the bash twin's `grep -r`
        # exit-2 — but ONLY for dirs bash would actually descend into. The bash twin
        # passes `--exclude-dir` for .git AND every $ExcludeDirs name, so it never
        # enters (nor errors on) those; an error from inside an excluded dir is
        # bash-invisible AND that dir's files are pruned from the scan anyway, so
        # failing on it would break bash<->PS parity for zero security gain. Prune
        # those errors via the SAME per-segment exclusion the ForEach-Object above
        # applies to files; fail closed on the rest. $e.TargetObject is the
        # offending path (string); an unknown/out-of-root path stays unpruned (fail
        # closed, conservative).
        $realErr = @()
        foreach ($e in $gciErr) {
            $ep = [string]$e.TargetObject
            $pruned = $false
            if (-not [string]::IsNullOrEmpty($ep) -and $ep.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
                $erel = $ep.Substring($Root.Length).TrimStart([char]'/', [char]'\').Replace([char]'\', '/')
                foreach ($s in ($erel -split '/')) {
                    if ($s -eq '.git' -or ($excludeDirsLower -contains $s.ToLowerInvariant())) { $pruned = $true; break }
                }
            }
            if (-not $pruned) { $realErr += $e }
        }
        if ($realErr.Count -gt 0) {
            Write-Fail "directory enumeration errored in non-git fallback ($($realErr.Count) error(s); e.g. $($realErr[0].Exception.Message)); not treating as clean"
            exit 1
        }
        return $hits.ToArray()
    }

    # <TEAM>-213: enumerate the COMMITTABLE set — tracked PLUS untracked-but-not-
    # gitignored files (`git ls-files --cached --others --exclude-standard`) —
    # instead of a `Get-ChildItem -Recurse -Force` filesystem walk. The walk
    # descended into GITIGNORED runtime artifacts (codegraph's .codegraph/*.log,
    # cross-model-out/, the harness .claude/.codex/.agents/ dirs), so a personal
    # absolute path inside one false-tripped the scan; --exclude-standard prunes
    # all gitignored paths up front (no per-tool --exclude-dir maintenance). A
    # gitignored file can never enter git, so it is out of scope; tracked +
    # untracked-not-ignored content is exactly what CAN be committed and is still
    # scanned. Newline-delimited (NOT `-z`): symmetric with the bash twin and
    # robust in PowerShell, where embedded-NUL splitting is fragile across pwsh /
    # Windows PowerShell / Git-for-Windows; safe because the framework tree has no
    # embedded-newline filenames. git enumeration failure FAILs the scan rather
    # than yielding an empty list that would read as "no hits -> pass".
    if ($Root -eq $repoRoot) {
        $relSpec = '.'
    } else {
        $relSpec = $Root.Substring($repoRoot.Length).TrimStart([char]'/', [char]'\').Replace([char]'\', '/')
    }
    # core.quotePath=false: emit non-ASCII filenames raw so they are scanned, not
    # C-quoted into a non-existent path that ReadLines would silently skip (Codex
    # adversarial F2).
    $listed = @(& git -C $repoRoot -c core.quotePath=false ls-files --cached --others --exclude-standard -- $relSpec 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "git ls-files enumeration errored (exit $LASTEXITCODE); not treating as clean"
        exit 1
    }
    foreach ($rel in $listed) {
        if ([string]::IsNullOrEmpty($rel)) { continue }
        # Control-char names (e.g. newline) are still C-quoted by git even with
        # quotePath=false; such a path can't be read safely line-delimited. Fail
        # CLOSED to match the bash twin (where grep on the quoted operand errors
        # out), rather than letting ReadLines' catch{} swallow it into a PASS
        # (Codex adversarial F2/F3).
        if ($rel.StartsWith('"')) {
            Write-Fail "cannot safely scan git-quoted path (control char in filename): $rel"
            exit 1
        }
        # Filename-level exclude (basename match).
        $name = Split-Path $rel -Leaf
        if ($excludeFilesSet.Contains($name)) { continue }
        # Dir-component exclude (matches grep --exclude-dir name-anywhere semantics).
        $segments = $rel -split '/'
        $skip = $false
        foreach ($s in $segments) {
            if ($excludeDirsLower -contains $s.ToLowerInvariant()) { $skip = $true; break }
        }
        if ($skip) { continue }
        # .git is untracked/ignored so absent from ls-files; keep the guard for parity.
        if ($segments -contains '.git') { continue }
        # Absolute path for reading + for the hit line (matches the bash twin's
        # "$repo_root/$f" output form). Read as text; skip on read failure.
        $full = Join-Path $repoRoot $rel
        try {
            $lineno = 0
            foreach ($line in [System.IO.File]::ReadLines($full)) {
                $lineno++
                if ($re.IsMatch($line)) {
                    [void]$hits.Add("${full}:${lineno}:${line}")
                }
            }
        } catch {
            # A listed file we cannot read must FAIL closed to match the bash
            # twin (grep exit >1 -> FAIL), not be silently skipped into a PASS.
            # exit aborts the script (Test-ScanPath runs at top level via
            # Assert-Absent), as the git-quoted-path guard above already does
            #.
            Write-Fail "content scan: could not read listed file ($full); not treating as pass"
            exit 1
        }
    }
    return $hits.ToArray()
}

function Assert-Absent {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Pattern,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs  = @(),
        [string[]]$Roots,
        [switch]$CaseInsensitive
    )
    $allHits = New-Object System.Collections.Generic.List[string]
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $hits = Test-ScanPath -Root $root -ExcludeFiles $ExcludeFiles -ExcludeDirs $ExcludeDirs -Pattern $Pattern -CaseInsensitive:$CaseInsensitive.IsPresent
        foreach ($h in $hits) { [void]$allHits.Add($h) }
    }
    if ($allHits.Count -gt 0) {
        Write-Fail $Label
        foreach ($h in $allHits) { [Console]::Error.WriteLine($h) }
        exit 1
    }
}

# Required-file checks (mirror bash twin exactly).
$requiredCore = @(
    'core/operating-system.md',
    'core/self-improvement.md',
    'core/memory-model.md',
    'core/verification.md',
    'core/tool-use.md'
)
$requiredPlaybooks = @(
    'playbooks/harness-entrypoints.md',
    'playbooks/data-readiness-map.md',
    'playbooks/goal-run.md'
)
$requiredVerification = @(
    'verification/process-memory.md',
    'verification/data-readiness.md'
)
$requiredDirs = @('verification')

foreach ($p in $requiredCore) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $p) -PathType Leaf)) {
        Write-Fail "missing required core file: $p"
        exit 1
    }
}
foreach ($p in $requiredDirs) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $p) -PathType Container)) {
        Write-Fail "missing required directory: $p"
        exit 1
    }
}
foreach ($p in $requiredPlaybooks) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $p) -PathType Leaf)) {
        Write-Fail "missing required playbook: $p"
        exit 1
    }
}
foreach ($p in $requiredVerification) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $p) -PathType Leaf)) {
        Write-Fail "missing required verification file: $p"
        exit 1
    }
}

foreach ($entrypoint in 'AGENTS.md', 'CLAUDE.md') {
    $epPath = Join-Path $repoRoot $entrypoint
    if (-not (Test-Path -LiteralPath $epPath -PathType Leaf)) {
        Write-Fail "missing harness entrypoint: $entrypoint"
        exit 1
    }
    $txt = [System.IO.File]::ReadAllText($epPath)
    if ($txt -notmatch 'README\.md') {
        Write-Fail "harness entrypoint $entrypoint does not reference README.md"
        exit 1
    }
    if ($txt -notmatch 'core/') {
        Write-Fail "harness entrypoint $entrypoint does not reference core/"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Path scan — assembles the regex at runtime from non-trip halves so this
# source does not self-trip per [[feedback_self_tripping_test_source]]
# <TEAM>-87 extension.
#
# Equivalent bash pattern:
#   /(Users|home)/[^/]+/?|[A-Za-z]:\\Users\\[^\\]+\\?
# ---------------------------------------------------------------------------
$_pathU = 'Use' + 'rs'          # "Users" but not a literal here
$_pathH = 'hom' + 'e'           # "home" but not a literal here
$pathScanRe = '/(' + $_pathU + '|' + $_pathH + ')/[^/]+/?|[A-Za-z]:\\' + $_pathU + '\\[^\\]+\\?'

Assert-Absent `
    -Label 'machine-specific absolute path found in repository content' `
    -Pattern $pathScanRe `
    -ExcludeFiles @(
        'check-drift.sh', 'check-drift.ps1',
        'local.env', '.git', '.mcp.json',
        'drift.test.sh', 'drift.test.ps1',
        'scripts-ps-parity.test.sh',
        '2026-05-22-que-50-windows-native-port.md',
        'check-clean.sh', 'check-clean.ps1'
    ) `
    -ExcludeDirs @('.claude', '.codex', '.agents', 'cross-model-out') `
    -Roots @($repoRoot)

# ---------------------------------------------------------------------------
# <TEAM>-51 / <TEAM>-146: operator-PRIVATE personal-naming denylist. The scan lives in
# a separate dot-sourced fragment (scripts/lib/operator-naming-check.ps1) that
# the public-snapshot ship-set denylist EXCLUDES — so the public template never
# ships the operator handle literal, while the private repo still runs the
# check. Dot-source it CONDITIONALLY: run if present, skip silently if absent (a
# public-template user has no operator handle to defend against, so the check is
# correctly vestigial there). The fragment relies on `Assert-Absent` + `$repoRoot`
# being in scope, which they are at this point.
# ---------------------------------------------------------------------------
if ($PSScriptRoot) {
    $_operatorNamingCheck = Join-Path $PSScriptRoot 'lib/operator-naming-check.ps1'
    if (Test-Path -LiteralPath $_operatorNamingCheck) {
        . $_operatorNamingCheck
        Invoke-OperatorNamingCheck -RepoRoot $repoRoot
    }
}

# Device-dependent review lane scan in skills/.
Assert-Absent `
    -Label 'device-dependent review lane found in baseline skills catalog' `
    -Pattern 'local[- ]brain|three[- ]brain' `
    -CaseInsensitive `
    -Roots @((Join-Path $repoRoot 'skills'))

# ---------------------------------------------------------------------------
# Harness-agnostic guard: shared dirs may not carry single-harness tokens.
# The trailing alternation group is the Hermes token set (hook event names, the
# Hermes home dir, Hermes-specific tool names) — harnesses/hermes/ is the only
# home for those, same rule as the Claude/Codex tokens before it.
# ---------------------------------------------------------------------------
Assert-Absent `
    -Label 'single-harness token found in shared framework content' `
    -Pattern 'WebFetch|WebSearch|TodoWrite|NotebookEdit|PreToolUse|PostToolUse|SessionStart|UserPromptSubmit|[Ss]uperpowers|\.claude/|\.codex/|\.agents/|on_session_start|on_session_end|pre_tool_call|post_tool_call|pre_llm_call|\.hermes/|SOUL\.md|skill_manage|delegate_task' `
    -ExcludeFiles @('harness-entrypoints.md') `
    -Roots @(
        (Join-Path $repoRoot 'core'),
        (Join-Path $repoRoot 'playbooks'),
        (Join-Path $repoRoot 'verification'),
        (Join-Path $repoRoot 'skills'),
        (Join-Path $repoRoot 'capabilities'),
        (Join-Path $repoRoot 'linear'),
        (Join-Path $repoRoot 'obsidian')
    )

Write-Host 'PASS drift and portability checks'
exit 0
