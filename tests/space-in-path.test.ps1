#Requires -Version 7
# tests/space-in-path.test.ps1 — Windows-native twin of tests/space-in-path.test.sh.
#
# <TEAM>-298 #3 — space-in-path robustness. Windows paths routinely contain spaces
# ("Program Files", user names), the operator's OBSIDIAN_VAULT_PATH has one, and
# the co-location default (<TEAM>-297) can put CLAUDE_CONFIG_DIR under a spaced repo
# path. PowerShell does not word-split variable expansion the way POSIX sh does,
# but Join-Path / Resolve-Path / -LiteralPath discipline still has to hold — this
# drives install.ps1, -DryRun, and self-audit.ps1 from spaced paths end to end.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$INSTALL_PS1   = Join-Path $env:REPO_ROOT 'scripts' 'install.ps1'
$SELFAUDIT_PS1 = Join-Path $env:REPO_ROOT 'scripts' 'self-audit.ps1'

$spRoot  = Join-Path ([IO.Path]::GetTempPath()) ('space-' + [Guid]::NewGuid().Guid.Substring(0,8))
$spTgt   = Join-Path $spRoot 'config dir'     # space in the config dir (co-located case)
$spVault = Join-Path $spRoot 'my vault'       # space in the vault path
New-Item -ItemType Directory -Path $spTgt -Force | Out-Null
New-Item -ItemType Directory -Path $spVault -Force | Out-Null
$spEnv = Join-Path $spRoot 'local.env'
Write-LocalEnvFixture -EnvFile $spEnv -ConfigDir $spTgt -VaultDir $spVault

# install.ps1 must build into a spaced config dir.
$env:AI_CONFIG_LOCAL_ENV = $spEnv
try { & pwsh -NoProfile -File $INSTALL_PS1 --harness claude *>$null; $spInstall = $LASTEXITCODE }
finally { Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue }
Assert-Eq "install.ps1 builds into a config dir containing a space" "0" ([string]$spInstall)
Assert-File "install produced CLAUDE.md in the spaced config dir" (Join-Path $spTgt 'CLAUDE.md')
Assert-File "install produced a spine skill in the spaced config dir" (Join-Path $spTgt 'skills' 'closeout' 'SKILL.md')

# -DryRun must classify a spaced target correctly (in sync right after install).
$env:AI_CONFIG_LOCAL_ENV = $spEnv
try { $spDry = (& pwsh -NoProfile -File $INSTALL_PS1 --dry-run 2>$null) | Out-String }
finally { Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue }
Assert-Contains "--dry-run handles a spaced config dir (reports in sync)" $spDry "in sync with the current framework"

# self-audit.ps1 with a spaced --vault-dir + a planted .git must fire the Drive-git
# guard (proves the spaced path reached the check whole, not split).
New-Item -ItemType Directory -Path (Join-Path $spVault '.git') -Force | Out-Null
$spAudit = (& pwsh -NoProfile -File $SELFAUDIT_PS1 --isolated --repo-root $env:REPO_ROOT --vault-dir $spVault --json 2>$null) | Out-String
Assert-Contains "self-audit Drive-git guard fires on a spaced vault path" $spAudit "Live .git inside the sync-hosted vault"

# Re-install over the spaced target stays idempotent.
$env:AI_CONFIG_LOCAL_ENV = $spEnv
try { & pwsh -NoProfile -File $INSTALL_PS1 --harness claude *>$null; $spReinstall = $LASTEXITCODE }
finally { Remove-Item Env:AI_CONFIG_LOCAL_ENV -ErrorAction SilentlyContinue }
Assert-Eq "re-install over a spaced config dir stays idempotent" "0" ([string]$spReinstall)

Remove-Item -LiteralPath $spRoot -Recurse -Force -ErrorAction SilentlyContinue
