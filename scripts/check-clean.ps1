#!/usr/bin/env pwsh
# scripts/check-clean.ps1 — public-repo cleanliness guard (PowerShell twin of
# check-clean.sh).
#
# The permanent enforcement that keeps a public framework tree free of operator
# identity and private tracker issue IDs. It replaces the publish-time scrubber
# model with a fail-closed gate: the build FAILS when a leak is present, so the
# canonical tree is always clean.
#
# Scans a target tree (default: the current directory) and FAILS (exit 1) when
# it finds any of:
#   - tracker issue IDs        QUE-<digits>
#   - macOS / Linux home paths with a real username segment under the home root
#   - Windows home paths with a real username segment under the profile root
#   - email addresses          (real shape; documentation + noreply domains pass)
#   - operator identity tokens listed in $OPERATOR_PII_TOKENS (component-split
#                              aware; case-insensitive)
#   - commit-metadata identity leaks (opt-in, git mode): with
#                              $COMMIT_IDENTITY_ALLOWLIST set, every ahead-of-default
#                              branch commit must carry an allowlisted author AND
#                              committer — content scans cannot see commit metadata
#
# Enumeration (hardened): in a git work tree the scan walks `git ls-files` and
# inspects each TRACKED file. This closes four bypasses a recursive,
# basename-excluded filesystem scan left open:
#   - an arbitrarily-named committed copy of this guard (e.g. docs/check-clean.ps1)
#     is no longer skipped — self-exclusion is by EXACT repo-relative path;
#   - a committed gitignored-by-name file (local.env / .mcp.json) is caught;
#   - tracked content is read as BYTES with NUL stripped, so a UTF-16 / binary
#     file carrying a leak is de-binarised and scanned, and an UNREADABLE tracked
#     file FAILS closed rather than being swallowed by a catch{};
#   - a tracked symlink is inspected by its TARGET text, not by following it.
# A non-git target (synthetic test fixtures) falls back to a filesystem walk.
#
# A bounded multi-line pass rejoins hard-wrapped lines so a high-signal token
# split across a newline (QUE-\n123, alice@\ncorp.example) is still caught.
#
# The structural patterns need no operator identity, so they run unchanged in
# CI. Personal name / handle / hostname come from $OPERATOR_PII_TOKENS (populated
# in the gitignored local.env), so the shipped guard carries ZERO operator PII.
#
# Tested against SYNTHETIC dirty/clean fixtures, never a live framework tree
# (which carries issue IDs by design). See tests/check-clean.test.ps1.

[CmdletBinding()]
param([string]$Target = '.')

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    [Console]::Error.WriteLine("FAIL check-clean: target is not a directory: $Target")
    exit 2
}
$Target = (Resolve-Path -LiteralPath $Target).Path

# Pick up operator tokens from local.env in the target tree when not already
# exported (a local pre-push convenience). Absent in CI, so this no-ops there.
$tokens = $env:OPERATOR_PII_TOKENS
if ([string]::IsNullOrEmpty($tokens)) {
    $lenv = Join-Path $Target 'local.env'
    if (Test-Path -LiteralPath $lenv -PathType Leaf) {
        $line = Get-Content -LiteralPath $lenv |
            Where-Object { $_ -match '^\s*(export\s+)?OPERATOR_PII_TOKENS=' } |
            Select-Object -First 1
        if ($line) {
            # Strip CR (CRLF local.env), drop an unquoted trailing ` # comment`,
            # then peel one layer of surrounding quotes.
            $val = ($line -replace '^[^=]*=', '').TrimEnd("`r")
            $val = ($val -replace '\s+#.*$', '').Trim()
            $tokens = $val.Trim('"').Trim("'")
        }
    }
}

$script:fail = 0

# --- Patterns --------------------------------------------------------------
$issueRe = 'QUE-[0-9]+'
# Home paths carrying a REAL username segment (angle-bracket or $-variable
# placeholders do not match). The Windows arm accepts ONE OR MORE backslashes, so
# simple, JSON-escaped, and nested source-of-JSON profile paths (one, two, or
# four backslashes) are all caught.
$homeRe = '/(Users|home)/[A-Za-z0-9._][A-Za-z0-9._-]*|[A-Za-z]:\\+Users\\+[A-Za-z0-9._-]+'
$emailRe = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
$emailAllowed = @('example.com', 'example.org', 'example.net', 'users.noreply.github.com')

# Pre-split the operator token list once: split on commas AND whitespace, so a
# configured "Jane Doe" catches a stray "Jane" or "Doe" on its own; sub-tokens
# shorter than 3 chars are skipped. Empty in the CI case.
$script:tokenList = @()
if (-not [string]::IsNullOrEmpty($tokens)) {
    foreach ($t in ($tokens -split '[,\s]+')) {
        $tk = $t.Trim()
        if ($tk.Length -ge 3) { $script:tokenList += $tk }
    }
}

# --- Exclusions ------------------------------------------------------------
# Self-reference is by EXACT repo-relative path (NOT basename, so a same-named
# copy elsewhere is still scanned). Machine-local files are content-excluded ONLY
# in git mode (the gitignored copy is not enumerated; a tracked copy is caught
# separately); in a non-git tree a present local.env / .mcp.json IS scanned. VCS
# / harness state dirs are pruned. All comparisons are case-SENSITIVE to match
# the bash twin's globs (a case-varied dir name is a real path, not an exclusion).
function Test-ExcludedPath([string]$rel) {
    if ($rel -ceq 'scripts/check-clean.sh' -or $rel -ceq 'scripts/check-clean.ps1' -or
        $rel -ceq 'tests/check-clean.test.sh' -or $rel -ceq 'tests/check-clean.test.ps1') { return $true }
    if ($script:isGit -and ($rel -ceq 'local.env' -or $rel -clike '*/local.env' -or
        $rel -ceq '.mcp.json' -or $rel -clike '*/.mcp.json')) { return $true }
    foreach ($seg in ($rel -split '/')) {
        if ($seg -cin @('.git', '.claude', '.codex', '.agents', 'cross-model-out')) { return $true }
    }
    return $false
}

# --- Content acquisition ---------------------------------------------------
# Get-CleanContent <abspath> — return the file's text with NUL bytes stripped (so
# a UTF-16 / binary blob is de-binarised). A symlink yields its TARGET text with
# separators normalised to '/'. Reads bytes via ReadAllBytes, which THROWS on an
# unreadable file — the caller treats that as fail-closed rather than swallowing it.
function Get-CleanContent([string]$abs) {
    $item = Get-Item -LiteralPath $abs -Force
    if ($item.LinkType -eq 'SymbolicLink') {
        $t = $item.Target
        if ($t -is [array]) { $t = ($t -join "`n") }
        return ([string]$t).Replace('\', '/')
    }
    $bytes = [System.IO.File]::ReadAllBytes($abs)
    $noNul = [byte[]]($bytes -ne 0)
    return [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($noNul)
}

# Hard-Unwrap — trim each line's leading/trailing horizontal whitespace (incl.
# CR) and concatenate with no separator, so a token split across a wrap becomes
# contiguous. Bounded high-signal pass for the adversarial split-leak model.
function Hard-Unwrap([string]$text) {
    (($text -split "`n") | ForEach-Object { ($_ -replace '^[ \t\r]+', '') -replace '[ \t\r]+$', '' }) -join ''
}

# --- Per-file scanners -----------------------------------------------------
# Scan-Class — line-aware structural scan first; only when clean is the bounded
# multi-line (hard-unwrapped) pass tried, so a single-line leak is not double-reported.
function Scan-Class([string]$rel, [string]$content, [string]$joined, [string]$label, [string]$pattern) {
    $re = [System.Text.RegularExpressions.Regex]::new($pattern)
    $n = 0
    $hit = $false
    foreach ($l in ($content -split "`n")) {
        $n++
        if ($re.IsMatch($l)) {
            if (-not $hit) { [Console]::Error.WriteLine("FAIL $label"); $hit = $true }
            [Console]::Error.WriteLine("  ${rel}:${n}:$l")
        }
    }
    if ($hit) { $script:fail = 1; return }
    if ($re.IsMatch($joined)) {
        [Console]::Error.WriteLine("FAIL $label (multi-line)")
        [Console]::Error.WriteLine("  ${rel}: $joined")
        $script:fail = 1
    }
}

# Scan-EmailPass — every address's FULL domain must be EXACTLY an allowed
# documentation/noreply domain (substring allow-listing would let
# bot@users.noreply.github.com.evil.net slip). Returns $true if a leak was reported.
function Scan-EmailPass([string]$rel, [string]$text, [string]$suffix) {
    $leaks = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($text, $emailRe)) {
        $addr = $m.Value
        $dom = $addr.Substring($addr.LastIndexOf('@') + 1)
        if ($emailAllowed -notcontains $dom) { [void]$leaks.Add($addr) }
    }
    if ($leaks.Count -gt 0) {
        [Console]::Error.WriteLine("FAIL email address found$suffix")
        ($leaks | Sort-Object -Unique | Select-Object -First 50) |
            ForEach-Object { [Console]::Error.WriteLine("  ${rel}:$_") }
        $script:fail = 1
        return $true
    }
    return $false
}

function Scan-EmailClass([string]$rel, [string]$content, [string]$joined) {
    if (Scan-EmailPass $rel $content '') { return }
    [void](Scan-EmailPass $rel $joined ' (multi-line)')
}

# Scan-TokenClass — case-insensitive FIXED-string scan for an operator identity
# token (a name may legitimately contain regex metacharacters). Line-aware first;
# only when clean is the bounded multi-line (hard-unwrapped) pass tried, so a
# token split across a wrap is caught too.
function Scan-TokenClass([string]$rel, [string]$content, [string]$joined, [string]$tok) {
    $re = [System.Text.RegularExpressions.Regex]::new(
        [regex]::Escape($tok), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $n = 0
    $hit = $false
    foreach ($l in ($content -split "`n")) {
        $n++
        if ($re.IsMatch($l)) {
            if (-not $hit) { [Console]::Error.WriteLine("FAIL operator identity token found (`"$tok`")"); $hit = $true }
            [Console]::Error.WriteLine("  ${rel}:${n}:$l")
        }
    }
    if ($hit) { $script:fail = 1; return }
    if ($re.IsMatch($joined)) {
        [Console]::Error.WriteLine("FAIL operator identity token found (`"$tok`") (multi-line)")
        [Console]::Error.WriteLine("  ${rel}: $joined")
        $script:fail = 1
    }
}

function Scan-FileContent([string]$rel, [string]$content) {
    $joined = Hard-Unwrap $content
    Scan-Class $rel $content $joined 'tracker issue ID found (QUE-<n>)' $issueRe
    Scan-Class $rel $content $joined 'machine-specific home path found' $homeRe
    Scan-EmailClass $rel $content $joined
    foreach ($tok in $script:tokenList) { Scan-TokenClass $rel $content $joined $tok }
}

# --- Enumerate + scan ------------------------------------------------------
# Prefer git ls-files (tracked set only); fall back to a filesystem walk for
# non-git fixtures.
$script:isGit = $false
if (Get-Command git -ErrorAction SilentlyContinue) {
    try { $script:isGit = ((& git -C $Target rev-parse --is-inside-work-tree 2>$null) -eq 'true') } catch {}
}

if ($script:isGit) {
    # NUL-delimited enumeration with the index MODE (-s). git -z emits raw paths
    # (no C-quoting), so a tracked file whose name carries a newline / quote /
    # non-ASCII byte is read by its true path. A symlink is mode 120000 on every
    # platform (index-canonical; core.symlinks only affects checkout), so it is
    # the authoritative symlink signal: it is scanned from its canonical git BLOB
    # (the target path) with separators normalised to '/', not from the
    # OS-resolved worktree link (Windows may store '\\' or check it out as plain
    # text). Regular files are read from the worktree (bytes, NUL-stripped).
    $raw = (& git -C $Target ls-files -s -z 2>$null)
    $entries = @()
    if ($null -ne $raw) { $entries = (($raw -join "`0") -split "`0") | Where-Object { $_ -ne '' } }
    foreach ($entry in $entries) {
        $mode = ($entry -split ' ', 2)[0]
        $rel = ($entry -split "`t", 2)[1]
        if ([string]::IsNullOrEmpty($rel)) { continue }
        if (Test-ExcludedPath $rel) { continue }
        if ($mode -eq '120000') {
            $content = ((& git -C $Target show ":$rel" 2>$null) -join "`n").Replace('\', '/')
        } else {
            $abs = Join-Path $Target $rel
            try { $content = Get-CleanContent $abs }
            catch {
                [Console]::Error.WriteLine("FAIL unreadable tracked file (fail-closed): $rel")
                $script:fail = 1
                continue
            }
        }
        Scan-FileContent $rel $content
    }
} else {
    Get-ChildItem -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer } |
        ForEach-Object {
            $f = $_
            $rel = $f.FullName.Substring($Target.Length).TrimStart([char]'/', [char]'\').Replace([char]'\', [char]'/')
            if (Test-ExcludedPath $rel) { return }
            try { $content = Get-CleanContent $f.FullName }
            catch {
                [Console]::Error.WriteLine("FAIL unreadable file (fail-closed): $rel")
                $script:fail = 1
                return
            }
            Scan-FileContent $rel $content
        }
}

# A committed local.env / .mcp.json is itself a leak — they hold machine-local
# PII. They are excluded from the CONTENT scans (the operator's gitignored copies
# legitimately hold local data), so catch a TRACKED copy explicitly. No-ops on a
# non-git target (synthetic fixtures).
if ($script:isGit) {
    $trackedLocal = & git -C $Target ls-files -- 'local.env' '*/local.env' '.mcp.json' '*/.mcp.json' 2>$null
    if ($trackedLocal) {
        [Console]::Error.WriteLine('FAIL machine-local file is tracked (must be gitignored)')
        $trackedLocal | ForEach-Object { [Console]::Error.WriteLine($_) }
        $script:fail = 1
    }
}

# --- Commit-metadata identity check -----------------------------------------
# Twin of the bash commit-metadata check. The content scans above cannot see git
# COMMIT METADATA: author/committer name+email are their own leak vector — a
# clone with no repo-local identity derives the operator's personal name and
# machine hostname into PUBLIC history on a plain `git commit`. When
# COMMIT_IDENTITY_ALLOWLIST is set (env, or read from the target's gitignored
# local.env — the same opt-in pattern as OPERATOR_PII_TOKENS, so the shipped
# guard carries zero operator identity), every ahead-of-default branch commit
# must carry an allowlisted author AND committer (comma-separated exact
# `Name <email>` entries — an identity CONTAINING a comma cannot be expressed,
# a documented format limit that fails closed, never open). Unset => documented
# no-op; the PASS line reports which way it went so coverage is never
# overstated. Git mode only. Trust boundary: the base is the LOCAL view of the
# remote (refs/remotes/*) — the guard defends against accidents, not a hostile
# local environment (see the bash twin's section comment).
$identityNote = ''
if ($script:isGit) {
    $allowRaw = $env:COMMIT_IDENTITY_ALLOWLIST
    if ([string]::IsNullOrEmpty($allowRaw)) {
        $lenv = Join-Path $Target 'local.env'
        if (Test-Path -LiteralPath $lenv -PathType Leaf) {
            $line = Get-Content -LiteralPath $lenv |
                Where-Object { $_ -match '^\s*(export\s+)?COMMIT_IDENTITY_ALLOWLIST=' } |
                Select-Object -First 1
            if ($line) {
                $val = ($line -replace '^[^=]*=', '').TrimEnd("`r")
                $val = ($val -replace '\s+#.*$', '').Trim()
                $allowRaw = $val.Trim('"').Trim("'")
            }
        }
    }
    if ([string]::IsNullOrEmpty($allowRaw)) {
        $identityNote = '; commit-identity check skipped (COMMIT_IDENTITY_ALLOWLIST unset)'
    } else {
        & git -C $Target rev-parse --verify --quiet HEAD *> $null
        if ($LASTEXITCODE -ne 0) {
            # HEAD does not resolve. Benign ONLY for an unborn repo (zero
            # commits anywhere) — verify explicitly; any other git state FAILS
            # closed per the guard's erroring-scanner contract.
            $allTip = & git -C $Target rev-list -n 1 --all 2>$null
            if ($LASTEXITCODE -eq 0 -and [string]::IsNullOrEmpty(($allTip -join ''))) {
                $identityNote = '; commit-identity: no commits to check'
            } else {
                [Console]::Error.WriteLine('FAIL commit-identity: HEAD does not resolve but the repo is not empty (fail-closed)')
                $script:fail = 1
            }
        } else {
            # Parse the allowlist into exact identities. Set-but-empty-after-
            # parsing is a misconfiguration — fail closed, never skip silently.
            $allowed = @()
            foreach ($e in ($allowRaw -split ',')) {
                $id = $e.Trim()
                if ($id) { $allowed += $id }
            }
            if ($allowed.Count -eq 0) {
                [Console]::Error.WriteLine('FAIL commit-identity: COMMIT_IDENTITY_ALLOWLIST is set but parses to no entries (fail-closed)')
                $script:fail = 1
            } else {
                # Base = the published default branch; the range ahead of it is
                # exactly the commit set a push/PR would publish. FULL refnames
                # only: a bare `origin/main` resolves through refs/tags/ FIRST
                # (gitrevisions order), so a local tag named "origin/main" at
                # HEAD would silently empty the range — the full refs/remotes/
                # form cannot be shadowed. No resolvable base (a fixture repo
                # with no remote) => check every commit reachable from HEAD.
                $base = ''
                foreach ($ref in @('refs/remotes/origin/HEAD', 'refs/remotes/origin/main', 'refs/remotes/origin/master')) {
                    & git -C $Target rev-parse --verify --quiet $ref *> $null
                    if ($LASTEXITCODE -eq 0) { $base = $ref; break }
                }
                $range = if ($base) { "$base..HEAD" } else { 'HEAD' }
                $meta = & git -C $Target log --format='%h%x09%an <%ae>%x09%cn <%ce>' $range 2>$null
                if ($LASTEXITCODE -ne 0) {
                    [Console]::Error.WriteLine("FAIL commit-identity: git log failed over $range (fail-closed)")
                    $script:fail = 1
                } else {
                    $checked = 0
                    foreach ($row in @($meta)) {
                        if ([string]::IsNullOrEmpty($row)) { continue }
                        $parts = $row -split "`t"
                        if ($parts.Count -lt 3) {
                            # Malformed metadata row: fail CLOSED (the bash twin
                            # compares empty fields and fails) — never skip.
                            [Console]::Error.WriteLine("FAIL commit-identity: malformed git log row (fail-closed): $row")
                            $script:fail = 1
                            continue
                        }
                        $checked++
                        if ($allowed -cnotcontains $parts[1]) {
                            [Console]::Error.WriteLine("FAIL commit-identity: commit $($parts[0]) author not allowlisted: $($parts[1])")
                            $script:fail = 1
                        }
                        if ($allowed -cnotcontains $parts[2]) {
                            [Console]::Error.WriteLine("FAIL commit-identity: commit $($parts[0]) committer not allowlisted: $($parts[2])")
                            $script:fail = 1
                        }
                    }
                    $identityNote = "; $checked branch commit(s) identity-checked"
                }
            }
        }
    }
}

if ($script:fail -ne 0) {
    [Console]::Error.WriteLine("FAIL check-clean: leaks found in $Target")
    exit 1
}
Write-Output "PASS check-clean: $Target is clean (no issue IDs / home paths / emails / operator tokens)$identityNote"
exit 0
