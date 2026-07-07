#Requires -Version 7
# tests/new-project.test.ps1 — Windows-native twin of tests/new-project.test.sh.
#
# Behavioral tests for scripts/new-project.ps1. The scaffold copies
# templates/project-CLAUDE.md + templates/project-AGENTS.md into
# <repo-root>/projects/<name>/ as CLAUDE.md + AGENTS.md — it is the tracked
# consumer of those two templates, so these tests also pin the template CONTRACT
# a scaffolded project depends on (the '## Project context' section the docs
# tell the operator to edit). Exit 0 = scaffolded; 1 = usage/exists/invalid-name/
# missing-template/git-init errors.
#
# Scaffolding runs inside a throwaway fixture repo-root (scripts/ + templates/
# copied in) — never against $env:REPO_ROOT itself, so no projects/ folder is
# ever created in the tree under test.
#
# Mirrors the .sh twin 1:1 — same fixtures, same assertions — with one noted
# exception: the .sh twin's CDPATH-immunity test (1b) has no mirror here
# because PowerShell's Set-Location does not consult CDPATH, so the guarded
# failure mode does not exist in the .ps1 script.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$CMD_SCRIPT = Join-Path $env:REPO_ROOT 'scripts' 'new-project.ps1'
Assert-File 'np: scripts/new-project.ps1 exists' $CMD_SCRIPT
Assert-File 'np: scripts/new-project.sh twin exists' (Join-Path $env:REPO_ROOT 'scripts' 'new-project.sh')

function New-NpTempDir {
    param([string]$Prefix = 'np-test')
    $d = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + '-' + [Guid]::NewGuid().Guid.Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $d
}

# New-NpFixture <dir> — a minimal framework checkout: the scaffold script + the
# two templates it consumes, laid out at the paths the script derives from its
# own location (repo_root = parent of scripts/).
function New-NpFixture {
    param([string]$R)
    New-Item -ItemType Directory -Path (Join-Path $R 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $R 'templates') -Force | Out-Null
    Copy-Item -LiteralPath $CMD_SCRIPT -Destination (Join-Path $R 'scripts')
    Copy-Item -LiteralPath (Join-Path $env:REPO_ROOT 'templates' 'project-CLAUDE.md') -Destination (Join-Path $R 'templates')
    Copy-Item -LiteralPath (Join-Path $env:REPO_ROOT 'templates' 'project-AGENTS.md') -Destination (Join-Path $R 'templates')
}

# Invoke-Np <fixture-root> <args...> — run the fixture's scaffold script, return
# @{ Out = <joined stdout+stderr>; Rc = <exit code> }.
function Invoke-Np {
    param([string]$Root, [string[]]$Argv = @())
    $script = Join-Path $Root 'scripts' 'new-project.ps1'
    $out = & pwsh -NoProfile -File $script @Argv 2>&1
    $rc = $LASTEXITCODE
    if ($out -is [array]) { $out = $out -join "`n" }
    return @{ Out = [string]$out; Rc = $rc }
}

# Cleanup lives in the finally block (repo convention — see drift.test.ps1): a
# terminating error mid-file must not leave np-* temp dirs behind.
$FIX = $null; $FIX2 = $null; $TR = $null; $STUB = $null
try {
    $FIX = New-NpTempDir 'np-fix'
    New-NpFixture $FIX

    # === 1. Plain scaffold: exit 0, both entrypoints exist, output names the dest.
    $r1 = Invoke-Np $FIX @('demo')
    Assert-Eq 'np: scaffold exits 0' '0' ([string]$r1.Rc)
    Assert-File 'np: CLAUDE.md scaffolded' (Join-Path $FIX 'projects' 'demo' 'CLAUDE.md')
    Assert-File 'np: AGENTS.md scaffolded' (Join-Path $FIX 'projects' 'demo' 'AGENTS.md')
    Assert-Contains 'np: output names the created project' $r1.Out 'created project:'
    Assert-Contains 'np: output points at the Project context edit' $r1.Out '## Project context'

    # (1b in the .sh twin — CDPATH immunity — has no mirror here; see header.)

    # === 2. Scaffolded entrypoints are byte-identical to their templates.
    $hashTplC = (Get-FileHash -LiteralPath (Join-Path $FIX 'templates' 'project-CLAUDE.md')).Hash
    $hashOutC = (Get-FileHash -LiteralPath (Join-Path $FIX 'projects' 'demo' 'CLAUDE.md')).Hash
    Assert-Eq 'np: CLAUDE.md byte-identical to project-CLAUDE.md' $hashTplC $hashOutC
    $hashTplA = (Get-FileHash -LiteralPath (Join-Path $FIX 'templates' 'project-AGENTS.md')).Hash
    $hashOutA = (Get-FileHash -LiteralPath (Join-Path $FIX 'projects' 'demo' 'AGENTS.md')).Hash
    Assert-Eq 'np: AGENTS.md byte-identical to project-AGENTS.md' $hashTplA $hashOutA

    # === 3. The template contract: both scaffolded entrypoints carry the
    # '## Project context' section the scaffold's next-steps output tells the
    # operator to edit.
    $ctxC = Select-String -LiteralPath (Join-Path $FIX 'projects' 'demo' 'CLAUDE.md') -Pattern '^## Project context$' -Quiet
    Assert-Eq 'np: scaffolded CLAUDE.md carries ## Project context' 'True' ([string]$ctxC)
    $ctxA = Select-String -LiteralPath (Join-Path $FIX 'projects' 'demo' 'AGENTS.md') -Pattern '^## Project context$' -Quiet
    Assert-Eq 'np: scaffolded AGENTS.md carries ## Project context' 'True' ([string]$ctxA)

    # === 4. Existing destination fails closed with a message naming it.
    $r4 = Invoke-Np $FIX @('demo')
    Assert-Eq 'np: existing dest exits 1' '1' ([string]$r4.Rc)
    Assert-Contains 'np: existing dest error says already exists' $r4.Out 'already exists'

    # === 5. Usage errors: no args, flag-shaped name, unknown second arg.
    $r5 = Invoke-Np $FIX @()
    Assert-Eq 'np: no args exits 1' '1' ([string]$r5.Rc)
    Assert-Contains 'np: no args prints usage' $r5.Out 'usage:'
    $r5b = Invoke-Np $FIX @('--git')
    Assert-Eq 'np: flag-shaped name (--git) rejected' '1' ([string]$r5b.Rc)
    $r5c = Invoke-Np $FIX @('other', '--frog')
    Assert-Eq 'np: unknown second arg rejected' '1' ([string]$r5c.Rc)

    # === 6. Invalid names fail closed: path separators and dot-dirs would
    # scaffold outside projects/ on one platform or the other.
    $r6a = Invoke-Np $FIX @('a/b')
    Assert-Eq 'np: slash name rejected' '1' ([string]$r6a.Rc)
    $r6b = Invoke-Np $FIX @('a\b')
    Assert-Eq 'np: backslash name rejected' '1' ([string]$r6b.Rc)
    $r6c = Invoke-Np $FIX @('..')
    Assert-Eq 'np: dot-dot name rejected' '1' ([string]$r6c.Rc)

    # === 7. --git initializes a repo inside the new project.
    $r7 = Invoke-Np $FIX @('gitproj', '--git')
    Assert-Eq 'np: --git scaffold exits 0' '0' ([string]$r7.Rc)
    $gitDir = Test-Path -LiteralPath (Join-Path $FIX 'projects' 'gitproj' '.git')
    Assert-Eq 'np: --git created a .git dir' 'True' ([string]$gitDir)

    # === 7b. --git failure path: exit 1 + the same message as the bash twin (a
    # stub git that always fails, prepended to PATH — the twins' error
    # contract). Both a POSIX shim and a .cmd shim so the stub wins command
    # resolution on every platform the suite runs on.
    $STUB = New-NpTempDir 'np-stub'
    Set-Content -LiteralPath (Join-Path $STUB 'git') -Value "#!/bin/sh`nexit 3"
    if (-not $IsWindows) { & chmod +x (Join-Path $STUB 'git') }
    Set-Content -LiteralPath (Join-Path $STUB 'git.cmd') -Value '@exit /b 3'
    $oldPath = $env:PATH
    $env:PATH = $STUB + [IO.Path]::PathSeparator + $env:PATH
    try {
        $r7b = Invoke-Np $FIX @('gitfail', '--git')
    } finally {
        $env:PATH = $oldPath
    }
    Assert-Eq 'np: --git failure exits 1 (not git''s raw status)' '1' ([string]$r7b.Rc)
    Assert-Contains 'np: --git failure names git init' $r7b.Out 'git init failed'

    # === 8. Missing templates fail closed BEFORE creating anything.
    $FIX2 = New-NpTempDir 'np-fix2'
    New-Item -ItemType Directory -Path (Join-Path $FIX2 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $CMD_SCRIPT -Destination (Join-Path $FIX2 'scripts')
    $r8 = Invoke-Np $FIX2 @('demo')
    Assert-Eq 'np: missing templates exits 1' '1' ([string]$r8.Rc)
    Assert-Contains 'np: missing templates error names the template' $r8.Out 'missing template'
    $projDir = Test-Path -LiteralPath (Join-Path $FIX2 'projects')
    Assert-Eq 'np: missing templates creates no projects dir' 'False' ([string]$projDir)

    # === 9. The tracked .gitignore covers projects/ — hermetic check in a
    # throwaway git repo (the operator's .git/info/exclude cannot mask a
    # regression here).
    $TR = New-NpTempDir 'np-tr'
    git -C $TR init -q
    Copy-Item -LiteralPath (Join-Path $env:REPO_ROOT '.gitignore') -Destination (Join-Path $TR '.gitignore')
    New-Item -ItemType Directory -Path (Join-Path $TR 'projects' 'x') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $TR 'projects' 'x' 'CLAUDE.md') -Value 'scaffolded'
    Assert-Exit 'np: projects/ path is gitignored by the tracked .gitignore' 0 -- `
        git -C $TR check-ignore -q projects/x/CLAUDE.md
    $status9 = git -C $TR status --porcelain -- projects 2>&1
    if ($status9 -is [array]) { $status9 = $status9 -join "`n" }
    Assert-Eq 'np: scaffolded workspace invisible to git status' '' ([string]$status9)
} finally {
    foreach ($d in @($FIX, $FIX2, $TR, $STUB)) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
