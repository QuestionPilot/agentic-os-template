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

        # --- T1d: the eval runner normalizes Windows-shaped baseline output
        # (absolute root + backslash separators) — the shipped fixture set must
        # stay green through a baseline that emits exactly that shape, the
        # normalization must stay root-anchored (no substring loosening), and a
        # crashing baseline must surface as an error. Mirrors the bash twin.
        $cWin = New-VsrCopy
        $winEvalsPath = ($cWin.Vault -replace '\\', '/') + '/' + $VSR_EVALS_REL
        $winBinDir = Join-Path $cWin.Vault 'bin'
        Move-Item -LiteralPath (Join-Path $winBinDir 'vault-search.sh') `
            -Destination (Join-Path $winBinDir 'vault-search-real.sh')
        # LF + UTF-8 no-BOM: bash must be able to execute the stub byte-for-byte.
        # The chmod matters on POSIX runners — WriteAllText creates the file
        # without the execute bit and the runner refuses a non-executable
        # baseline by contract (exit 2, "baseline missing or not executable").
        # The mangling prefix rides in ENVIRON, never `awk -v` (a -v value
        # undergoes escape processing — the shipped fix's own rule).
        $vsrUtf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $winSearchSh = ($cWin.Vault -replace '\\', '/') + '/bin/vault-search.sh'
        $winStubTemplate = @'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
out="$(bash "$DIR/vault-search-real.sh" "$@")"; rc=$?
[ -n "$out" ] && printf '%s\n' "$out" | VS_PREFIX="__PREFIX__" VS_SEP="__SEP__" awk 'BEGIN { p = ENVIRON["VS_PREFIX"]; s = ENVIRON["VS_SEP"] } { gsub("/", "\\"); print p s $0 }'
exit "$rc"
'@
        function Write-VsrWinStub([string]$Prefix, [string]$Sep) {
            $body = $winStubTemplate.Replace('__PREFIX__', $Prefix).Replace('__SEP__', $Sep)
            [System.IO.File]::WriteAllText((Join-Path $winBinDir 'vault-search.sh'), ($body + "`n"), $vsrUtf8NoBom)
            & bash -c "chmod +x '$winSearchSh'"
        }
        Write-VsrWinStub '$ROOT' '/'
        Assert-Exit 'vault-scaffolding-retrieval.test: fixtures stay green when the baseline emits absolute+backslash paths' 0 -- `
            bash $winEvalsPath
        Write-VsrWinStub '$ROOT' '/wrong\'
        Assert-Exit 'vault-scaffolding-retrieval.test: a wrong-directory hit still fails the fixture compare' 1 -- `
            bash $winEvalsPath
        Write-VsrWinStub '$ROOT' '\'
        Assert-Exit 'vault-scaffolding-retrieval.test: a non-root-anchored backslash path is not normalized into a match' 1 -- `
            bash $winEvalsPath
        Write-VsrWinStub 'C:/fake vault' '/'
        & bash -c "RETRIEVAL_EVALS_NATIVE_ROOT='C:/fake vault' bash '$winEvalsPath'" *> $null
        Assert-Eq 'vault-scaffolding-retrieval.test: the native-root branch strips an injected drive-letter root' 0 $LASTEXITCODE
        Assert-Exit 'vault-scaffolding-retrieval.test: drive-letter lines stay misses when no native root exists' 1 -- `
            bash $winEvalsPath
        $winCrashStub = "#!/usr/bin/env bash`necho garbage-line`nexit 2"
        [System.IO.File]::WriteAllText((Join-Path $winBinDir 'vault-search.sh'), ($winCrashStub + "`n"), $vsrUtf8NoBom)
        & bash -c "chmod +x '$winSearchSh'"
        $winErrOut = (& bash $winEvalsPath 2>&1) -join "`n"
        Assert-Eq 'vault-scaffolding-retrieval.test: a crashing baseline fails the eval run' 1 $LASTEXITCODE
        Assert-Contains 'vault-scaffolding-retrieval.test: a crashing baseline is reported as a baseline error' `
            $winErrOut 'baseline errored (exit 2)'
        Remove-Item -LiteralPath $cWin.Parent -Recurse -Force -ErrorAction SilentlyContinue
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

    # --- T10: local-config seams (bin/session-index.local.json). The config is
    # what lets a live vault keep operator behavior in DATA while the script
    # stays byte-identical to its template twin.
    $c10 = New-VsrCopy
    $vsrCfg10 = Join-Path $c10.Vault 'bin' 'session-index.local.json'
    $vsrGen10 = Join-Path $c10.Vault $VSR_SESSION_REL
    # (a) fail-loud posture: an empty corpus becomes a corpus-integrity exit 2,
    # and the generator refuses to write a view it cannot populate.
    Set-Content -LiteralPath $vsrCfg10 -Value '{"failOnEmptyCorpus": true}'
    $vsrT10Out = (& node $vsrGen10 --check 2>&1) -join "`n"
    Assert-Eq 'vault-scaffolding-retrieval.test: failOnEmptyCorpus turns an empty corpus into exit 2' 2 $LASTEXITCODE
    Assert-Contains 'vault-scaffolding-retrieval.test: the fail-loud empty corpus names itself' `
        $vsrT10Out 'session corpus empty'
    $vsrSeamParent = Join-Path ([System.IO.Path]::GetTempPath()) ("vsr-seam-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $vsrSeamParent '90-Indexes') -Force | Out-Null
    # try/finally: the env var must not leak into later tests if anything
    # between set and clear throws — the bash twin scopes it per-invocation.
    try {
        $env:VAULT_AUDIT_ROOT = $vsrSeamParent
        $vsrT10mOut = (& node $vsrGen10 2>&1) -join "`n"
        $vsrT10mRc = $LASTEXITCODE
    }
    finally {
        Remove-Item Env:VAULT_AUDIT_ROOT -ErrorAction SilentlyContinue
    }
    Assert-Eq 'vault-scaffolding-retrieval.test: failOnEmptyCorpus turns a missing corpus into exit 2' 2 $vsrT10mRc
    Assert-Contains 'vault-scaffolding-retrieval.test: the fail-loud missing corpus names itself' `
        $vsrT10mOut 'session corpus missing'
    if (-not (Test-Path -LiteralPath (Join-Path $vsrSeamParent '90-Indexes' 'Session Index.md'))) {
        _Pass 'vault-scaffolding-retrieval.test: the generator refuses to write an index it cannot populate'
    }
    else {
        _Fail 'vault-scaffolding-retrieval.test: the generator refuses to write an index it cannot populate' "view written under $vsrSeamParent"
    }
    Remove-Item -LiteralPath $vsrSeamParent -Recurse -Force -ErrorAction SilentlyContinue
    # (b) machineFolds + viewTag are honored: a folded spelling lands under its
    # canonical token and the view carries the configured tag.
    Set-Content -LiteralPath $vsrCfg10 -Value '{"machineFolds":{"old-mbp":"main-machine"},"viewTag":"custom-vault/retrieval"}'
    $vsrSessDir10 = Join-Path $c10.Vault '30-Archive' 'Sessions'
    New-Item -ItemType Directory -Path $vsrSessDir10 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $vsrSessDir10 '2026-01-02-000000-old-mbp-fixture.md') -Value @'
---
title: fold fixture
date: 2026-01-02
harness: claude-code
machine: Old-MBP.local
linear: [ABC-1]
---

## Issues this session

### ABC-1 — fixture
'@
    node $vsrGen10 *> $null
    $vsrT10View = Get-Content -LiteralPath (Join-Path $c10.Vault $VSR_VIEW_REL) -Raw
    Assert-Contains 'vault-scaffolding-retrieval.test: machineFolds folds a confirmed spelling to its canonical token' `
        $vsrT10View '| Machine | main-machine (1) |'
    Assert-Contains 'vault-scaffolding-retrieval.test: viewTag replaces the default frontmatter tag' `
        $vsrT10View 'custom-vault/retrieval'
    # (c) restraint: with NO config the same tree gets the conservative
    # pass-through and the default tag — folds come only from local data.
    Remove-Item -LiteralPath $vsrCfg10 -Force
    node $vsrGen10 *> $null
    $vsrT10View = Get-Content -LiteralPath (Join-Path $c10.Vault $VSR_VIEW_REL) -Raw
    Assert-Contains 'vault-scaffolding-retrieval.test: without config the spelling passes through lowercased (no guessed fold)' `
        $vsrT10View '| Machine | old-mbp (1) |'
    Assert-Contains 'vault-scaffolding-retrieval.test: without config the view keeps the default tag' `
        $vsrT10View 'memory-vault/retrieval'
    # (d) a malformed config file fails loud (exit 2), never a silent default.
    Set-Content -LiteralPath $vsrCfg10 -Value '{nope'
    $vsrT10cOut = (& node $vsrGen10 --check 2>&1) -join "`n"
    Assert-Eq 'vault-scaffolding-retrieval.test: a malformed local config exits 2' 2 $LASTEXITCODE
    Assert-Contains 'vault-scaffolding-retrieval.test: a malformed local config names itself' `
        $vsrT10cOut 'local config malformed'
    # (e) documented types are ENFORCED, not coerced: a stringly boolean would
    # silently flip the posture ("false" is truthy), a multiline tag would
    # break the view's YAML frontmatter (panel findings).
    Set-Content -LiteralPath $vsrCfg10 -Value '{"failOnEmptyCorpus": "false"}'
    $vsrT10eOut = (& node $vsrGen10 --check 2>&1) -join "`n"
    Assert-Eq 'vault-scaffolding-retrieval.test: a non-boolean failOnEmptyCorpus exits 2' 2 $LASTEXITCODE
    Assert-Contains 'vault-scaffolding-retrieval.test: the non-boolean failOnEmptyCorpus names its key' `
        $vsrT10eOut 'failOnEmptyCorpus must be a boolean'
    Set-Content -LiteralPath $vsrCfg10 -Value '{"viewTag": "a\nb"}'
    $vsrT10fOut = (& node $vsrGen10 --check 2>&1) -join "`n"
    Assert-Eq 'vault-scaffolding-retrieval.test: a multiline viewTag exits 2' 2 $LASTEXITCODE
    Assert-Contains 'vault-scaffolding-retrieval.test: the multiline viewTag names its key' `
        $vsrT10fOut 'viewTag must be a non-empty single-line string'
    # (f) the fold table never consults inherited Object.prototype properties:
    # a machine legitimately named `constructor` passes through as itself even
    # while unrelated folds are configured (panel finding).
    Set-Content -LiteralPath $vsrCfg10 -Value '{"machineFolds":{"old-mbp":"main-machine"}}'
    Set-Content -LiteralPath (Join-Path $vsrSessDir10 '2026-01-03-000000-proto-fixture.md') -Value @'
---
title: proto fixture
date: 2026-01-03
harness: claude
machine: Constructor
---
'@
    node $vsrGen10 *> $null
    $vsrT10View = Get-Content -LiteralPath (Join-Path $c10.Vault $VSR_VIEW_REL) -Raw
    Assert-Contains 'vault-scaffolding-retrieval.test: a prototype-property machine name passes through as itself' `
        $vsrT10View '| 2026-01-03 | claude | constructor |'
    Remove-Item -LiteralPath $c10.Parent -Recurse -Force -ErrorAction SilentlyContinue

    # --- T11: the $VAULT_AUDIT_ROOT seam retargets the generator at the given
    # root, and the audit PINS its session child to its own root so a stray env
    # value can never make parent and child check two different trees.
    $c11a = New-VsrCopy
    $c11b = New-VsrCopy
    Add-Content -LiteralPath (Join-Path $c11b.Vault $VSR_VIEW_REL) -Value 'HAND EDIT'
    # try/finally: same env-leak guard as T10 — the var must be gone even if
    # an invocation throws.
    try {
        $env:VAULT_AUDIT_ROOT = $c11b.Vault
        & node (Join-Path $c11a.Vault $VSR_SESSION_REL) --check *> $null
        $vsrT11Rc = $LASTEXITCODE
        $vsrT11Out = (& node (Join-Path $c11a.Vault $VSR_AUDIT_REL) 2>&1) -join "`n"
    }
    finally {
        Remove-Item Env:VAULT_AUDIT_ROOT -ErrorAction SilentlyContinue
    }
    Assert-Eq 'vault-scaffolding-retrieval.test: VAULT_AUDIT_ROOT retargets --check at the seam root (drift there is seen)' 1 $vsrT11Rc
    Assert-Exit 'vault-scaffolding-retrieval.test: without the seam the same generator is clean on its own root' 0 -- `
        node (Join-Path $c11a.Vault $VSR_SESSION_REL) --check
    Assert-Contains 'vault-scaffolding-retrieval.test: the audit pins its session child to its own root (stray env ignored)' `
        $vsrT11Out 'PASS session index view matches regeneration'
    Remove-Item -LiteralPath $c11a.Parent, $c11b.Parent -Recurse -Force -ErrorAction SilentlyContinue
}
