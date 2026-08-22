#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/vault-scaffolding-retrieval.test.ps1 — Windows-native twin of
# tests/vault-scaffolding-retrieval.test.sh.
#
# The scaffold's retrieval baseline (bin/vault-search.sh + bin/retrieval-evals.sh
# + 00-System/Retrieval Fixtures.md) and its generated session index
# (bin/generate-session-index.js), plus the two audit checks that gate them.
#
# Mirrors the bash twin, with one documented divergence: the retrieval eval arm
# (T1) is a bash script whose only backend is ripgrep, so it runs here ONLY when
# both `bash` and `rg` are on PATH and SKIPs otherwise — same convention the
# suite uses elsewhere for a tool-dependent lane. Every node-backed assertion
# (session index empty state, drift, the audit's two new checks, and the
# not-applicable outcomes) runs natively on Windows with no skip.
#
# Runs against TMP COPIES of the scaffolding — never mutates the live repo tree.
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$VSR_SCAFFOLD = Join-Path $env:REPO_ROOT 'obsidian' 'vault-scaffolding'
$VSR_EVALS_REL = 'bin/retrieval-evals.sh'
$VSR_SEARCH_REL = 'bin/vault-search.sh'
$VSR_SESSION_REL = Join-Path 'bin' 'generate-session-index.js'
$VSR_AUDIT_REL = Join-Path 'bin' 'memory-vault-audit.js'
$VSR_FIXTURES_REL = Join-Path '00-System' 'Retrieval Fixtures.md'
$VSR_VIEW_REL = Join-Path '90-Indexes' 'Session Index.md'

function New-VsrCopy {
    $parent = Join-Path ([System.IO.Path]::GetTempPath()) ("vsr-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $vault = Join-Path $parent 'vault'
    Copy-Item -LiteralPath $VSR_SCAFFOLD -Destination $vault -Recurse
    [pscustomobject]@{ Parent = $parent; Vault = $vault }
}

$vsrNode = Get-Command node -ErrorAction SilentlyContinue
if (-not $vsrNode) {
    _Skip 'vault-scaffolding-retrieval.test: suite' 'node not installed'
}
elseif (-not (Test-Path -LiteralPath (Join-Path $VSR_SCAFFOLD $VSR_SESSION_REL))) {
    _Fail 'vault-scaffolding-retrieval.test: session index generator present' "missing: $VSR_SCAFFOLD/$VSR_SESSION_REL"
}
else {
    $c1 = New-VsrCopy
    $vsrAudit = Join-Path $c1.Vault $VSR_AUDIT_REL
    $vsrSession = Join-Path $c1.Vault $VSR_SESSION_REL

    # --- T1: the shipped fixture set is green on the pristine scaffold.
    # bash + ripgrep lane; SKIP rather than pass when either is absent.
    $vsrBash = Get-Command bash -ErrorAction SilentlyContinue
    $vsrRg = Get-Command rg -ErrorAction SilentlyContinue
    if (-not $vsrBash -or -not $vsrRg) {
        _Skip 'vault-scaffolding-retrieval.test: retrieval evals' 'bash and/or ripgrep (rg) not installed'
    }
    else {
        # Forward-slash paths: the scripts resolve their own vault root from
        # BASH_SOURCE, so bash must be handed a path it can open.
        $vsrEvalsPath = ($c1.Vault -replace '\\', '/') + '/' + $VSR_EVALS_REL
        $vsrSearchPath = ($c1.Vault -replace '\\', '/') + '/' + $VSR_SEARCH_REL
        Assert-Exit 'vault-scaffolding-retrieval.test: shipped retrieval fixtures pass on the pristine scaffold' 0 -- `
            bash $vsrEvalsPath
        $vsrEvalsOut = (& bash $vsrEvalsPath 2>&1) -join "`n"
        Assert-Contains 'vault-scaffolding-retrieval.test: the eval run reports a non-zero fixture denominator' `
            $vsrEvalsOut '0 failed ('
        Assert-Contains 'vault-scaffolding-retrieval.test: the eval run exercises negative controls' `
            $vsrEvalsOut '[negative-control] correctly found nothing'
        $vsrProbe = (& bash $vsrSearchPath 'kubernetes ingress controller' --scope durable --paths-only 2>&1) -join "`n"
        Assert-NotContains 'vault-scaffolding-retrieval.test: the baseline itself excludes the fixture note from results' `
            $vsrProbe 'Retrieval Fixtures.md'

        # --- T1b: --context actually renders context lines (dash records pass
        # the display filter; marked `L<n>|` to distinguish from `L<n>:` matches).
        $vsrCtxOut = (& bash $vsrSearchPath 'source of truth' --context 1 2>&1) -join "`n"
        if ($vsrCtxOut -match 'L[0-9]+\|') {
            _Pass 'vault-scaffolding-retrieval.test: --context emits dash-record context lines'
        } else {
            _Fail 'vault-scaffolding-retrieval.test: --context emits dash-record context lines' 'no L<n>| line in output'
        }

        # --- T1c: --paths-only keeps stdout machine-clean on an empty result;
        # the no-match notice goes to stderr, the exit code carries the result.
        $vsrPoOut = (& bash $vsrSearchPath 'zzzz-no-such-concept-in-this-vault' --paths-only 2>$null) -join "`n"
        $vsrPoRc = $LASTEXITCODE
        Assert-Eq 'vault-scaffolding-retrieval.test: empty --paths-only exits 1' 1 $vsrPoRc
        Assert-Eq 'vault-scaffolding-retrieval.test: empty --paths-only emits nothing on stdout' '' $vsrPoOut
    }

    # --- T2: session index --check is green on the pristine, EMPTY scaffold ---
    Assert-Exit 'vault-scaffolding-retrieval.test: session index --check passes on the pristine (empty) scaffold' 0 -- `
        node $vsrSession --check

    # --- T3: the empty view is TRUTHFUL — states the zero, prints no table ---
    $vsrView = Get-Content -LiteralPath (Join-Path $c1.Vault $VSR_VIEW_REL) -Raw
    Assert-Contains 'vault-scaffolding-retrieval.test: the empty session index states zero coverage' `
        $vsrView 'Session logs: **0**'
    Assert-Contains 'vault-scaffolding-retrieval.test: the empty session index says plainly that no logs exist yet' `
        $vsrView 'No session logs exist yet'
    Assert-NotContains 'vault-scaffolding-retrieval.test: the empty session index omits the sessions table' `
        $vsrView '| Date | Harness | Machine |'

    # --- T4: the audit is green on the pristine scaffold, both new checks reporting ---
    $vsrAuditOut = (& node $vsrAudit 2>&1) -join "`n"
    $vsrAuditRc = $LASTEXITCODE
    Assert-Eq 'vault-scaffolding-retrieval.test: the audit is green on the pristine scaffold' 0 $vsrAuditRc
    Assert-Contains 'vault-scaffolding-retrieval.test: the audit reports the retrieval-pointer check' `
        $vsrAuditOut 'PASS retrieval fixture pointers resolve'
    Assert-Contains 'vault-scaffolding-retrieval.test: the audit reports the session-index view check' `
        $vsrAuditOut 'PASS session index view matches regeneration'

    Remove-Item -LiteralPath $c1.Parent -Recurse -Force -ErrorAction SilentlyContinue

    # --- T5: positive control — a broken fixture pointer FAILs the audit ---
    $c5 = New-VsrCopy
    $vsrFix5 = Join-Path $c5.Vault $VSR_FIXTURES_REL
    $vsrRow = '| R1 | promotion test | durable | 4 | `00-System/__no-such-note__.md` | policy-lookup |'
    (Get-Content -LiteralPath $vsrFix5) |
        ForEach-Object { if ($_ -like '| R1 |*') { $vsrRow } else { $_ } } |
        Set-Content -LiteralPath $vsrFix5
    $vsrBpOut = (& node (Join-Path $c5.Vault $VSR_AUDIT_REL) 2>&1) -join "`n"
    $vsrBpRc = $LASTEXITCODE
    Assert-Eq 'vault-scaffolding-retrieval.test: a broken fixture pointer FAILs the audit (non-zero exit)' 1 $vsrBpRc
    Assert-Contains 'vault-scaffolding-retrieval.test: a broken fixture pointer surfaces as a FAIL line (not WARN)' `
        $vsrBpOut 'FAIL retrieval fixture broken pointer: R1 -> 00-System/__no-such-note__.md does not exist'
    Remove-Item -LiteralPath $c5.Parent -Recurse -Force -ErrorAction SilentlyContinue

    # --- T6: a fixture set with no negative controls FAILs ---
    $c6 = New-VsrCopy
    $vsrFix6 = Join-Path $c6.Vault $VSR_FIXTURES_REL
    (Get-Content -LiteralPath $vsrFix6) |
        Where-Object { $_ -notmatch '^\| N[0-9]+ \|' } |
        Set-Content -LiteralPath $vsrFix6
    $vsrNcOut = (& node (Join-Path $c6.Vault $VSR_AUDIT_REL) 2>&1) -join "`n"
    $vsrNcRc = $LASTEXITCODE
    Assert-Eq 'vault-scaffolding-retrieval.test: a fixture set with no negative controls FAILs the audit' 1 $vsrNcRc
    Assert-Contains 'vault-scaffolding-retrieval.test: the missing-negative-controls FAIL names the reason' `
        $vsrNcOut 'FAIL retrieval fixtures: no negative controls'
    Remove-Item -LiteralPath $c6.Parent -Recurse -Force -ErrorAction SilentlyContinue

    # --- T7: a hand-edited session index FAILs the audit as drift ---
    $c7 = New-VsrCopy
    Add-Content -LiteralPath (Join-Path $c7.Vault $VSR_VIEW_REL) -Value 'HAND EDIT'
    Assert-Exit 'vault-scaffolding-retrieval.test: a hand-edited session index fails generator --check' 1 -- `
        node (Join-Path $c7.Vault $VSR_SESSION_REL) --check
    $vsrDrOut = (& node (Join-Path $c7.Vault $VSR_AUDIT_REL) 2>&1) -join "`n"
    $vsrDrRc = $LASTEXITCODE
    Assert-Eq 'vault-scaffolding-retrieval.test: a hand-edited session index FAILs the audit (non-zero exit)' 1 $vsrDrRc
    Assert-Contains 'vault-scaffolding-retrieval.test: session index drift surfaces as a FAIL line' `
        $vsrDrOut 'FAIL session index drift:'
    Remove-Item -LiteralPath $c7.Parent -Recurse -Force -ErrorAction SilentlyContinue

    # --- T8: NOT-APPLICABLE, not silence and not a FAIL ---
    $c8 = New-VsrCopy
    Remove-Item -LiteralPath (Join-Path $c8.Vault $VSR_SESSION_REL) -Force
    $vsrNaOut = (& node (Join-Path $c8.Vault $VSR_AUDIT_REL) 2>&1) -join "`n"
    $vsrNaRc = $LASTEXITCODE
    Assert-Eq 'vault-scaffolding-retrieval.test: an absent session index generator does not FAIL the audit' 0 $vsrNaRc
    Assert-Contains 'vault-scaffolding-retrieval.test: an absent session index generator reports a visible N/A line' `
        $vsrNaOut 'N/A  session index generator absent'
    Assert-Contains 'vault-scaffolding-retrieval.test: the audit summary counts the n/a outcome' `
        $vsrNaOut ' n/a, '
    Remove-Item -LiteralPath $c8.Parent -Recurse -Force -ErrorAction SilentlyContinue

    # --- T9: same for the fixture note. Removing it also breaks the wikilinks
    # that point at it, so the exit code is not asserted here (that FAIL belongs
    # to checkWikilinks); what MUST hold is the N/A line instead of a silent pass.
    $c9 = New-VsrCopy
    Remove-Item -LiteralPath (Join-Path $c9.Vault $VSR_FIXTURES_REL) -Force
    $vsrNa2Out = (& node (Join-Path $c9.Vault $VSR_AUDIT_REL) 2>&1) -join "`n"
    Assert-Contains 'vault-scaffolding-retrieval.test: absent retrieval fixtures report a visible N/A line' `
        $vsrNa2Out 'N/A  retrieval fixtures absent'
    Assert-NotContains 'vault-scaffolding-retrieval.test: absent retrieval fixtures do not report a pointer PASS' `
        $vsrNa2Out 'PASS retrieval fixture pointers resolve'
    Remove-Item -LiteralPath $c9.Parent -Recurse -Force -ErrorAction SilentlyContinue
}
