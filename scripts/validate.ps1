#Requires -Version 7
<#
.SYNOPSIS
    Windows-native validator — PS twin of scripts/validate.sh.

.DESCRIPTION
    validate.ps1 — <TEAM>-100 prototype port, <TEAM>-124 extension.

    Checks (in order, matching validate.sh's order so output is operator-familiar):
      1. .DS_Store scan (with .claude/.codex/.agents worktrees allowlist)
      2. embedded .git directory scan
      3. forbidden-artifacts list (loose files at repo root + harness-config
         allowlist + security precheck for .claude/skills auto-load attack)
      4. secret-pattern scan (path-anchored allowlist for harness worktrees)
      5. capability-spec header completeness
      6. lifecycle frontmatter convention
      7. local.env gitignored
      8. harness adapter.md presence
      9. internal markdown link integrity (<TEAM>-53 C7 + <TEAM>-63 fence parser +
         <TEAM>-105 13-prefix GitHub-platform skip-list + harnesses/*/vendored/*
         allowlist; <TEAM>-124 added this PS twin)

    Exits 0 if all checks pass, 1 on first failure.

    Drift-checking (scripts/check-drift.ps1) is a separate script and is NOT
    invoked from here; bash twin's `"$repo_root/scripts/check-drift.sh"` tail
    invocation is handled out-of-band by the operator (`make verify` or CI).

.NOTES
    <TEAM>-109 PS-5: $PSScriptRoot empty-string fallback applied.

    -RepoRoot param lets the test suite point this at a fixture dir; absent,
    it resolves to the parent of $PSScriptRoot.

.PARAMETER RepoRoot
    Override the repo root used for the scan. Defaults to the parent of the
    directory containing this script.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Repo root resolution (<TEAM>-109 PS-5)
# ---------------------------------------------------------------------------

if ($RepoRoot) {
    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
} elseif ($PSScriptRoot) {
    $repo = Split-Path $PSScriptRoot -Parent
} else {
    $repo = (Resolve-Path "$PWD/..").Path
}

Write-Host "agentic-os-template validation"
Write-Host "Repo: $repo"
Write-Host ""

function Fail-Validation { param([string]$Msg) [Console]::Error.WriteLine($Msg); exit 1 }
function Pass-Line { param([string]$Msg) Write-Host $Msg }

# ---------------------------------------------------------------------------
# Co-located harness config-dir resolution (<TEAM>-285 recognition; hoisted by
# <TEAM>-319). When the operator points a harness config-dir variable
# (CLAUDE_CONFIG_DIR / CODEX_HOME / HERMES_HOME) at a dir under the repo root,
# that dir holds the harness's own gitignored output + runtime state — plugin
# clones carrying their OWN .git, a Finder .DS_Store, etc. <TEAM>-285 added this
# recognition to the forbidden-artifacts scan ONLY; <TEAM>-319 hoists it ABOVE the
# .DS_Store + embedded-.git scans so those two tree-walks prune a co-located
# config dir's contents — a co-located install previously cascade-failed
# `make verify`. Mirrors validate.sh's hoisted block + _under_colocated_cfg.
# ---------------------------------------------------------------------------

# <TEAM>-328 Item A: build a fully-resolved map of local.env's KEY=VALUE
# assignments, in file order, so a later line may reference an earlier var
# (BASE=...; CLAUDE_CONFIG_DIR=$BASE/.claude). The bash twin gets this for free
# by sourcing local.env in a subshell (validate.sh's cfg_* block); PS has no
# shell to source, so the prior single-line parser expanded $VAR against ONLY
# the process environment — a var defined in local.env but never exported
# resolved to empty, corrupting the path and leaving a co-located config dir
# unrecognized on Windows. Emulating bash in-order sourcing here keeps bash<->PS
# config-dir recognition identical. Quote/escape handling mirrors
# scripts/lib/local-env.ps1 Import-LocalEnv. Cached per local.env path: built
# once even though Get-ConfiguredConfigDirPhys is called per harness var.
$script:LocalEnvMap = $null
$script:LocalEnvMapKey = $null
function Get-LocalEnvMap {
    param([string]$RepoRoot)
    $localEnv = Join-Path $RepoRoot 'local.env'
    # Constant (non-null string) on the LHS so the cache check is an unambiguous
    # scalar compare, never PS array-filtering semantics.
    if ($localEnv -eq $script:LocalEnvMapKey) { return $script:LocalEnvMap }
    $map = [ordered]@{}
    if (Test-Path -LiteralPath $localEnv -PathType Leaf) {
        # Unreadable local.env (ACL / lock): the bash twin sources with
        # `2>/dev/null` + `set +eu` and falls back to empty, so match that here
        # rather than crash under $ErrorActionPreference='Stop'.
        $envLines = @()
        try { $envLines = [System.IO.File]::ReadAllLines($localEnv) } catch { $envLines = @() }
        foreach ($line in $envLines) {
            $trim = $line.Trim()
            if ($trim.Length -eq 0) { continue }
            if ($trim.StartsWith('#', [StringComparison]::Ordinal)) { continue }
            if ($trim -match '^export\s+(.+)$') { $trim = $matches[1] }
            if ($trim -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
            $key = $matches[1]
            $val = $matches[2]
            # Strip a trailing inline comment (whitespace then `#...`) before quote
            # handling — bash sourcing drops a trailing comment that sits outside
            # quotes, and the prior single-line parser did too; not stripping it
            # was a bash<->PS parity regression. The `\s+#` anchor means `val#x`
            # (no preceding space) stays literal, matching bash.
            $val = $val -replace '\s+#.*$', ''
            # Balanced surrounding quotes are stripped. A single-quoted value is
            # literal (bash performs no $VAR expansion inside ''); an unquoted
            # %q-escaped value has its backslash-escapes collapsed (mirrors
            # scripts/lib/local-env.ps1 Import-LocalEnv). Bash's in-double-quote
            # escape processing (\$, \\) is intentionally NOT emulated — config-dir
            # values are plain paths; same documented scope as Import-LocalEnv.
            $singleQuoted = $false
            if ($val.Length -ge 2) {
                $first = $val[0]; $last = $val[$val.Length - 1]
                if ($first -ceq '"' -and $last -ceq '"') {
                    $val = $val.Substring(1, $val.Length - 2)
                } elseif ($first -ceq "'" -and $last -ceq "'") {
                    $val = $val.Substring(1, $val.Length - 2)
                    $singleQuoted = $true
                } elseif ($val.Contains([char]'\')) {
                    $val = [System.Text.RegularExpressions.Regex]::Replace($val, '\\(.)', '$1')
                }
            }
            if (-not $singleQuoted) {
                # ${VAR} or $VAR, resolved against the accumulating map first
                # (earlier local.env lines), then the process environment —
                # bash `set -a; . local.env` in-order semantics. The two-branch
                # alternation matches ${VAR} OR $VAR distinctly, so a mismatched
                # `$VAR}` leaves the `}` literal (as bash does). %VAR% is NOT
                # expanded: bash has no %VAR% syntax, so expanding it would diverge.
                $val = [regex]::Replace($val, '\$\{(\w+)\}|\$(\w+)', {
                    param($m)
                    $name = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
                    if ($map.Contains($name)) { [string]$map[$name] }
                    else { [string][Environment]::GetEnvironmentVariable($name) }
                }.GetNewClosure())
            }
            $map[$key] = $val
        }
    }
    $script:LocalEnvMap = $map
    $script:LocalEnvMapKey = $localEnv
    return $map
}

# Resolve a harness config-dir variable (CLAUDE_CONFIG_DIR / CODEX_HOME /
# HERMES_HOME) to a physical path — environment first, then the resolved
# local.env map (Get-LocalEnvMap, which mirrors bash sourcing incl. variable
# composition). Returns '' when unset or the path does not resolve. Mirrors
# validate.sh's env-then-local.env resolution so a CO-LOCATED config dir is
# recognized identically on both platforms.
function Get-ConfiguredConfigDirPhys {
    param([string]$EnvName, [string]$RepoRoot)
    $val = [Environment]::GetEnvironmentVariable($EnvName)
    if ([string]::IsNullOrEmpty($val)) {
        $map = Get-LocalEnvMap -RepoRoot $RepoRoot
        if ($map.Contains($EnvName)) { $val = [string]$map[$EnvName] }
    }
    if ([string]::IsNullOrEmpty($val)) { return '' }
    try { return (Resolve-Path -LiteralPath $val -ErrorAction Stop).Path } catch { return '' }
}

# Repo-root harness dirs that resolve to a configured config dir. Computed once.
# Empty when no co-located install (maintainer default / CI) — the scans then
# behave exactly as before. (.agents has no config variable, so it is never
# registered and stays fully guarded.)
#
# Mirrors validate.sh's _register_colocated EXACTLY: a config var is recognized
# ONLY when a repo-root harness dir (.claude/.codex/.hermes) PHYSICALLY equals
# the resolved config path. Storing every resolved config path unconditionally
# would prune leak-guard findings under ANY dir a config var happens to point at
# (e.g. CLAUDE_CONFIG_DIR=$repo/core) — which bash never does. The stored key is
# the repo-root harness dir ($repo/.claude), matching the prefix Get-ChildItem
# prints for artifacts inside it. (Parity fix caught by cross-model review.)
$script:ColocatedCfgDirs = @()
foreach ($pair in @(
    @{ Name = '.claude'; EnvName = 'CLAUDE_CONFIG_DIR' },
    @{ Name = '.codex';  EnvName = 'CODEX_HOME' },
    @{ Name = '.hermes'; EnvName = 'HERMES_HOME' }
)) {
    $cfgPhys = Get-ConfiguredConfigDirPhys $pair.EnvName $repo
    if ([string]::IsNullOrEmpty($cfgPhys)) { continue }
    $hd = Join-Path $repo $pair.Name
    if (-not (Test-Path -LiteralPath $hd -PathType Container)) { continue }
    $hdPhys = (Resolve-Path -LiteralPath $hd -ErrorAction SilentlyContinue).Path
    if ($hdPhys -and ($hdPhys -eq $cfgPhys)) {
        $script:ColocatedCfgDirs += $hd
    }
}

# True when $Path lives inside a recognized co-located config dir.
function Test-UnderColocatedCfg {
    param([string]$Path)
    foreach ($cfg in $script:ColocatedCfgDirs) {
        if ($Path.StartsWith($cfg + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

# Test-ParentGitIgnored <path> — $true when the CONTAINING directory is
# excluded by the repo's effective ignore rules (.gitignore OR the
# operator-local .git/info/exclude). <TEAM>-394: the static prunes name only
# the framework's own gitignored dirs; an operator's info/exclude'd workspace
# (a .toolkit/, an extra checkout dir) is invisible to them, so its checkouts'
# .git dirs / Finder .DS_Store drops failed the junk scans from a living home.
# Checking the PARENT (not the hit itself) keeps root junk failing: a root
# .DS_Store's parent is the repo root, which is never ignored, while .DS_Store
# by NAME is gitignored — filtering on the hit itself would neuter the scan.
# Outside a git work tree (or with git absent) returns $false — fs-mode keeps
# the static prunes only, same as the bash twin.
# core.excludesFile pinned to NUL (panel C4): only the repo's own .gitignore
# + its .git/info/exclude may decide — never the operator's machine-global
# excludes, which would make the junk scans machine-dependent.
function Test-ParentGitIgnored {
    param([string]$Path)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    $parent = Split-Path -Parent $Path
    if ([string]::IsNullOrEmpty($parent)) { return $false }
    $nullFile = if ($IsWindows) { 'NUL' } else { '/dev/null' }
    & git -C $repo -c "core.excludesFile=$nullFile" check-ignore -q -- $parent 2>$null
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
# 1. .DS_Store scan
# ---------------------------------------------------------------------------

function Test-DSStore {
    # Allowlist harness-managed worktree subtrees per validate.sh <TEAM>-60/61,
    # plus the gitignored runtime-artifact dirs (cross-model-out/, .codegraph/)
    # per validate.sh <TEAM>-244 — driver-local per-run output that can never enter
    # git, mirroring check-drift's gitignored-runtime prune. projects/ joins the
    # set (<TEAM>-394): the shipped .gitignore declares it the operator's local
    # project workspace ("never tracked"), and a real workspace holds whole
    # checkouts — Finder .DS_Store drops there are operator content.
    $allowList = @(
        (Join-Path $repo '.claude'  'worktrees'),
        (Join-Path $repo '.codex'   'worktrees'),
        (Join-Path $repo '.agents'  'worktrees'),
        (Join-Path $repo 'cross-model-out'),
        (Join-Path $repo 'projects'),
        (Join-Path $repo '.codegraph')
    )
    # <TEAM>-328 Item B: capture traversal errors via -ErrorVariable and FAIL
    # closed. A bare -EA SilentlyContinue silently swallows a permission-denied
    # subdir mid-recursion, so the scan would false-PASS on an unreadable tree —
    # the PS mirror of the bash twin's find-exit-status check (and of the secret
    # scan's $gciErr fail-closed pattern below).
    $dsErr = @()
    $offenders = @(Get-ChildItem -LiteralPath $repo -Recurse -File -Force -Filter '.DS_Store' -ErrorAction SilentlyContinue -ErrorVariable dsErr |
        Where-Object {
            $f = $_.FullName
            $isAllow = $false
            foreach ($p in $allowList) {
                if ($f.StartsWith($p + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $isAllow = $true; break }
            }
            # <TEAM>-319: also drop artifacts inside a co-located config dir.
            if (-not $isAllow -and (Test-UnderColocatedCfg $f)) { $isAllow = $true }
            # <TEAM>-394: drop artifacts whose containing dir is git-ignored
            # (operator workspaces incl. info/exclude'd dirs).
            if (-not $isAllow -and (Test-ParentGitIgnored $f)) { $isAllow = $true }
            -not $isAllow
        }
    )
    if ($dsErr.Count -gt 0) {
        [Console]::Error.WriteLine("FAIL .DS_Store scan: directory enumeration errored ($($dsErr.Count) error(s)); not treating as clean")
        foreach ($e in $dsErr) { [Console]::Error.WriteLine("       $($e.Exception.Message)") }
        exit 1
    }
    if ($offenders.Count -gt 0) {
        [Console]::Error.WriteLine("FAIL .DS_Store files found")
        foreach ($o in $offenders) {
            [Console]::Error.WriteLine($o.FullName)
        }
        exit 1
    }
    Pass-Line "PASS no .DS_Store files"
}
Test-DSStore

# ---------------------------------------------------------------------------
# 2. Embedded .git directory scan
# ---------------------------------------------------------------------------

function Test-EmbeddedGit {
    $rootGit = (Join-Path $repo '.git')
    # <TEAM>-244: also prune .git dirs inside the gitignored runtime-artifact dirs
    # (cross-model-out/, .codegraph/) — a cross-model run that captured output
    # from a cloned repo, or a codegraph index, can leave a nested .git there
    # that is driver-local, never committable framework content. Mirrors
    # validate.sh's prune + check-drift's gitignored-runtime exclusion.
    # projects/ joins the set (<TEAM>-394): the operator's local project
    # workspace holds whole repo checkouts by design, so nested .git dirs
    # there are operator content, never framework content.
    $excludeRoots = @(
        (Join-Path $repo 'cross-model-out'),
        (Join-Path $repo 'projects'),
        (Join-Path $repo '.codegraph')
    )
    # <TEAM>-328 Item B: same -ErrorVariable fail-closed as the .DS_Store scan —
    # a permission-denied subtree must FAIL the scan, not silently false-PASS.
    $gitErr = @()
    $offenders = @(Get-ChildItem -LiteralPath $repo -Recurse -Directory -Force -Filter '.git' -ErrorAction SilentlyContinue -ErrorVariable gitErr |
        Where-Object {
            $f = $_.FullName
            $skip = ($f -eq $rootGit -or $f.StartsWith($rootGit + [IO.Path]::DirectorySeparatorChar))
            if (-not $skip) {
                foreach ($r in $excludeRoots) {
                    if ($f.StartsWith($r + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
                }
            }
            # <TEAM>-319: also drop .git dirs inside a co-located config dir
            # (plugin-marketplace clones carry their own .git).
            if (-not $skip -and (Test-UnderColocatedCfg $f)) { $skip = $true }
            # <TEAM>-394: drop .git dirs whose containing dir is git-ignored
            # (operator workspaces incl. info/exclude'd dirs).
            if (-not $skip -and (Test-ParentGitIgnored $f)) { $skip = $true }
            -not $skip
        }
    )
    if ($gitErr.Count -gt 0) {
        [Console]::Error.WriteLine("FAIL embedded .git scan: directory enumeration errored ($($gitErr.Count) error(s)); not treating as clean")
        foreach ($e in $gitErr) { [Console]::Error.WriteLine("       $($e.Exception.Message)") }
        exit 1
    }
    if ($offenders.Count -gt 0) {
        [Console]::Error.WriteLine("FAIL embedded .git directories found")
        foreach ($o in $offenders) {
            [Console]::Error.WriteLine($o.FullName)
        }
        exit 1
    }
    Pass-Line "PASS no embedded .git directories"
}
Test-EmbeddedGit

# ---------------------------------------------------------------------------
# 3. Forbidden artifacts at repo root + harness-config allowlist
# ---------------------------------------------------------------------------

# (Get-ConfiguredConfigDirPhys is defined once near the top of this script —
# hoisted by <TEAM>-319 so the .DS_Store + embedded-.git scans share it. The
# $cfgDirs map below reuses it for the per-harness co-located match.)

function Test-ForbiddenArtifacts {
    $rootForbidden = @(
        '.env', 'auth.json', 'config.toml', 'settings.json', 'vault', 'codex'
    )
    foreach ($name in $rootForbidden) {
        $path = Join-Path $repo $name
        if (Test-Path -LiteralPath $path) {
            [Console]::Error.WriteLine("FAIL forbidden local or legacy artifact present: $path")
            exit 1
        }
    }

    # Recognize a deliberately CO-LOCATED harness config dir below: when the
    # operator points a harness's config-dir variable at a dir under the repo
    # root (CLAUDE_CONFIG_DIR=$repo/.claude — running every harness out of the
    # framework folder), that dir holds the harness's own gitignored output +
    # state, out of scope for this leak guard. Resolve each configured target to
    # a physical path. Mirrors validate.sh. In the maintainer default
    # (~/.claude etc.) and CI (temp-dir config), none equal $repo/.<harness>, so
    # the reject still fires on a genuine leak.
    $cfgDirs = @{
        '.claude' = (Get-ConfiguredConfigDirPhys 'CLAUDE_CONFIG_DIR' $repo)
        '.codex'  = (Get-ConfiguredConfigDirPhys 'CODEX_HOME' $repo)
        '.hermes' = (Get-ConfiguredConfigDirPhys 'HERMES_HOME' $repo)
    }

    # Harness-config dirs at repo root may contain ONLY:
    #   worktrees/            — operator parallel-branch workspaces
    #   settings.local.json   — operator-local permission tweaks
    # Anything else is a hand-edit leak (unless the dir is the co-located config
    # target recognized via $cfgDirs above).
    foreach ($hname in '.claude', '.codex', '.hermes', '.agents') {
        $hdir = Join-Path $repo $hname
        if (-not (Test-Path -LiteralPath $hdir)) { continue }
        if (-not (Test-Path -LiteralPath $hdir -PathType Container)) {
            [Console]::Error.WriteLine("FAIL forbidden harness-config artifact at repo root (not a directory): $hdir")
            exit 1
        }
        # Co-located config target: when this repo-root harness dir IS the
        # operator's configured config dir, its contents are the harness's own
        # gitignored output + state, not a leak — recognize it and skip the
        # reject. Matched by physical path, so a stray dir when the config lives
        # elsewhere still falls through to the rejects below. Mirrors validate.sh.
        $cfgPhys = $cfgDirs[$hname]
        if (-not [string]::IsNullOrEmpty($cfgPhys)) {
            $hdirPhys = (Resolve-Path -LiteralPath $hdir -ErrorAction SilentlyContinue).Path
            if ($hdirPhys -and ($hdirPhys -eq $cfgPhys)) {
                Pass-Line "PASS co-located harness config dir recognized (out of leak-guard scope): $hdir"
                continue
            }
        }
        # <TEAM>-394: an operator can declare the repo-root .agents/ dir their
        # own OPERATOR STATE by excluding it in .git/info/exclude — the ONE
        # harness workspace with no config variable (.claude/.codex/.hermes
        # use the co-location path above). Restricted to .agents DELIBERATELY
        # (panel F2): .claude/skills/ is the actual finding-#8 auto-load
        # surface and the harness loads it regardless of git ignore status.
        # Mirrors validate.sh.
        if ($hname -eq '.agents' -and (Get-Command git -ErrorAction SilentlyContinue)) {
            $ciOut = (& git -C $repo check-ignore -v -- $hname 2>$null)
            if ($LASTEXITCODE -eq 0 -and $ciOut -and (@($ciOut) -join "`n").StartsWith('.git/info/exclude:')) {
                Pass-Line "PASS operator-declared harness workspace (.git/info/exclude) out of leak-guard scope: $hdir"
                continue
            }
        }
        # Security precheck — skills/ at framework repo root is the auto-load
        # attack surface from <TEAM>-67 finding #8.
        if (Test-Path -LiteralPath (Join-Path $hdir 'skills')) {
            [Console]::Error.WriteLine("FAIL security: $hdir/skills/ at repo root would auto-load into Claude Code sessions")
            [Console]::Error.WriteLine("       per <TEAM>-67 finding #8 — skills belong in `$CLAUDE_CONFIG_DIR/skills/, never in a framework repo root.")
            exit 1
        }
        $leaked = @(Get-ChildItem -LiteralPath $hdir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'worktrees' -and $_.Name -ne 'settings.local.json' }
        )
        if ($leaked.Count -gt 0) {
            [Console]::Error.WriteLine("FAIL hand-edited harness config at repo root — move to `$CLAUDE_CONFIG_DIR / `$CODEX_HOME:")
            foreach ($l in $leaked) {
                [Console]::Error.WriteLine("       $($l.FullName)")
            }
            exit 1
        }
    }
    Pass-Line "PASS forbidden local and legacy artifacts absent"
}
Test-ForbiddenArtifacts

# ---------------------------------------------------------------------------
# 4. Secret-pattern scan
#
# Mirrors validate.sh's grep -rE pattern but uses Select-String. macOS/Linux
# `grep -rE` and PS `Select-String` use different regex flavors but both
# support the alternation + character-class shape we need.
#
# The pattern is constructed from non-matching pieces so this script's own
# source doesn't self-trip a scan when validate.sh is later run against the
# Windows port files.
# ---------------------------------------------------------------------------

function Test-SecretPattern {
    # Build the pattern at runtime from non-matching halves per
    # [[feedback_self_tripping_test_source]] — the `[` after each prefix breaks
    # the character class, so this script's own source never self-trips.
    $shKey = 'gh' + '[pousr]_[A-Za-z0-9_]{20,}'
    $skLive = 'sk' + '-[A-Za-z0-9_-]{20,}'
    $bgnPriv = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    $stripeLive = '(sk|pk)' + '_live_[A-Za-z0-9]{20,}'
    $pattern = "$shKey|$skLive|$bgnPriv|$stripeLive"

    # <TEAM>-246: scan the COMMITTABLE set (git ls-files --cached --others
    # --exclude-standard) — tracked PLUS untracked-not-gitignored files — mirroring
    # check-drift.ps1's <TEAM>-213 enumeration and the bash twin. Gitignored runtime
    # artifacts (cross-model-out/, .codegraph/, worktrees/, *.log, .mcp.json, the
    # harness .claude/.codex/.agents/ dirs) are pruned by --exclude-standard, so a
    # per-run log quoting a key-shaped string can't false-trip the scan and no
    # per-dir exclude list needs maintaining. Conversely a TRACKED file is always
    # scanned even when its NAME matches a gitignore rule (a force-added
    # daemon.log / .mcp.json): a committed secret is the only secret a leak guard
    # must catch. README.md (documented example key shapes) is the single tracked
    # exclusion; .git is never listed by ls-files.
    #
    # Git-worktree detection: TOPLEVEL-EQUALITY (not --is-inside-work-tree) so a
    # plain-copy staging tree nested under an unrelated parent repo falls back to
    # the filesystem walk rather than git-enumerating the wrong repo. (Mirror of
    # check-drift.ps1 / the bash twin.)
    # Gate on whether git returned a toplevel (git prints one only on success),
    # NOT on $LASTEXITCODE: under Set-StrictMode -Version Latest, reading
    # $LASTEXITCODE before any native command has set it throws, and the
    # `| Select-Object -First 1` early-stop can leave it unset on this first call.
    $isGit = $false
    $gitTop = (& git -C $repo rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if ($gitTop) {
        $topResolved = Resolve-Path -LiteralPath $gitTop -ErrorAction SilentlyContinue
        $repoResolved = Resolve-Path -LiteralPath $repo -ErrorAction SilentlyContinue
        if ($topResolved -and $repoResolved -and $topResolved.Path -eq $repoResolved.Path) { $isGit = $true }
        else {
            # Symlink/mount aliasing rescue (twin of the bash scripts' pwd -P +
            # -ef): git reports the PHYSICAL toplevel while Resolve-Path keeps
            # the logical spelling (it does not resolve symlinks), so a live repo
            # reached through a symlinked path — e.g. macOS /tmp -> /private/tmp
            # — fails the string compare above. An EMPTY --show-prefix proves
            # $repo IS the toplevel under any spelling; a staging tree nested
            # under an unrelated parent repo yields a NON-empty prefix and still
            # takes the intended fallback. Full-array capture (no early-stop
            # pipeline) so $LASTEXITCODE is reliably set under StrictMode.
            $gitPrefixOut = @(& git -C $repo rev-parse --show-prefix 2>$null)
            if ($LASTEXITCODE -eq 0 -and [string]::IsNullOrEmpty(($gitPrefixOut | Select-Object -First 1))) {
                $isGit = $true
            }
        }
    }

    # .git exists yet the git path was refused -> rev-parse refusal or a
    # path-resolution quirk. The fs-walk fallback is only legitimate for a
    # plain-copy staging tree (no .git); fail loudly instead of silently
    # widening the scan. (Mirror of check-drift.ps1 / the bash twin.)
    $dotGitPath = Join-Path $repo '.git'
    # Get-Item -Force alongside Test-Path: Test-Path can report $false for a
    # dangling .git symlink/junction; Get-Item -Force sees the link entry
    # itself. (Mirror of check-drift.ps1 / the bash twins' -e || -L.)
    $dotGitEntry = (Test-Path -LiteralPath $dotGitPath) -or
        [bool](Get-Item -LiteralPath $dotGitPath -Force -ErrorAction SilentlyContinue)
    if (-not $isGit -and $dotGitEntry) {
        [Console]::Error.WriteLine("FAIL secret scan: $repo\.git exists but git enumeration was not selected")
        [Console]::Error.WriteLine("     (git rev-parse failed, or toplevel did not match / could not be resolved - check safe.directory/ownership).")
        [Console]::Error.WriteLine("     Refusing to silently fall back to the filesystem walk.")
        exit 1
    }

    $hits = @()
    # Listed files we could not read (locked/deleted/permission). The bash twin
    # fails closed (grep exit >1 -> FAIL); a silent -EA SilentlyContinue skip
    # here would fail OPEN on a committable file PS can't read, the worse
    # direction since Windows CI is the gate. Accumulate + FAIL closed.
    $readErrorFiles = @()
    # Non-git fallback only: directory-traversal errors from the Get-ChildItem
    # walk (a permission-denied dir). -EA SilentlyContinue still RECORDS into
    # -ErrorVariable (unlike -EA Ignore), so we fail closed on an unreadable dir
    # whose files would otherwise silently vanish from the scan — matching the
    # bash twin's `grep -r` exit-2. Stays @() on the git branch (that branch
    # enumerates via ls-files, not the walk), so the post-scan check is a no-op there.
    $gciErr = @()
    # Root README.md (documented example key shapes) is the single tracked
    # exclusion — ROOT-EXACT, not basename, so a nested docs/README.md carrying
    # a real token is still scanned.
    $rootReadme = Join-Path $repo 'README.md'
    if ($isGit) {
        # core.quotePath=false: emit non-ASCII names raw so they ARE scanned; a
        # control-char name stays git-quoted (leading ") → fail closed. A git
        # enumeration failure FAILs the scan rather than yielding an empty list
        # that would read as "no hits -> pass".
        $listed = @(& git -C $repo -c core.quotePath=false ls-files --cached --others --exclude-standard -- . 2>$null)
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("FAIL secret scan: git ls-files enumeration errored (exit $LASTEXITCODE); not treating as clean")
            exit 1
        }
        foreach ($rel in $listed) {
            if ([string]::IsNullOrEmpty($rel)) { continue }
            if ($rel.StartsWith('"')) {
                [Console]::Error.WriteLine("FAIL secret scan: cannot safely scan git-quoted path (control char in filename): $rel")
                exit 1
            }
            # -ceq (case-SENSITIVE): the bash twin's `[ "$secret_f" = "README.md" ]`
            # is byte-exact, so a root readme.md / ReadMe.md must be SCANNED, not
            # treated as the exempt README — PS `-eq` is case-insensitive and would
            # open a PS-only leak bypass for case variants.
            if ($rel -ceq 'README.md') { continue }
            $full = Join-Path $repo $rel
            try {
                $m = Select-String -LiteralPath $full -Pattern $pattern -AllMatches -ErrorAction Stop
                if ($m) { foreach ($mm in $m) { $hits += "${full}:$($mm.LineNumber):$($mm.Line)" } }
            } catch {
                $readErrorFiles += $full
            }
        }
    } else {
        # Non-git fallback: filesystem walk + root-anchored exclude (pre-<TEAM>-246).
        # A plain-copy staging/export tree has no .git, so no gitignored runtime
        # state to prune via git; the StartsWith check appends a separator so the
        # exclusion is ROOT-ANCHORED — only the top-level dir is pruned, and a
        # nested same-named dir or a committable sibling is STILL scanned.
        $excludeRoots = @(
            (Join-Path $repo '.git'),
            (Join-Path $repo '.claude' 'worktrees'),
            (Join-Path $repo '.codex'  'worktrees'),
            (Join-Path $repo '.agents' 'worktrees'),
            (Join-Path $repo 'cross-model-out'),
            (Join-Path $repo '.codegraph')
        )
        Get-ChildItem -LiteralPath $repo -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable gciErr |
            Where-Object {
                $f = $_.FullName
                $skip = $false
                foreach ($r in $excludeRoots) {
                    if ($f.StartsWith($r + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
                }
                # Ordinal (case-SENSITIVE) to match the bash twin's byte-exact
                # README check — a case-variant root readme.md must still be
                # scanned, not skipped.
                if (-not $skip -and [string]::Equals($_.FullName, $rootReadme, [System.StringComparison]::Ordinal)) { $skip = $true }
                -not $skip
            } |
            ForEach-Object {
                try {
                    $m = Select-String -LiteralPath $_.FullName -Pattern $pattern -AllMatches -ErrorAction Stop
                    if ($m) { foreach ($mm in $m) { $hits += "$($_.FullName):$($mm.LineNumber):$($mm.Line)" } }
                } catch {
                    $readErrorFiles += $_.FullName
                }
            }
    }
    # A permission-denied DIRECTORY makes the non-git Get-ChildItem walk error
    # (captured above via -ErrorVariable); its files are never enumerated, so a
    # secret inside would hide and the scan would fail OPEN. Fail closed to match
    # the bash twin (`grep -r` exit 2 -> the `secret_status -gt 1` check). No
    # exclude-dir filtering here (unlike check-drift.ps1's Test-ScanPath): the bash
    # twin's grep passes ONLY `--exclude-dir=.git`, post-filtering (not pruning
    # traversal of) cross-model-out/.codegraph/worktrees — so bash ENTERS those and
    # ALSO fails closed on an unreadable dir there; matching it means failing on any
    # error. The lone divergent dir is `.git`, already caught by the embedded-.git
    # scan (check 2) before this secret scan runs — so the divergence is unreachable.
    if ($gciErr.Count -gt 0) {
        [Console]::Error.WriteLine("FAIL secret scan: directory enumeration errored in non-git fallback ($($gciErr.Count) error(s)); not treating as clean")
        foreach ($e in $gciErr) { [Console]::Error.WriteLine("       $($e.Exception.Message)") }
        exit 1
    }
    if ($readErrorFiles.Count -gt 0) {
        [Console]::Error.WriteLine("FAIL secret scan: could not read $($readErrorFiles.Count) listed file(s); not treating as pass")
        foreach ($rf in $readErrorFiles) { [Console]::Error.WriteLine("       $rf") }
        exit 1
    }
    if ($hits.Count -gt 0) {
        [Console]::Error.WriteLine("FAIL likely secret pattern found")
        foreach ($h in $hits) { [Console]::Error.WriteLine($h) }
        exit 1
    }
    Pass-Line "PASS repository secret pattern scan"
}
Test-SecretPattern

# ---------------------------------------------------------------------------
# 5. Capability-spec header completeness
# ---------------------------------------------------------------------------

function Test-CapabilityHeaders {
    $capDir = Join-Path $repo 'capabilities'
    if (-not (Test-Path -LiteralPath $capDir -PathType Container)) {
        [Console]::Error.WriteLine("FAIL capabilities/ directory missing")
        exit 1
    }

    function Get-FmBlock { param([string]$Path)
        $lines = [System.IO.File]::ReadAllLines($Path)
        if ($lines.Count -eq 0 -or $lines[0] -ne '---') { return $null }
        $out = New-Object System.Collections.Generic.List[string]
        $closed = $false
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^---\s*$') { $closed = $true; break }
            [void]$out.Add($lines[$i])
        }
        # validate.sh's check_capabilities tolerates unterminated frontmatter
        # (no closing ---) but flags empty body. Replicate: only require non-
        # empty body; do not enforce closing fence here (lifecycle does).
        return ($out -join "`n")
    }
    function Get-FmVal { param([string]$Block, [string]$Key)
        if ([string]::IsNullOrEmpty($Block)) { return '' }
        foreach ($line in ($Block -split "`n")) {
            $pattern = "^${Key}:\s*(.*)$"
            if ($line -match $pattern) { return $matches[1].TrimEnd() }
        }
        return ''
    }

    $found = 0
    foreach ($file in (Get-ChildItem -LiteralPath $capDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($base -eq 'README') { continue }
        $found++

        $firstLine = (Get-Content -LiteralPath $file.FullName -TotalCount 1)
        if ($firstLine -ne '---') {
            [Console]::Error.WriteLine("FAIL capability ${base}: missing YAML frontmatter (no opening ---)")
            exit 1
        }
        $fm = Get-FmBlock -Path $file.FullName
        if ([string]::IsNullOrEmpty($fm)) {
            [Console]::Error.WriteLine("FAIL capability ${base}: empty or unterminated frontmatter")
            exit 1
        }

        foreach ($key in 'name', 'summary', 'triggers', 'verification', 'harnesses', 'kind') {
            $pat = "^${key}:\s*\S"
            $found_key = $false
            foreach ($l in ($fm -split "`n")) {
                if ($l -match $pat) { $found_key = $true; break }
            }
            if (-not $found_key) {
                [Console]::Error.WriteLine("FAIL capability ${base}: missing or empty required header key: $key")
                exit 1
            }
        }

        $vName = Get-FmVal -Block $fm -Key 'name'
        if ($vName -ne $base) {
            [Console]::Error.WriteLine("FAIL capability ${base}: header name `"$vName`" does not match filename")
            exit 1
        }
        $vKind = Get-FmVal -Block $fm -Key 'kind'
        if ($vKind -ne 'native' -and $vKind -ne 'vendored') {
            [Console]::Error.WriteLine("FAIL capability ${base}: kind must be native or vendored (got `"$vKind`")")
            exit 1
        }
        foreach ($lk in 'triggers', 'harnesses') {
            $lv = Get-FmVal -Block $fm -Key $lk
            if ($lv -notmatch '^\[[^\[\]]*[^\[\]\s][^\[\]]*\]$') {
                [Console]::Error.WriteLine("FAIL capability ${base}: $lk must be a non-empty [list] (got `"$lv`")")
                exit 1
            }
        }
        $vVer = Get-FmVal -Block $fm -Key 'verification'
        if ($vVer -ne 'none' -and -not (Test-Path -LiteralPath (Join-Path $repo 'verification' ($vVer + '.md')) -PathType Leaf)) {
            [Console]::Error.WriteLine("FAIL capability ${base}: verification gate `"$vVer`" not found in verification/")
            exit 1
        }
        $harnessList = (Get-FmVal -Block $fm -Key 'harnesses') -replace '[\[\]]','' -split ','
        foreach ($h in $harnessList) {
            $h = $h.Trim()
            if (-not $h) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $repo 'harnesses' $h) -PathType Container)) {
                [Console]::Error.WriteLine("FAIL capability ${base}: listed harness `"$h`" has no harnesses/$h/ adapter")
                exit 1
            }
        }
        if ($vKind -eq 'vendored') {
            foreach ($vk in 'source', 'version', 'install') {
                $pat = "^${vk}:\s*\S"
                $ok = $false
                foreach ($l in ($fm -split "`n")) { if ($l -match $pat) { $ok = $true; break } }
                if (-not $ok) {
                    [Console]::Error.WriteLine("FAIL capability ${base}: vendored capability missing required key: $vk")
                    exit 1
                }
            }
        }
    }
    if ($found -eq 0) {
        [Console]::Error.WriteLine("FAIL capabilities/ contains no capability specs")
        exit 1
    }
    Pass-Line "PASS capability headers complete ($found specs)"
}
Test-CapabilityHeaders

# ---------------------------------------------------------------------------
# 6. Lifecycle frontmatter convention (<TEAM>-83 5-enum)
# ---------------------------------------------------------------------------

function Test-Lifecycle {
    $validRe = '^lifecycle:\s+(experimental|reviewed|shipped|superseded|sunset)\s*$'
    $found = 0
    # Use git ls-files so dotfile sentinels are enumerated. If $repo is not
    # a git checkout, skip with PASS.
    Push-Location $repo
    try {
        $isGit = $true
        $null = & git rev-parse --git-dir 2>$null
        if ($LASTEXITCODE -ne 0) { $isGit = $false }
        if (-not $isGit) {
            Pass-Line "PASS lifecycle frontmatter convention (skipped — not a git checkout)"
            return
        }
        $tracked = & git ls-files
        foreach ($rel in $tracked) {
            # In-scope paths.
            $inScope = $false
            switch -Wildcard ($rel) {
                'docs/plans/*.md' { $inScope = $true }
                'docs/specs/*.md' { $inScope = $true }
                'docs/*/plans/*.md' { $inScope = $true }
                'docs/*/specs/*.md' { $inScope = $true }
                'capabilities/*.md' { $inScope = $true }
                'harnesses/*/capabilities/*.md' { $inScope = $true }
            }
            if (-not $inScope) { continue }
            $file = Join-Path $repo $rel
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
            $base = [System.IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileName($rel))
            if ($base -eq 'README') { continue }
            $found++

            $firstLine = (Get-Content -LiteralPath $file -TotalCount 1)
            if ($firstLine -ne '---') {
                [Console]::Error.WriteLine("FAIL lifecycle ${rel}: missing YAML frontmatter (no opening ---)")
                exit 1
            }
            $lines = [System.IO.File]::ReadAllLines($file)
            $closed = $false
            $fm = New-Object System.Collections.Generic.List[string]
            for ($i = 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^---\s*$') { $closed = $true; break }
                [void]$fm.Add($lines[$i])
            }
            if (-not $closed) {
                [Console]::Error.WriteLine("FAIL lifecycle ${rel}: unterminated YAML frontmatter (no closing ---)")
                exit 1
            }
            if ($fm.Count -eq 0) {
                [Console]::Error.WriteLine("FAIL lifecycle ${rel}: empty frontmatter block")
                exit 1
            }
            $hasLifecycle = $false
            foreach ($l in $fm) {
                if ($l -match $validRe) { $hasLifecycle = $true; break }
            }
            if (-not $hasLifecycle) {
                [Console]::Error.WriteLine("FAIL lifecycle ${rel}: missing or invalid lifecycle: value")
                [Console]::Error.WriteLine("       expected one of: experimental | reviewed | shipped | superseded | sunset")
                exit 1
            }
        }
    } finally {
        Pop-Location
    }
    if ($found -eq 0) {
        Pass-Line "PASS lifecycle frontmatter convention (0 in-scope artifacts)"
    } else {
        Pass-Line "PASS lifecycle frontmatter convention ($found in-scope artifacts)"
    }
}
Test-Lifecycle

# ---------------------------------------------------------------------------
# 7. local.env gitignored
# ---------------------------------------------------------------------------

function Test-LocalEnvGitignored {
    $gi = Join-Path $repo '.gitignore'
    if (-not (Test-Path -LiteralPath $gi -PathType Leaf)) {
        [Console]::Error.WriteLine("FAIL .gitignore missing; cannot confirm local.env is ignored")
        exit 1
    }
    $patterns = @(Get-Content -LiteralPath $gi -ErrorAction SilentlyContinue)
    $hasPattern = $false
    foreach ($p in $patterns) {
        $t = $p.Trim()
        if ($t -eq 'local.env' -or $t -eq '/local.env') { $hasPattern = $true; break }
    }
    if (-not $hasPattern) {
        [Console]::Error.WriteLine("FAIL .gitignore does not ignore local.env (machine secrets/paths must not be committed)")
        exit 1
    }
    $localEnv = Join-Path $repo 'local.env'
    if (Test-Path -LiteralPath $localEnv -PathType Leaf) {
        Push-Location $repo
        try {
            $isGit = $true
            $null = & git rev-parse --git-dir 2>$null
            if ($LASTEXITCODE -ne 0) { $isGit = $false }
            if ($isGit) {
                & git check-ignore -q 'local.env' 2>$null
                if ($LASTEXITCODE -ne 0) {
                    [Console]::Error.WriteLine("FAIL local.env exists and is NOT ignored by git")
                    exit 1
                }
            }
        } finally {
            Pop-Location
        }
    }
    Pass-Line "PASS local.env is gitignored"
}
Test-LocalEnvGitignored

# ---------------------------------------------------------------------------
# 8. Every harness has adapter.md
# ---------------------------------------------------------------------------

function Test-HarnessAdapters {
    $hdir = Join-Path $repo 'harnesses'
    if (-not (Test-Path -LiteralPath $hdir -PathType Container)) {
        [Console]::Error.WriteLine("FAIL harnesses/ directory missing")
        exit 1
    }
    $found = 0
    foreach ($h in (Get-ChildItem -LiteralPath $hdir -Directory -ErrorAction SilentlyContinue)) {
        $found++
        if (-not (Test-Path -LiteralPath (Join-Path $h.FullName 'adapter.md') -PathType Leaf)) {
            [Console]::Error.WriteLine("FAIL harness $($h.Name) has no adapter.md")
            exit 1
        }
    }
    if ($found -eq 0) {
        [Console]::Error.WriteLine("FAIL harnesses/ contains no harness directories")
        exit 1
    }
    Pass-Line "PASS every harness has an adapter.md"
}
Test-HarnessAdapters

# ---------------------------------------------------------------------------
# 9. Internal markdown link integrity (<TEAM>-53 C7 + <TEAM>-63 + <TEAM>-88 + <TEAM>-105
#    + <TEAM>-124)
#
# PS twin of `scripts/validate.sh` check_internal_links (lines ~439-633).
# Walks `git ls-files '*.md'` and verifies every inline `[text](target)` link
# resolves on disk relative to its source file's directory. Honors:
#
#   - vendored allowlist: `harnesses/<h>/vendored/**` (<TEAM>-42 — immutable
#     upstream snapshots, broken refs inside are upstream debt)
#   - CommonMark fences: 3+ same-char (` or ~) fences, 0-3 leading spaces,
#     length-aware (4-backtick fence not closed by 3-backtick line)
#   - inline-code stripping: longest-first triple → double → single backtick
#     so multi-backtick delimiter spans don't leak their content
#   - external schemes + anchors: `http(s)://`, `mailto:`, `ftp://`, `file://`,
#     `//`-protocol-relative, absolute paths (`/...`), pure `#anchor`
#   - title strip: `path "title"` / `path 'title'` before resolution
#   - query strip: `path?q=...` before resolution
#   - <TEAM>-105 13-prefix GitHub-platform skip-list: `issues` / `wiki` /
#     `pulls` / `pull` (singular detail route) / `releases` / `tree` / `blob` /
#     `labels` / `milestones` / `commits` / `commit` (singular detail route) /
#     `discussions`, each as `../../<seg>` bare AND `../../<seg>/` sub-path
#
# Per [[reference_ps_port_traps]]:
#   - trap #8 (count-string drift): output strings byte-identical to bash twin
#     ("PASS internal markdown links resolve" / "FAIL broken internal link in
#     <file> -> <target>" / "PASS internal markdown links (skipped — not a
#     git checkout)").
#   - <TEAM>-88 BSD/GNU awk regex divergence + LC_ALL=C: MOOT in .NET regex
#     (consistent across hosts; no locale-dependent gsub no-op).
#   - The fence parser is a line-iterator state machine (boolean + char +
#     length) instead of an awk script, which sidesteps any `(?m)` PS regex
#     multiline-flag traps. Each line is matched independently.
#   - trap #11 (relative-path): handled here by `Join-Path $repo $fileDir
#     $target` + `Test-Path -LiteralPath`, both of which canonicalize through
#     the OS path layer — no manual `$full.Substring($target.Length)` shape.
#   - Case-sensitivity: PowerShell `-match` is case-INsensitive by default;
#     bash POSIX `case` glob (validate.sh:606) is case-sensitive. Use
#     `-cmatch` + `-ceq` + `[StringComparison]::Ordinal` for all comparisons
#     so PS treats `[x](HTTPS://example.com)` exactly like bash (the bash
#     twin treats it as a LOCAL link). RFC-3986 case-insensitive URI
#     handling is intentionally out-of-scope for this parity port — would
#     be a separate cross-twin enhancement.
#
# Trust-boundary + DoS notes (adversarial review, documented out-of-scope):
#   - Filenames containing embedded newlines: `git ls-files '*.md'`
#     is read newline-delimited, matching bash twin's `IFS= read -r`
#     behavior (validate.sh:626). Both ports share the pathological-filename
#     trust assumption that framework repos don't carry such names.
#   - Pathological file size: `[System.IO.File]::ReadAllLines` materializes
#     each file fully. Bash twin's awk also reads each file end-to-end.
#     Framework markdown files are bounded (largest tracked .md ~10 KB);
#     swap to streaming if that bound is ever broken.
# ---------------------------------------------------------------------------

# <TEAM>-105: GitHub-platform path segments treated as external. Both bare
# (`../../issues`) and sub (`../../issues/123`) forms; plurals + singulars
# where GitHub uses them. Matches the bash twin's case-statement at
# validate.sh:605-619.
$script:GhPlatformSegments = @(
    'issues', 'wiki', 'pulls', 'pull', 'releases',
    'tree', 'blob', 'labels', 'milestones',
    'commits', 'commit', 'discussions'
)

function Test-InternalLinks {
    # Bash twin mirror: validate.sh:440-446 has an explicit
    # `command -v git` guard that emits "FAIL git unavailable; cannot
    # enumerate tracked markdown files" + exit 1. Cross-model confirmation
    # M-2 caught the PS port silently throwing under StrictMode if `git` is
    # absent. Add the guard so the operator-facing FAIL is identical.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine('FAIL git unavailable; cannot enumerate tracked markdown files')
        exit 1
    }

    Push-Location $repo
    try {
        $isGit = $true
        $null = & git rev-parse --git-dir 2>$null
        if ($LASTEXITCODE -ne 0) { $isGit = $false }
        if (-not $isGit) {
            Pass-Line "PASS internal markdown links (skipped — not a git checkout)"
            return
        }
        # Use git ls-files '*.md' to enumerate tracked markdown — matches the
        # bash twin's `git -C "$repo_root" ls-files '*.md'` so dotfile
        # sentinels (e.g. .test-*.md) are included. Bash globs would skip
        # dotfiles per [[feedback_bash_globs_skip_dotfiles]].
        $tracked = @(& git ls-files '*.md')
    } finally {
        Pop-Location
    }

    $fail = $false
    foreach ($rel in $tracked) {
        # Skip vendored snapshots
        if ($rel -like 'harnesses/*/vendored/*') { continue }

        $abs = Join-Path $repo $rel
        if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }

        $lines    = [System.IO.File]::ReadAllLines($abs)
        $fileDir  = Split-Path -Parent $rel
        # Split-Path -Parent on a repo-root file returns ''; bash dirname
        # returns '.'. Both resolve the same way via Join-Path-conditional.

        # Fence-state-machine. Mirrors validate.sh awk grammar:
        #   open shape:  0-3 leading spaces, then 3+ same-char fence (` or ~)
        #   close shape: open-shape + only-fence-chars + optional whitespace
        # Homogeneous-fence + length-aware: count consecutive same-char
        # chars after the open match; close requires same char + length >=
        # opening (4-backtick open NOT closed by a 3-backtick line).
        $inFence   = $false
        $fenceChar = ''
        $fenceLen  = 0

        foreach ($line in $lines) {
            if (-not $inFence) {
                # Try opening: 0-3 leading spaces + 3+ backticks OR 3+ tildes
                if ($line -match '^ {0,3}(`{3,}|~{3,})') {
                    $stripped = $line -replace '^ {0,3}', ''
                    $c = $stripped.Substring(0, 1)
                    $n = 0
                    while ($n -lt $stripped.Length -and $stripped[$n] -eq $c[0]) {
                        $n++
                    }
                    $inFence   = $true
                    $fenceChar = $c
                    $fenceLen  = $n
                    continue
                }

                # Not opening — strip inline-code spans longest-first, then
                # extract every [text](target) match.
                $clean = $line
                $clean = $clean -replace '```[^`]+```', ''
                $clean = $clean -replace '``[^`]+``',   ''
                $clean = $clean -replace '`[^`]+`',     ''

                $matchesFound = [regex]::Matches($clean, '\]\(([^)]+)\)')
                foreach ($m in $matchesFound) {
                    $rawTarget = $m.Groups[1].Value

                    # Strip in bash-twin order: `#frag` → `?query` →
                    # ` "title"` → ` 'title'`. The order matters when
                    # delimiters appear in earlier-strip output (e.g.
                    # `path?q=foo#bar` strips `#` first then `?`).
                    $target = $rawTarget
                    $hashIdx = $target.IndexOf('#')
                    if ($hashIdx -ge 0) { $target = $target.Substring(0, $hashIdx) }
                    $qIdx = $target.IndexOf('?')
                    if ($qIdx -ge 0) { $target = $target.Substring(0, $qIdx) }
                    $dqIdx = $target.IndexOf(' "')
                    if ($dqIdx -ge 0) { $target = $target.Substring(0, $dqIdx) }
                    $sqIdx = $target.IndexOf(" '")
                    if ($sqIdx -ge 0) { $target = $target.Substring(0, $sqIdx) }
                    if (-not $target) { continue }

                    # External schemes + absolute filesystem paths. Matches
                    # bash twin's case at validate.sh:606 — `mailto:*` is
                    # colon-only (no `//`), unlike http(s)/ftp/file which
                    # require `://`. `//*` is protocol-relative; `/*` is
                    # absolute filesystem path. Both are caught by
                    # StartsWith('/'). Bash POSIX `case` is case-sensitive
                    # so we use `-cmatch` (NOT `-match` which is PS default
                    # case-insensitive) for byte-parity with the bash twin.
                    if ($target -cmatch '^(https?://|ftp://|file://|mailto:)' -or
                        $target.StartsWith('/', [StringComparison]::Ordinal)) {
                        continue
                    }

                    # <TEAM>-105 skip-list: bare + /sub forms for each known
                    # GitHub-platform segment. NOT prefix-match — `issues-old`
                    # must still fall through to local resolution. Use `-ceq`
                    # (case-sensitive) + `Ordinal` StartsWith so `../../ISSUES`
                    # falls through to local resolution as it would under
                    # bash POSIX `case`.
                    $skipT105 = $false
                    foreach ($seg in $script:GhPlatformSegments) {
                        if ($target -ceq "../../$seg" -or
                            $target.StartsWith("../../$seg/", [StringComparison]::Ordinal)) {
                            $skipT105 = $true
                            break
                        }
                    }
                    if ($skipT105) { continue }

                    # Resolve relative to the source file's directory
                    if ($fileDir) {
                        $absTarget = Join-Path $repo $fileDir $target
                    } else {
                        $absTarget = Join-Path $repo $target
                    }
                    if (-not (Test-Path -LiteralPath $absTarget)) {
                        [Console]::Error.WriteLine("FAIL broken internal link in $rel -> $target")
                        $fail = $true
                    }
                }
            } else {
                # Inside fence — only a homogeneous-char fence line of length
                # >= opening, with optional trailing space/tab, can close.
                # Use `[ \t]*$` (not `\s*$`) to mirror the bash twin's awk
                # grammar at validate.sh:540, which only accepts space + tab
                # as trailing whitespace. PS `\s` is broader (includes \v,
                # \f, \r, NBSP) and would be a parity break.
                if ($line -match '^ {0,3}(`{3,}|~{3,})[ \t]*$') {
                    $stripped = $line -replace '^ {0,3}', ''
                    $stripped = $stripped -replace '[ \t]+$', ''
                    $cc = $stripped.Substring(0, 1)
                    $nn = 0
                    while ($nn -lt $stripped.Length -and $stripped[$nn] -eq $cc[0]) {
                        $nn++
                    }
                    # Confirm homogeneous (no trailing other-fence-char run)
                    if ($nn -eq $stripped.Length -and
                        $cc -eq $fenceChar -and
                        $nn -ge $fenceLen) {
                        $inFence   = $false
                        $fenceChar = ''
                        $fenceLen  = 0
                    }
                }
                # All in-fence lines (including the closer) skip link extraction
                continue
            }
        }
    }

    if ($fail) { exit 1 }
    Pass-Line "PASS internal markdown links resolve"
}
Test-InternalLinks

Write-Host ""
Pass-Line "PASS agentic-os-template validation complete"
exit 0
