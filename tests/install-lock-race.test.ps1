#Requires -Version 7
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/install-lock-race.test.ps1
#
# Runtime proof for the PowerShell half of the shared exclusive lock-file
# protocol. Two child installers start against one copied target. Exactly one
# must acquire FileMode.CreateNew; the other must fail before compilation or
# swap. The Bash twin supplies the explicit after-backup barrier schedule.

$IL_INSTALL = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$IL_ROOT = Join-Path ([IO.Path]::GetTempPath()) ('install-lock-race-' + [Guid]::NewGuid().Guid.Substring(0,8))
$IL_TARGET = Join-Path $IL_ROOT 'target'
$IL_ENV = Join-Path $IL_ROOT 'local.env'
$IL_WRAP = Join-Path $IL_ROOT 'run-install.ps1'
$IL_A_REPO = Join-Path $IL_ROOT 'a-repo'
$IL_A_INSTALL = Join-Path $IL_A_REPO 'scripts' 'install.ps1'
$IL_BARRIER = Join-Path $IL_ROOT 'barrier'
$IL_UTF8 = [System.Text.UTF8Encoding]::new($false)
$a = $null
$b = $null
New-Item -ItemType Directory -Path $IL_TARGET -Force | Out-Null
Write-LocalEnvFixture -EnvFile $IL_ENV -ConfigDir $IL_TARGET -VaultDir (Join-Path $IL_ROOT 'vault')
[System.IO.File]::WriteAllText($IL_WRAP, @'
param([string]$EnvFile, [string]$Install, [string]$Barrier, [string]$Pause)
$env:AI_CONFIG_LOCAL_ENV = $EnvFile
$env:RACE_INSTALL_LOCK_BARRIER = $Barrier
$env:RACE_INSTALL_LOCK_PAUSE = $Pause
& pwsh -NoProfile -File $Install --harness claude
exit $LASTEXITCODE
'@, $IL_UTF8)

try {
    New-Item -ItemType Directory -Path $IL_BARRIER -Force | Out-Null
    New-Item -ItemType Directory -Path $IL_A_REPO -Force | Out-Null
    Get-ChildItem -LiteralPath $env:REPO_ROOT -Force | Copy-Item -Destination $IL_A_REPO -Recurse -Force
    $aSource = [System.IO.File]::ReadAllText($IL_A_INSTALL)
    $anchor = '        Enter-InstallerLock -LockTarget $TARGET'
    if ($aSource.Split($anchor).Count -ne 2) { throw 'PowerShell installer lock anchor missing or non-unique' }
    $pause = $anchor + "`n" + @'
        if ($env:RACE_INSTALL_LOCK_PAUSE -eq '1') {
            [System.IO.File]::WriteAllText((Join-Path $env:RACE_INSTALL_LOCK_BARRIER 'owner-ready'), "$PID`n", [System.Text.UTF8Encoding]::new($false))
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while (-not (Test-Path -LiteralPath (Join-Path $env:RACE_INSTALL_LOCK_BARRIER 'release'))) {
                if ([DateTime]::UtcNow -gt $deadline) { throw 'PowerShell installer race barrier timed out' }
                Start-Sleep -Milliseconds 20
            }
        }
'@
    [System.IO.File]::WriteAllText($IL_A_INSTALL, $aSource.Replace($anchor, $pause), $IL_UTF8)
    $aOut = Join-Path $IL_ROOT 'a.out'; $aErr = Join-Path $IL_ROOT 'a.err'
    $bOut = Join-Path $IL_ROOT 'b.out'; $bErr = Join-Path $IL_ROOT 'b.err'
    $aArg = "-NoProfile -File `"$IL_WRAP`" `"$IL_ENV`" `"$IL_A_INSTALL`" `"$IL_BARRIER`" 1"
    $a = Start-Process -FilePath pwsh -ArgumentList $aArg -RedirectStandardOutput $aOut -RedirectStandardError $aErr -PassThru
    $wait = 0
    while (-not (Test-Path -LiteralPath (Join-Path $IL_BARRIER 'owner-ready')) -and $wait -lt 750) { Start-Sleep -Milliseconds 20; $wait++ }
    $ownerReady = Join-Path $IL_BARRIER 'owner-ready'
    if (Test-Path -LiteralPath $ownerReady -PathType Leaf) {
        _Pass 'install lock race PS: A holds lock before B starts'
    } else {
        $aDiagnostic = Get-Content -LiteralPath $aErr -Raw -ErrorAction SilentlyContinue
        _Fail 'install lock race PS: A holds lock before B starts' "owner-ready missing; A stderr: $aDiagnostic"
    }
    $bArg = "-NoProfile -File `"$IL_WRAP`" `"$IL_ENV`" `"$IL_INSTALL`" `"$IL_BARRIER`" 0"
    $b = Start-Process -FilePath pwsh -ArgumentList $bArg -RedirectStandardOutput $bOut -RedirectStandardError $bErr -PassThru
    if (-not $b.WaitForExit(15000)) { $b.Kill($true); throw 'PowerShell contender B exceeded 15 seconds' }
    [System.IO.File]::WriteAllText((Join-Path $IL_TARGET '.install-lock'), "replacement owner`n", $IL_UTF8)
    [System.IO.File]::WriteAllText((Join-Path $IL_BARRIER 'release'), '', $IL_UTF8)
    if (-not $a.WaitForExit(15000)) { $a.Kill($true); throw 'PowerShell owner A exceeded 15 seconds' }
    Assert-Eq 'install lock race PS: owner A succeeds after explicit release' '0' "$($a.ExitCode)"
    Assert-Eq 'install lock race PS: B refuses while A owns the barrier' '1' "$($b.ExitCode)"
    $combined = ((Get-Content -LiteralPath $aOut -Raw -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $aErr -Raw -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $bOut -Raw -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $bErr -Raw -ErrorAction SilentlyContinue))
    Assert-Contains 'install lock race PS: contended writer names ownership lock' $combined 'another installer owns physical target'
    Assert-File 'install lock race PS: successful writer produces entrypoint' (Join-Path $IL_TARGET 'CLAUDE.md')
    Assert-File 'install lock race PS: changed owner token survives A cleanup' (Join-Path $IL_TARGET '.install-lock')
    Assert-Eq 'install lock race PS: changed owner token stays intact' 'replacement owner' ([System.IO.File]::ReadAllText((Join-Path $IL_TARGET '.install-lock')).Trim())
    Remove-Item -LiteralPath (Join-Path $IL_TARGET '.install-lock') -Force
    $env:AI_CONFIG_LOCAL_ENV = $IL_ENV
    $null = & pwsh -NoProfile -File $IL_INSTALL --harness claude 2>&1
    Assert-Eq 'install lock race PS: serial writer succeeds after owner release' '0' "$LASTEXITCODE"
    if (Test-Path -LiteralPath (Join-Path $IL_TARGET '.install-lock')) {
        _Fail 'install lock race PS: serial writer releases its lock' '.install-lock remains after serial writer exit'
    } else {
        _Pass 'install lock race PS: serial writer releases its lock'
    }

    # A foreign/stale lock is never taken over automatically.
    [System.IO.File]::WriteAllText((Join-Path $IL_TARGET '.install-lock'), "foreign owner`n", $IL_UTF8)
    $env:AI_CONFIG_LOCAL_ENV = $IL_ENV
    $foreign = (& pwsh -NoProfile -File $IL_INSTALL --harness claude 2>&1 | Out-String)
    $foreignCode = $LASTEXITCODE
    Assert-Eq 'install lock race PS: foreign lock refuses manual takeover' '1' "$foreignCode"
    Assert-File 'install lock race PS: foreign lock remains for confirmation' (Join-Path $IL_TARGET '.install-lock')
    Remove-Item -LiteralPath (Join-Path $IL_TARGET '.install-lock') -Force

    $lockPath = Join-Path $IL_TARGET '.install-lock'
    New-Item -ItemType Directory -Path $lockPath | Out-Null
    $directoryLock = (& pwsh -NoProfile -File $IL_INSTALL --harness claude 2>&1 | Out-String)
    Assert-Eq 'install lock race PS: directory lock refuses without blocking' '1' "$LASTEXITCODE"
    if (Test-Path -LiteralPath $lockPath -PathType Container) {
        _Pass 'install lock race PS: directory lock is preserved'
    } else {
        _Fail 'install lock race PS: directory lock is preserved' 'directory lock disappeared'
    }
    Remove-Item -LiteralPath $lockPath -Recurse -Force

    $missingLockTarget = Join-Path $IL_ROOT 'missing-lock-target'
    try {
        New-Item -ItemType SymbolicLink -Path $lockPath -Target $missingLockTarget -ErrorAction Stop | Out-Null
        $danglingLock = (& pwsh -NoProfile -File $IL_INSTALL --harness claude 2>&1 | Out-String)
        Assert-Eq 'install lock race PS: dangling symlink lock refuses without blocking' '1' "$LASTEXITCODE"
        if (Get-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue) {
            _Pass 'install lock race PS: dangling symlink lock is preserved'
        } else {
            _Fail 'install lock race PS: dangling symlink lock is preserved' 'dangling symlink disappeared'
        }
        Remove-Item -LiteralPath $lockPath -Force
    } catch {
        _Skip 'install lock race PS: dangling symlink lock refusal' "symbolic links unavailable: $($_.Exception.Message)"
    }

    # Build-only and dry-run are inspect-only and must not reserve the target.
    $null = & pwsh -NoProfile -File $IL_INSTALL --harness claude --dry-run 2>&1
    Assert-Eq 'install lock race PS: dry-run exits 0 without lock' '0' "$LASTEXITCODE"
    if (Test-Path -LiteralPath (Join-Path $IL_TARGET '.install-lock')) {
        _Fail 'install lock race PS: dry-run leaves no lock' '.install-lock exists after dry-run'
    } else {
        _Pass 'install lock race PS: dry-run leaves no lock'
    }

    $buildOnlyOut = (& pwsh -NoProfile -File $IL_INSTALL --harness claude --build-only 2>&1 | Out-String).Trim()
    Assert-Eq 'install lock race PS: build-only exits 0 without lock' '0' "$LASTEXITCODE"
    if (Test-Path -LiteralPath (Join-Path $IL_TARGET '.install-lock')) {
        _Fail 'install lock race PS: build-only leaves no lock' '.install-lock exists after build-only'
    } else {
        _Pass 'install lock race PS: build-only leaves no lock'
    }
    if ($buildOnlyOut -and (Test-Path -LiteralPath $buildOnlyOut -PathType Container)) {
        Remove-Item -LiteralPath $buildOnlyOut -Recurse -Force -ErrorAction SilentlyContinue
    }

    $env:AI_CONFIG_INSTALL_TEST_FAIL_SWAP = 'hooks'
    try { $null = & pwsh -NoProfile -File $IL_INSTALL --harness claude 2>&1; $failCode = $LASTEXITCODE }
    finally { Remove-Item Env:AI_CONFIG_INSTALL_TEST_FAIL_SWAP -ErrorAction SilentlyContinue }
    Assert-Eq 'install lock race PS: rollback error remains nonzero' '1' "$failCode"
    if (Test-Path -LiteralPath (Join-Path $IL_TARGET '.install-lock')) {
        _Fail 'install lock race PS: rollback error releases owned lock' '.install-lock remains after rollback'
    } else {
        _Pass 'install lock race PS: rollback error releases owned lock'
    }

    # A cleanup failure must be visible and must leave the owner's lock in
    # place. The changed-owner assertion above separately proves this cleanup
    # path never deletes a replacement token.
    $releaseAnchor = '                Remove-Item -LiteralPath $lockDir -Force -ErrorAction Stop'
    $releaseSource = [System.IO.File]::ReadAllText($IL_A_INSTALL)
    if ($releaseSource.Split($releaseAnchor).Count -ne 2) { throw 'PowerShell installer release anchor missing or non-unique' }
    [System.IO.File]::WriteAllText(
        $IL_A_INSTALL,
        $releaseSource.Replace($releaseAnchor, "                throw 'forced installer lock release failure'"),
        $IL_UTF8
    )
    $releaseFailureOutput = (& pwsh -NoProfile -File $IL_A_INSTALL --harness claude 2>&1 | Out-String)
    $releaseFailureCode = $LASTEXITCODE
    Assert-Eq 'install lock race PS: forced release failure keeps install successful' '0' "$releaseFailureCode"
    Assert-Contains 'install lock race PS: forced release failure warns operator' $releaseFailureOutput 'could not remove owned installer lock'
    Assert-File 'install lock race PS: forced release failure leaves owned lock for inspection' (Join-Path $IL_TARGET '.install-lock')
    Remove-Item -LiteralPath (Join-Path $IL_TARGET '.install-lock') -Force

    # Codex's .agents mirror is a separate target. A foreign mirror lock must
    # keep its bytes intact after the main codex target has been installed.
    $IL_CODEX = Join-Path $IL_ROOT 'codex'
    $IL_AGENTS = Join-Path $IL_ROOT 'agents'
    $IL_CODEX_ENV = Join-Path $IL_ROOT 'codex.local.env'
    $IL_AGENT_SKILL = Join-Path $IL_AGENTS 'skills/closeout/SKILL.md'
    New-Item -ItemType Directory -Path (Split-Path -Parent $IL_AGENT_SKILL) -Force | Out-Null
    [System.IO.File]::WriteAllText($IL_AGENT_SKILL, "untouched mirror sentinel`n", $IL_UTF8)
    $agentsBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($IL_AGENT_SKILL))
    $codexEnv = @(
        "CODEX_HOME=`"$IL_CODEX`""
        "OBSIDIAN_VAULT_PATH=`"$(Join-Path $IL_ROOT 'vault')`""
        "AGENTS_DIR=`"$IL_AGENTS`""
        ''
    ) -join "`n"
    [System.IO.File]::WriteAllText($IL_CODEX_ENV, $codexEnv, $IL_UTF8)
    [System.IO.File]::WriteAllText((Join-Path $IL_AGENTS '.install-lock'), "foreign mirror owner`n", $IL_UTF8)
    $env:AI_CONFIG_LOCAL_ENV = $IL_CODEX_ENV
    $agentsOutput = (& pwsh -NoProfile -File $IL_INSTALL --harness codex 2>&1 | Out-String)
    $agentsCode = $LASTEXITCODE
    Assert-Eq 'install lock race PS: .agents contention fails after main target' '1' "$agentsCode"
    Assert-File 'install lock race PS: .agents contention leaves main codex render' (Join-Path $IL_CODEX 'AGENTS.md')
    Assert-File 'install lock race PS: .agents foreign lock survives' (Join-Path $IL_AGENTS '.install-lock')
    Assert-Contains 'install lock race PS: .agents contention states mirror was untouched' $agentsOutput '.agents mirror was not touched'
    Assert-Eq 'install lock race PS: .agents contention preserves mirror bytes' $agentsBefore ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($IL_AGENT_SKILL)))
} finally {
    foreach ($child in @($a, $b)) {
        if ($null -eq $child) { continue }
        try {
            if (-not $child.HasExited) {
                $child.Kill($true)
                $null = $child.WaitForExit(5000)
            }
        } catch {
            # Preserve the test failure while making a best-effort cleanup of
            # the child process tree before this fixture root is removed.
        } finally {
            $child.Dispose()
        }
    }
    Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $IL_ROOT -Recurse -Force -ErrorAction SilentlyContinue
}
