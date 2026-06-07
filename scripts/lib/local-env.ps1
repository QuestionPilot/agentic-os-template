#Requires -Version 7
# scripts/lib/local-env.ps1 — shared PS parser for local.env.
#
# <TEAM>-115 (absorbs <TEAM>-108) — native PS equivalent of bash
# `set -a; . local.env; set +a`. Both `scripts/bootstrap.ps1` and
# `scripts/install.ps1` dot-source this file and call `Import-LocalEnv -Path`
# instead of carrying their own copies.
#
# Supported subset (matches what tests/lib.sh `make_local_env` writes via
# `printf '%q'` AND what bash `set -a; . local.env; set +a` would consume):
#
#   KEY=VALUE              — plain
#   KEY="VALUE"            — double-quoted
#   KEY='VALUE'            — single-quoted
#   KEY=foo\ bar           — backslash-escape (bash `%q` shape for values
#                            containing shell-metacharacters like SPACE).
#                            bash sourcing strips the `\<x>` and yields `foo bar`;
#                            this parser does the same so paths-with-spaces
#                            written by `printf %q` round-trip correctly.
#   # leading comment      — skipped
#   <blank>                — skipped
#   export KEY=VALUE       — `export` prefix stripped (bash habit)
#   KEY=                   — explicitly-empty value (preserved)
#
# UNSUPPORTED (documented):
#   - bash ANSI-C `KEY=$'...'` form (escape sequences left literal)
#   - backslash-newline continuation
#   - inline comments after value (bash sourcing also doesn't strip these
#     unless the `# ` falls outside a quoted segment)
#
# Behavior on malformed lines: prints a WARNING to stderr and continues.
# Behavior on missing file: throws (Die handler in the caller decides).
#
# Sister memories: [[reference_powershell_var_colon]] ($name: parser trap;
# this file uses ${name}: shape throughout), [[feedback_powershell_set_content_crlf]]
# (NOT a writer, so no encoding concern; just a parser).

function Import-LocalEnv {
    <#
    .SYNOPSIS
        Parse a local.env file and push each KEY=VALUE into the current
        process environment.

    .DESCRIPTION
        Native PS equivalent of bash `set -a; . local.env; set +a`. See file
        header for supported subset + unsupported forms.

    .PARAMETER Path
        Absolute or relative path to the local.env file.

    .EXAMPLE
        . "$PSScriptRoot/lib/local-env.ps1"
        Import-LocalEnv -Path "$repoRoot/local.env"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Import-LocalEnv: local.env not found at $Path"
    }

    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trim = $line.Trim()
        if ($trim.Length -eq 0) { continue }
        if ($trim.StartsWith('#', [StringComparison]::Ordinal)) { continue }

        # Strip `export ` prefix if present (bash habit).
        if ($trim -match '^export\s+(.+)$') { $trim = $matches[1] }

        if ($trim -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            [Console]::Error.WriteLine("Import-LocalEnv: WARNING line not in KEY=VALUE form, skipping: $line")
            continue
        }

        $key = $matches[1]
        $val = $matches[2]

        # Quoted-value branch: strip surrounding double- or single-quotes
        # if balanced. Quoted values pass through to bash as-is (bash drops
        # the quotes when sourcing).
        $stripped = $false
        if ($val.Length -ge 2) {
            $first = $val[0]
            $last  = $val[$val.Length - 1]
            if (($first -ceq '"' -and $last -ceq '"') -or
                ($first -ceq "'" -and $last -ceq "'")) {
                $val = $val.Substring(1, $val.Length - 2)
                $stripped = $true
            }
        }

        # Unquoted-value branch: bash `%q` shape uses backslash-escape for
        # shell-metacharacters (space, parens, &, |, ;, etc.). Bash sourcing
        # collapses each `\<x>` to `<x>`. Mirror that here for parity.
        # The transformation is conservative: only operates when the value
        # was NOT quote-stripped above (preserve quoted-content verbatim).
        # Codex F-1 (<TEAM>-115 confirmation review): bash `make_local_env`
        # writes paths-with-spaces as `KEY=/path/with\ spaces/...` via
        # `printf '%q'`; without this transform the PS parser preserves the
        # backslash, breaking any CLAUDE_CONFIG_DIR / OBSIDIAN_VAULT_PATH
        # that contains a space (e.g. `~/path with spaces/...`).
        if (-not $stripped -and $val.Contains([char]'\')) {
            # Regex: backslash followed by ANY single character → that
            # character. Loop-safe — .NET regex consumes one match at a
            # time so `\\` (two-backslash) becomes `\` (one).
            $val = [System.Text.RegularExpressions.Regex]::Replace(
                $val, '\\(.)', '$1')
        }

        Set-Item -Path "env:${key}" -Value $val
    }
}
