#!/usr/bin/env pwsh
# standalone-invocation guard: this file is DOT-SOURCED by tests/run.ps1
# (which defines the Assert-* helpers). Run standalone the helpers are absent,
# assertions error, yet the file still exits 0 — a false green. Bail loudly instead.
if (-not (Get-Command Assert-Exit -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('ERROR: run via tests/run.ps1 (e.g. pwsh tests/run.ps1 <stem>), not standalone'); exit 1 }
# tests/check-clean.test.ps1 — PowerShell twin of tests/check-clean.test.sh for
# the public-repo cleanliness guard (scripts/check-clean.ps1).
#
# Dot-sourced by tests/run.ps1; uses Assert-* helpers from tests/lib.ps1. All
# planted sentinels are assembled at runtime from non-matching halves per
# [[feedback_self_tripping_test_source]], so this test's own source never
# self-trips the guard when the guard later scans a tree containing it.

$CC_SUT = Join-Path $env:REPO_ROOT 'scripts' 'check-clean.ps1'
Assert-File 'check-clean.ps1 present' $CC_SUT

$CC_TMP = Join-Path ([IO.Path]::GetTempPath()) ('check-clean-' + [Guid]::NewGuid().Guid.Substring(0, 8))
New-Item -ItemType Directory -Path $CC_TMP -Force | Out-Null

# Runtime-built sentinel fragments (no contiguous trip-shape in this source).
$CC_QUE = 'QU' + 'E'
$CC_USERS = 'Us' + 'ers'
$CC_HOME = 'ho' + 'me'
$CC_AT = '@'

# Ensure no inherited token config leaks in from the environment.
Remove-Item Env:\OPERATOR_PII_TOKENS -ErrorAction SilentlyContinue

# --- DIRTY fixture: one file per marker class ---------------------------------
$ccDirty = Join-Path $CC_TMP 'dirty'; New-Item -ItemType Directory -Path $ccDirty -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccDirty 'issue.md')     -Value "tracked under ${CC_QUE}-2024 for follow-up"
Set-Content -LiteralPath (Join-Path $ccDirty 'macpath.txt')  -Value "config lives at /$CC_USERS/realdev/project/work"
Set-Content -LiteralPath (Join-Path $ccDirty 'linuxpath.txt') -Value "linux build dir /$CC_HOME/realdev/out"
Set-Content -LiteralPath (Join-Path $ccDirty 'email.txt')    -Value "reach me at realdev${CC_AT}acme-corp.io anytime"

Assert-Exit 'check-clean FAILS on a dirty tree' 1 -- pwsh -NoProfile -File $CC_SUT $ccDirty

$ccDirtyOut = (& pwsh -NoProfile -File $CC_SUT $ccDirty 2>&1 | Out-String)
Assert-Contains 'dirty report names the issue-ID class' $ccDirtyOut 'tracker issue ID'
Assert-Contains 'dirty report names the home-path class' $ccDirtyOut 'home path'
Assert-Contains 'dirty report names the email class'     $ccDirtyOut 'email'

# --- Per-class isolation ------------------------------------------------------
$ccQ = Join-Path $CC_TMP 'q'; New-Item -ItemType Directory -Path $ccQ -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccQ 'a.md') -Value "see ${CC_QUE}-1 detail"
Assert-Exit 'issue-ID alone FAILS' 1 -- pwsh -NoProfile -File $CC_SUT $ccQ

# Lowercase, no-hyphen tracker token (que<NN>) — the class the old uppercase +
# required-hyphen regex missed. Built at runtime so this source carries no
# contiguous trip-shape.
$ccQueLc = 'qu' + 'e'
$ccQlc = Join-Path $CC_TMP 'qlc'; New-Item -ItemType Directory -Path $ccQlc -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccQlc 'a.md') -Value "stale skill named ${ccQueLc}107-stale here"
Assert-Exit 'lowercase no-hyphen issue-ID (que<NN>) FAILS' 1 -- pwsh -NoProfile -File $CC_SUT $ccQlc

# Boundary: ordinary words ending in "que" + digits (unique/opaque/technique class)
# must NOT trip this fail-closed gate — the lowercase arm requires a left boundary.
# Assembled at runtime so this source carries no contiguous trip-shape.
$ccOk = Join-Path $CC_TMP 'ok'; New-Item -ItemType Directory -Path $ccOk -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccOk 'a.md') -Value "uni${ccQueLc}100 opa${ccQueLc}22 techni${ccQueLc}5 here"
Assert-Exit "benign words ending in 'que'+digits do NOT trip (word boundary)" 0 -- pwsh -NoProfile -File $CC_SUT $ccOk

$ccP = Join-Path $CC_TMP 'p'; New-Item -ItemType Directory -Path $ccP -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccP 'a.md') -Value "path /$CC_USERS/realperson/x"
Assert-Exit 'home-path alone FAILS' 1 -- pwsh -NoProfile -File $CC_SUT $ccP

$ccE = Join-Path $CC_TMP 'e'; New-Item -ItemType Directory -Path $ccE -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccE 'a.md') -Value "write person${CC_AT}real-domain.net"
Assert-Exit 'real email alone FAILS' 1 -- pwsh -NoProfile -File $CC_SUT $ccE

# --- CLEAN fixture: placeholders + allowed domains + plain prose --------------
$ccClean = Join-Path $CC_TMP 'clean'; New-Item -ItemType Directory -Path $ccClean -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccClean 'paths.md')   -Value "home is /$CC_USERS/<name>/ or /$CC_HOME/`$USER/ — fill in your own"
Set-Content -LiteralPath (Join-Path $ccClean 'contact.md') -Value "example contact you${CC_AT}example.com or bot${CC_AT}users.noreply.github.com"
Set-Content -LiteralPath (Join-Path $ccClean 'readme.md')  -Value "a perfectly ordinary sentence with nothing to hide"

Assert-Exit 'check-clean PASSES on a clean tree (placeholders + allowed domains)' 0 -- pwsh -NoProfile -File $CC_SUT $ccClean

# --- Operator-token layer (component-split aware) -----------------------------
$ccTok = Join-Path $CC_TMP 'tok'; New-Item -ItemType Directory -Path $ccTok -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccTok 'note.md') -Value "a note mentioning Zubble in passing"

Remove-Item Env:\OPERATOR_PII_TOKENS -ErrorAction SilentlyContinue
Assert-Exit 'token-only tree PASSES when no tokens configured (CI case)' 0 -- pwsh -NoProfile -File $CC_SUT $ccTok

$env:OPERATOR_PII_TOKENS = 'Zubble,Wozzle'
Assert-Exit 'operator token FAILS when configured (component-split)' 1 -- pwsh -NoProfile -File $CC_SUT $ccTok
Remove-Item Env:\OPERATOR_PII_TOKENS -ErrorAction SilentlyContinue

# Case-insensitive token match.
$ccTokCi = Join-Path $CC_TMP 'tokci'; New-Item -ItemType Directory -Path $ccTokCi -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccTokCi 'note.md') -Value "lowercase mention of zubble here"
$env:OPERATOR_PII_TOKENS = 'Zubble'
Assert-Exit 'operator token match is case-insensitive' 1 -- pwsh -NoProfile -File $CC_SUT $ccTokCi
Remove-Item Env:\OPERATOR_PII_TOKENS -ErrorAction SilentlyContinue

# --- local.env sourcing -------------------------------------------------------
$ccLenv = Join-Path $CC_TMP 'lenv'; New-Item -ItemType Directory -Path $ccLenv -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccLenv 'note.md')   -Value "a note mentioning Zubble in passing"
Set-Content -LiteralPath (Join-Path $ccLenv 'local.env') -Value 'OPERATOR_PII_TOKENS="Zubble,Wozzle"'
Remove-Item Env:\OPERATOR_PII_TOKENS -ErrorAction SilentlyContinue
Assert-Exit 'tokens are read from the target local.env when not exported' 1 -- pwsh -NoProfile -File $CC_SUT $ccLenv

# --- Cross-model review hardening (Codex adversarial pass) ---------------------
# HIGH-2: JSON/source-escaped Windows path (C:\\Users\\name) is caught.
$ccWin = Join-Path $CC_TMP 'win'; New-Item -ItemType Directory -Path $ccWin -Force | Out-Null
$CC_DBS = '\' + '\'
Set-Content -LiteralPath (Join-Path $ccWin 'w.json') -Value ("cache C:" + $CC_DBS + $CC_USERS + $CC_DBS + "realdev" + $CC_DBS + "AppData")
Assert-Exit 'escaped Windows backslash path FAILS (HIGH-2)' 1 -- pwsh -NoProfile -File $CC_SUT $ccWin

# HIGH-3: an allowed domain that is only a PREFIX of a real domain must FAIL.
$ccEb = Join-Path $CC_TMP 'ebypass'; New-Item -ItemType Directory -Path $ccEb -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccEb 'a.md') -Value ("bot" + $CC_AT + "users.noreply.github.com.attacker.net here")
Assert-Exit 'allowed-domain prefix bypass FAILS (HIGH-3 exact-domain)' 1 -- pwsh -NoProfile -File $CC_SUT $ccEb

# MED-1: CRLF + inline-comment local.env still yields the token.
$ccCrlf = Join-Path $CC_TMP 'crlf'; New-Item -ItemType Directory -Path $ccCrlf -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccCrlf 'n.md') -Value "a note mentioning Zubble"
[System.IO.File]::WriteAllText((Join-Path $ccCrlf 'local.env'), "OPERATOR_PII_TOKENS=`"Zubble`" # my tokens`r`n")
Remove-Item Env:\OPERATOR_PII_TOKENS -ErrorAction SilentlyContinue
Assert-Exit 'CRLF + inline-comment local.env still reads the token (MED-1)' 1 -- pwsh -NoProfile -File $CC_SUT $ccCrlf

# MED-2: a multi-word token catches a single component.
$ccSplit = Join-Path $CC_TMP 'split'; New-Item -ItemType Directory -Path $ccSplit -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ccSplit 'm.md') -Value "meeting with Jane about the deal"
$env:OPERATOR_PII_TOKENS = 'Jane Doe'
Assert-Exit 'multi-word token catches one component (MED-2)' 1 -- pwsh -NoProfile -File $CC_SUT $ccSplit
Remove-Item Env:\OPERATOR_PII_TOKENS -ErrorAction SilentlyContinue

# HIGH-1 (partial): a git-tracked local.env is itself a leak.
$ccGit = Join-Path $CC_TMP 'gitrepo'; New-Item -ItemType Directory -Path $ccGit -Force | Out-Null
Push-Location $ccGit
& git init -q *>$null
Set-Content -LiteralPath (Join-Path $ccGit 'local.env') -Value 'CLAUDE_CONFIG_DIR=x'
& git add local.env *>$null
Pop-Location
Assert-Exit 'a git-tracked local.env is flagged (HIGH-1)' 1 -- pwsh -NoProfile -File $CC_SUT $ccGit

# --- deferred adversarial findings (git ls-files enumeration) ---------
# The shared root is enumerate-tracked-blobs instead of a recursive,
# basename-excluded Get-ChildItem scan. Sentinels stay runtime-built from
# non-matching halves so this source never self-trips the guard.

# HIGH-1 (full): a committed file sharing the guard's BASENAME at a NON-self
# path must still be scanned. Old per-Name HashSet excluded the basename
# anywhere; exact repo-relative self-exclusion scans it.
$ccBn = Join-Path $CC_TMP 'basename'; New-Item -ItemType Directory -Path (Join-Path $ccBn 'docs') -Force | Out-Null
& git -C $ccBn init -q *>$null
[System.IO.File]::WriteAllText((Join-Path $ccBn 'docs/check-clean.ps1'), "# decoy, not the real guard`ntracked under ${CC_QUE}-9 here`n")
& git -C $ccBn add -A *>$null
Assert-Exit 'committed docs/check-clean.ps1 leak FAILS (HIGH-1 basename bypass)' 1 -- pwsh -NoProfile -File $CC_SUT $ccBn

# HIGH-5: a UTF-16LE (no BOM) tracked file carrying a leak must FAIL. The old
# ReadLines (UTF-8) saw the NUL-separated bytes as non-contiguous; the fix
# reads bytes and strips NUL before scanning.
$ccU16 = Join-Path $CC_TMP 'utf16'; New-Item -ItemType Directory -Path $ccU16 -Force | Out-Null
& git -C $ccU16 init -q *>$null
$u16enc = [System.Text.UnicodeEncoding]::new($false, $false)   # little-endian, no BOM
[System.IO.File]::WriteAllText((Join-Path $ccU16 'notes.txt'), ($CC_QUE + '-5'), $u16enc)
& git -C $ccU16 add -A *>$null
Assert-Exit 'UTF-16 (no BOM) tracked leak FAILS (HIGH-5 binary fail-closed)' 1 -- pwsh -NoProfile -File $CC_SUT $ccU16

# HIGH-5: an unreadable tracked file must FAIL closed (old catch{} swallowed
# the read error and continued). POSIX 000 mode only — skipped on Windows.
$ccUnr = Join-Path $CC_TMP 'unreadable'; New-Item -ItemType Directory -Path $ccUnr -Force | Out-Null
& git -C $ccUnr init -q *>$null
$unrFile = Join-Path $ccUnr 'blob.bin'
[System.IO.File]::WriteAllText($unrFile, "benign placeholder line`n")
& git -C $ccUnr add -A *>$null
if ($IsWindows) {
    _Skip 'unreadable tracked file FAILS closed (HIGH-5)' 'POSIX 000 mode not applicable on Windows'
} else {
    & chmod 000 $unrFile *>$null
    $canRead = $true
    try { [void][System.IO.File]::ReadAllBytes($unrFile) } catch { $canRead = $false }
    if ($canRead) {
        _Skip 'unreadable tracked file FAILS closed (HIGH-5)' 'host reads 000 files (root?)'
    } else {
        Assert-Exit 'unreadable tracked file FAILS closed (HIGH-5)' 1 -- pwsh -NoProfile -File $CC_SUT $ccUnr
    }
    & chmod 644 $unrFile *>$null
}

# HIGH-4: a high-signal token split across a hard line-wrap must FAIL. The old
# line-by-line scan never saw QUE-\n123 / realdev@\nacme as one token.
$ccMl = Join-Path $CC_TMP 'multiline'; New-Item -ItemType Directory -Path $ccMl -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $ccMl 'wrap.md'), "see ${CC_QUE}-`n123 for context`n")
Assert-Exit 'multi-line split issue-ID FAILS (HIGH-4)' 1 -- pwsh -NoProfile -File $CC_SUT $ccMl

$ccMle = Join-Path $CC_TMP 'multiline-email'; New-Item -ItemType Directory -Path $ccMle -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $ccMle 'w.md'), "contact realdev${CC_AT}`nacme-corp.io soon`n")
Assert-Exit 'multi-line split email FAILS (HIGH-4 email)' 1 -- pwsh -NoProfile -File $CC_SUT $ccMle

# MED-symlink: a tracked symlink whose TARGET text is a home path must FAIL.
# The old recursive scan never read the link target.
$ccSym = Join-Path $CC_TMP 'symlink'; New-Item -ItemType Directory -Path $ccSym -Force | Out-Null
& git -C $ccSym init -q *>$null
$symTarget = "/$CC_USERS/realdev/secret"
$symMade = $true
try { New-Item -ItemType SymbolicLink -Path (Join-Path $ccSym 'link') -Target $symTarget -ErrorAction Stop | Out-Null }
catch { $symMade = $false }
if ($symMade) {
    & git -C $ccSym add -A *>$null
    Assert-Exit 'tracked symlink target home-path FAILS (MED-symlink)' 1 -- pwsh -NoProfile -File $CC_SUT $ccSym
} else {
    _Skip 'tracked symlink target home-path FAILS (MED-symlink)' 'symlink creation unsupported (privilege?)'
}

# Regression guard: a CLEAN git tree (placeholders + allowed domains) still
# PASSES under git enumeration — no false positives from the blob/multi-line
# passes.
$ccGClean = Join-Path $CC_TMP 'gitclean'; New-Item -ItemType Directory -Path $ccGClean -Force | Out-Null
& git -C $ccGClean init -q *>$null
[System.IO.File]::WriteAllText((Join-Path $ccGClean 'readme.md'), "home is /$CC_USERS/<name>/ — fill in your own`ncontact you${CC_AT}example.com anytime`n")
& git -C $ccGClean add -A *>$null
Assert-Exit 'clean git tree PASSES under git-enumeration (no FP)' 0 -- pwsh -NoProfile -File $CC_SUT $ccGClean

# --- hardening from the Codex forced adversarial pass ---------

# F2: an operator token split across a hard line-wrap must FAIL — the multi-line
# pass must cover tokens too, not only structural patterns. The token is a
# runtime-built fake ("Zubble"+"wozzle") so this source carries no real operator
# handle and does not self-trip the repo PII scans.
$ccTokMl = Join-Path $CC_TMP 'token-multiline'; New-Item -ItemType Directory -Path $ccTokMl -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $ccTokMl 'n.md'), "see Zubble`nwozzle notes`n")
$env:OPERATOR_PII_TOKENS = 'Zubblewozzle'
Assert-Exit 'operator token split across a wrap FAILS (F2 multi-line tokens)' 1 -- pwsh -NoProfile -File $CC_SUT $ccTokMl
Remove-Item Env:\OPERATOR_PII_TOKENS -ErrorAction SilentlyContinue

# F3: a Windows home path escaped with MORE than two backslashes (a JSON string
# nested inside a source string) must still FAIL.
$ccW4 = Join-Path $CC_TMP 'win4'; New-Item -ItemType Directory -Path $ccW4 -Force | Out-Null
$CC_QBS = '\' + '\' + '\' + '\'   # four literal backslashes
[System.IO.File]::WriteAllText((Join-Path $ccW4 'w.json'), ("path C:" + $CC_QBS + $CC_USERS + $CC_QBS + "realdev" + $CC_QBS + ".ssh"))
Assert-Exit '4-backslash Windows home path FAILS (F3 nested escape)' 1 -- pwsh -NoProfile -File $CC_SUT $ccW4

# F4: in filesystem (non-git) mode a present local.env carrying a leak must FAIL
# — the tracked-file check is git-only, leaving a fs-mode gap.
$ccFsLenv = Join-Path $CC_TMP 'fs-lenv'; New-Item -ItemType Directory -Path $ccFsLenv -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $ccFsLenv 'local.env'), "OPERATOR_PII_TOKENS=`"Zubble`"`nNOTE=/$CC_USERS/realdev/secret`n")
Remove-Item Env:\OPERATOR_PII_TOKENS -ErrorAction SilentlyContinue
Assert-Exit 'fs-mode leaky local.env FAILS (F4 git/fs gap)' 1 -- pwsh -NoProfile -File $CC_SUT $ccFsLenv

# F6: a case-varied excluded-dir name (Cross-Model-Out vs cross-model-out) must
# still be scanned — exclusion is case-SENSITIVE, matching the bash globs.
$ccCaseDir = Join-Path $CC_TMP 'casedir'; New-Item -ItemType Directory -Path (Join-Path $ccCaseDir 'Cross-Model-Out') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $ccCaseDir 'Cross-Model-Out/leak.md'), "tracked under ${CC_QUE}-6 here`n")
Assert-Exit 'case-varied excluded dir is still scanned (F6 case-sensitive exclusion)' 1 -- pwsh -NoProfile -File $CC_SUT $ccCaseDir

# F1: a tracked file with a non-ASCII name carrying a leak must FAIL — robust
# NUL-delimited enumeration, no path-quoting bypass or spurious skip.
$ccUni = Join-Path $CC_TMP 'unicode'; New-Item -ItemType Directory -Path $ccUni -Force | Out-Null
& git -C $ccUni init -q *>$null
[System.IO.File]::WriteAllText((Join-Path $ccUni 'café.md'), "tracked under ${CC_QUE}-1 here`n")
& git -C $ccUni add -A *>$null
Assert-Exit 'tracked non-ASCII filename leak FAILS (F1 -z enumeration)' 1 -- pwsh -NoProfile -File $CC_SUT $ccUni

# --- Commit-metadata identity check (opt-in via COMMIT_IDENTITY_ALLOWLIST) ----
# Twin of the bash commit-identity block. Content scans cannot see commit
# metadata; identities are runtime-built (allowed email domain) so this source
# carries no real identity and no contiguous email shape.
$CC_BOT_NAME = 'Bot Fixture'
$CC_BOT_MAIL = "bot${CC_AT}example.com"
$CC_BOT_ID = "$CC_BOT_NAME <$CC_BOT_MAIL>"
$CC_ROGUE_NAME = 'Real Dev'
$CC_ROGUE_MAIL = "real.dev${CC_AT}acme-corp.io"
Remove-Item Env:\COMMIT_IDENTITY_ALLOWLIST -ErrorAction SilentlyContinue

# Bot-only commits + allowlist => PASS, and the PASS line reports coverage.
$ccIdOk = Join-Path $CC_TMP 'id-ok'; New-Item -ItemType Directory -Path $ccIdOk -Force | Out-Null
& git -C $ccIdOk init -q *>$null
Set-Content -LiteralPath (Join-Path $ccIdOk 'a.md') -Value 'clean prose'
& git -C $ccIdOk add -A *>$null
& git -C $ccIdOk -c user.name="$CC_BOT_NAME" -c user.email="$CC_BOT_MAIL" commit -qm one *>$null
$env:COMMIT_IDENTITY_ALLOWLIST = $CC_BOT_ID
try {
    Assert-Exit 'commit-identity: bot-only branch PASSES with allowlist' 0 -- pwsh -NoProfile -File $CC_SUT $ccIdOk
    $ccIdOkOut = (& pwsh -NoProfile -File $CC_SUT $ccIdOk 2>&1 | Out-String)
    Assert-Contains 'commit-identity: PASS line reports checked count' $ccIdOkOut '1 branch commit(s) identity-checked'

    # Rogue author+committer => FAIL naming both fields.
    $ccIdBad = Join-Path $CC_TMP 'id-bad'; New-Item -ItemType Directory -Path $ccIdBad -Force | Out-Null
    & git -C $ccIdBad init -q *>$null
    Set-Content -LiteralPath (Join-Path $ccIdBad 'a.md') -Value 'clean prose'
    & git -C $ccIdBad add -A *>$null
    & git -C $ccIdBad -c user.name="$CC_ROGUE_NAME" -c user.email="$CC_ROGUE_MAIL" commit -qm one *>$null
    Assert-Exit 'commit-identity: rogue identity FAILS' 1 -- pwsh -NoProfile -File $CC_SUT $ccIdBad
    $ccIdBadOut = (& pwsh -NoProfile -File $CC_SUT $ccIdBad 2>&1 | Out-String)
    Assert-Contains 'commit-identity: FAIL names the author field' $ccIdBadOut 'author not allowlisted'
    Assert-Contains 'commit-identity: FAIL names the committer field' $ccIdBadOut 'committer not allowlisted'

    # Allowed author but rogue COMMITTER => still FAILS.
    $ccIdCom = Join-Path $CC_TMP 'id-committer'; New-Item -ItemType Directory -Path $ccIdCom -Force | Out-Null
    & git -C $ccIdCom init -q *>$null
    Set-Content -LiteralPath (Join-Path $ccIdCom 'a.md') -Value 'clean prose'
    & git -C $ccIdCom add -A *>$null
    & git -C $ccIdCom -c user.name="$CC_ROGUE_NAME" -c user.email="$CC_ROGUE_MAIL" commit -qm one --author="$CC_BOT_ID" *>$null
    $ccIdComOut = (& pwsh -NoProfile -File $CC_SUT $ccIdCom 2>&1 | Out-String)
    $ccIdComRc = $LASTEXITCODE
    Assert-Eq 'commit-identity: rogue committer behind allowed author FAILS' '1' "$ccIdComRc"
    Assert-Contains 'commit-identity: committer-only leak names the committer' $ccIdComOut 'committer not allowlisted'
    Assert-NotContains 'commit-identity: allowed author is not flagged' $ccIdComOut 'author not allowlisted'

    # Set-but-empty-after-parsing allowlist is a misconfiguration => fail-closed.
    $env:COMMIT_IDENTITY_ALLOWLIST = ' , '
    Assert-Exit 'commit-identity: empty-parse allowlist FAILS closed' 1 -- pwsh -NoProfile -File $CC_SUT $ccIdOk
    $env:COMMIT_IDENTITY_ALLOWLIST = $CC_BOT_ID

    # Range scoping: rogue commit BELOW the default-branch ref is published
    # history; only ahead-of-base commits are checked => bot-only ahead PASSES.
    $ccIdRange = Join-Path $CC_TMP 'id-range'; New-Item -ItemType Directory -Path $ccIdRange -Force | Out-Null
    & git -C $ccIdRange init -q *>$null
    Set-Content -LiteralPath (Join-Path $ccIdRange 'a.md') -Value 'clean prose'
    & git -C $ccIdRange add -A *>$null
    & git -C $ccIdRange -c user.name="$CC_ROGUE_NAME" -c user.email="$CC_ROGUE_MAIL" commit -qm old *>$null
    & git -C $ccIdRange update-ref refs/remotes/origin/main HEAD *>$null
    Set-Content -LiteralPath (Join-Path $ccIdRange 'b.md') -Value 'more clean prose'
    & git -C $ccIdRange add -A *>$null
    & git -C $ccIdRange -c user.name="$CC_BOT_NAME" -c user.email="$CC_BOT_MAIL" commit -qm new *>$null
    $ccIdRangeOut = (& pwsh -NoProfile -File $CC_SUT $ccIdRange 2>&1 | Out-String)
    $ccIdRangeRc = $LASTEXITCODE
    Assert-Eq 'commit-identity: only ahead-of-default commits are checked' '0' "$ccIdRangeRc"
    Assert-Contains 'commit-identity: range-scoped run reports 1 checked' $ccIdRangeOut '1 branch commit(s) identity-checked'
} finally {
    Remove-Item Env:\COMMIT_IDENTITY_ALLOWLIST -ErrorAction SilentlyContinue
}

# Allowlist UNSET => documented no-op even on the rogue repo, and the PASS line
# says so (coverage is never silently overstated).
$ccIdSkipOut = (& pwsh -NoProfile -File $CC_SUT (Join-Path $CC_TMP 'id-bad') 2>&1 | Out-String)
$ccIdSkipRc = $LASTEXITCODE
Assert-Eq 'commit-identity: unset allowlist is a no-op (exit 0)' '0' "$ccIdSkipRc"
Assert-Contains 'commit-identity: skip is reported on the PASS line' $ccIdSkipOut 'commit-identity check skipped'

# Allowlist read from the target's gitignored local.env (env unset).
[System.IO.File]::WriteAllText((Join-Path $CC_TMP 'id-bad/local.env'), "COMMIT_IDENTITY_ALLOWLIST=`"$CC_BOT_ID`"`n")
$ccIdLenvOut = (& pwsh -NoProfile -File $CC_SUT (Join-Path $CC_TMP 'id-bad') 2>&1 | Out-String)
$ccIdLenvRc = $LASTEXITCODE
Assert-Eq 'commit-identity: allowlist picked up from target local.env' '1' "$ccIdLenvRc"
Assert-Contains 'commit-identity: local.env-sourced check flags the rogue commit' $ccIdLenvOut 'author not allowlisted'

# Adversarial regression: a local TAG named origin/main resolves BEFORE the
# remote-tracking ref (gitrevisions order) — with bare refnames it would shadow
# the no-base fallback and empty the range. Full refs/remotes/ names are
# immune: the remoteless rogue repo is still fully checked and FAILS.
$env:COMMIT_IDENTITY_ALLOWLIST = $CC_BOT_ID
try {
    $ccIdTag = Join-Path $CC_TMP 'id-tagshadow'; New-Item -ItemType Directory -Path $ccIdTag -Force | Out-Null
    & git -C $ccIdTag init -q *>$null
    Set-Content -LiteralPath (Join-Path $ccIdTag 'a.md') -Value 'clean prose'
    & git -C $ccIdTag add -A *>$null
    & git -C $ccIdTag -c user.name="$CC_ROGUE_NAME" -c user.email="$CC_ROGUE_MAIL" commit -qm one *>$null
    & git -C $ccIdTag tag origin/main *>$null
    Assert-Exit 'commit-identity: tag named origin/main cannot shadow the fallback range' 1 -- pwsh -NoProfile -File $CC_SUT $ccIdTag

    # Adversarial regression: the no-commits skip is benign ONLY for an unborn
    # repo (zero commits anywhere) — that path passes with the explicit note.
    $ccIdUnborn = Join-Path $CC_TMP 'id-unborn'; New-Item -ItemType Directory -Path $ccIdUnborn -Force | Out-Null
    & git -C $ccIdUnborn init -q *>$null
    $ccIdUnbornOut = (& pwsh -NoProfile -File $CC_SUT $ccIdUnborn 2>&1 | Out-String)
    $ccIdUnbornRc = $LASTEXITCODE
    Assert-Eq 'commit-identity: unborn repo passes with the no-commits note' '0' "$ccIdUnbornRc"
    Assert-Contains 'commit-identity: unborn repo names the no-commits path' $ccIdUnbornOut 'no commits to check'
} finally {
    Remove-Item Env:\COMMIT_IDENTITY_ALLOWLIST -ErrorAction SilentlyContinue
}

# --- Commit-MESSAGE scan -------------------------------------------------------
# Twin of the bash commit-message block. The live incident: a lowercase
# tracker-ID fragment in a commit MESSAGE body passed the guard (tree scan sees
# files at HEAD; identity check sees author/committer fields) and was stopped
# only by a manual format-patch sweep. Same ahead-of-default range as the
# identity check. Sentinels are runtime-built like every other trip-shape here.
$ccQueUp = 'QU' + 'E'

# RED: a lowercase hyphenated ID in the message BODY fails, naming the commit.
$ccMsg = Join-Path $CC_TMP 'msg-red'; New-Item -ItemType Directory -Path $ccMsg -Force | Out-Null
& git -C $ccMsg init -q *>$null
Set-Content -LiteralPath (Join-Path $ccMsg 'a.md') -Value 'clean prose'
& git -C $ccMsg add -A *>$null
& git -C $ccMsg -c user.name="$CC_BOT_NAME" -c user.email="$CC_BOT_MAIL" commit -qm 'fix path' -m "moved the ${ccQueLc}-123 fragment out of docs" *>$null
$ccMsgOut = (& pwsh -NoProfile -File $CC_SUT $ccMsg 2>&1 | Out-String)
$ccMsgRc = $LASTEXITCODE
Assert-Eq 'commit-message: lowercase ID in a message body FAILS' '1' "$ccMsgRc"
Assert-Contains 'commit-message: the report names the class and the commit' `
    $ccMsgOut 'tracker issue ID found in commit message'
Assert-Contains 'commit-message: the hit line carries the commit' $ccMsgOut 'commit '

# Separator tolerance: a spaced reference in the SUBJECT fails too.
$ccMsgSp = Join-Path $CC_TMP 'msg-space'; New-Item -ItemType Directory -Path $ccMsgSp -Force | Out-Null
& git -C $ccMsgSp init -q *>$null
Set-Content -LiteralPath (Join-Path $ccMsgSp 'a.md') -Value 'clean prose'
& git -C $ccMsgSp add -A *>$null
& git -C $ccMsgSp -c user.name="$CC_BOT_NAME" -c user.email="$CC_BOT_MAIL" commit -qm "see $ccQueUp 77 for context" *>$null
Assert-Exit 'commit-message: space-separated ID (PREFIX 77) FAILS' 1 -- pwsh -NoProfile -File $CC_SUT $ccMsgSp
$ccMsgUs = Join-Path $CC_TMP 'msg-underscore'; New-Item -ItemType Directory -Path $ccMsgUs -Force | Out-Null
& git -C $ccMsgUs init -q *>$null
Set-Content -LiteralPath (Join-Path $ccMsgUs 'a.md') -Value 'clean prose'
& git -C $ccMsgUs add -A *>$null
& git -C $ccMsgUs -c user.name="$CC_BOT_NAME" -c user.email="$CC_BOT_MAIL" commit -qm "rename ${ccQueLc}_9 helper" *>$null
Assert-Exit 'commit-message: underscore-separated lowercase ID FAILS' 1 -- pwsh -NoProfile -File $CC_SUT $ccMsgUs

# RESTRAINT: prose words ending in the lowercase prefix + digits stay clean —
# and the PASS line proves the scan RAN (a quiet scan that never executed would
# make this assertion vacuous).
$ccMsgOk = Join-Path $CC_TMP 'msg-ok'; New-Item -ItemType Directory -Path $ccMsgOk -Force | Out-Null
& git -C $ccMsgOk init -q *>$null
Set-Content -LiteralPath (Join-Path $ccMsgOk 'a.md') -Value 'clean prose'
& git -C $ccMsgOk add -A *>$null
& git -C $ccMsgOk -c user.name="$CC_BOT_NAME" -c user.email="$CC_BOT_MAIL" commit -qm 'restraint check' -m "a question 42 about the queue 7 and an anti${ccQueLc} 55 remain" *>$null
$ccMsgOkOut = (& pwsh -NoProfile -File $CC_SUT $ccMsgOk 2>&1 | Out-String)
$ccMsgOkRc = $LASTEXITCODE
Assert-Eq 'commit-message: benign question/queue/antique prose PASSES (restraint)' '0' "$ccMsgOkRc"
Assert-Contains 'commit-message: the PASS line proves the scan ran (count reported)' `
    $ccMsgOkOut '1 branch commit(s) message-scanned'

# Range scoping: a leaky message BELOW the default-branch ref is published
# history; only ahead-of-base commits are scanned.
$ccMsgRange = Join-Path $CC_TMP 'msg-range'; New-Item -ItemType Directory -Path $ccMsgRange -Force | Out-Null
& git -C $ccMsgRange init -q *>$null
Set-Content -LiteralPath (Join-Path $ccMsgRange 'a.md') -Value 'clean prose'
& git -C $ccMsgRange add -A *>$null
& git -C $ccMsgRange -c user.name="$CC_BOT_NAME" -c user.email="$CC_BOT_MAIL" commit -qm "old ${ccQueLc}-500 reference" *>$null
& git -C $ccMsgRange update-ref refs/remotes/origin/main HEAD *>$null
Set-Content -LiteralPath (Join-Path $ccMsgRange 'b.md') -Value 'more clean prose'
& git -C $ccMsgRange add -A *>$null
& git -C $ccMsgRange -c user.name="$CC_BOT_NAME" -c user.email="$CC_BOT_MAIL" commit -qm 'new clean work' *>$null
$ccMsgRangeOut = (& pwsh -NoProfile -File $CC_SUT $ccMsgRange 2>&1 | Out-String)
$ccMsgRangeRc = $LASTEXITCODE
Assert-Eq 'commit-message: only ahead-of-default messages are scanned' '0' "$ccMsgRangeRc"
Assert-Contains 'commit-message: range-scoped run reports 1 scanned' `
    $ccMsgRangeOut '1 branch commit(s) message-scanned'

# Operator tokens are scanned in messages too (case-insensitive), same opt-in
# as the tree scan.
$ccMsgTok = Join-Path $CC_TMP 'msg-tok'; New-Item -ItemType Directory -Path $ccMsgTok -Force | Out-Null
& git -C $ccMsgTok init -q *>$null
Set-Content -LiteralPath (Join-Path $ccMsgTok 'a.md') -Value 'clean prose'
& git -C $ccMsgTok add -A *>$null
& git -C $ccMsgTok -c user.name="$CC_BOT_NAME" -c user.email="$CC_BOT_MAIL" commit -qm "tested on zubble's machine" *>$null
$env:OPERATOR_PII_TOKENS = 'Zubble'
try {
    Assert-Exit 'commit-message: operator token in a message FAILS when configured' 1 -- pwsh -NoProfile -File $CC_SUT $ccMsgTok
} finally {
    Remove-Item Env:\OPERATOR_PII_TOKENS -ErrorAction SilentlyContinue
}
Assert-Exit 'commit-message: token-only message PASSES when no tokens configured (CI case)' 0 -- pwsh -NoProfile -File $CC_SUT $ccMsgTok

# RESTRAINT (panel-confirmed false positive, fixture-pinned): ALL-CAPS prose
# carries uppercase prefix letters mid-word ("UNIQUE 1 constraint"), so the
# whitespace arm must be left-boundary anchored on BOTH prefix arms.
$ccMsgCaps = Join-Path $CC_TMP 'msg-caps'; New-Item -ItemType Directory -Path $ccMsgCaps -Force | Out-Null
& git -C $ccMsgCaps init -q *>$null
Set-Content -LiteralPath (Join-Path $ccMsgCaps 'a.md') -Value 'clean prose'
& git -C $ccMsgCaps add -A *>$null
& git -C $ccMsgCaps -c user.name="$CC_BOT_NAME" -c user.email="$CC_BOT_MAIL" commit -qm "enforce UNI$ccQueUp 1 constraint and TECHNI$ccQueUp 2 pass" *>$null
Assert-Exit 'commit-message: ALL-CAPS prose (UNIQUE 1 / TECHNIQUE 2) PASSES (restraint)' 0 -- pwsh -NoProfile -File $CC_SUT $ccMsgCaps

# Bypass hardening (panel-confirmed): 2+ blanks or a tab between prefix and
# digits is the same leak — the whitespace arm accepts 1+ blanks.
$ccMsgDbl = Join-Path $CC_TMP 'msg-dblspace'; New-Item -ItemType Directory -Path $ccMsgDbl -Force | Out-Null
& git -C $ccMsgDbl init -q *>$null
Set-Content -LiteralPath (Join-Path $ccMsgDbl 'a.md') -Value 'clean prose'
& git -C $ccMsgDbl add -A *>$null
& git -C $ccMsgDbl -c user.name="$CC_BOT_NAME" -c user.email="$CC_BOT_MAIL" commit -qm "see $ccQueUp  548 double-space ref" *>$null
Assert-Exit 'commit-message: double-space-separated ID still FAILS' 1 -- pwsh -NoProfile -File $CC_SUT $ccMsgDbl
$ccMsgTab = Join-Path $CC_TMP 'msg-tab'; New-Item -ItemType Directory -Path $ccMsgTab -Force | Out-Null
& git -C $ccMsgTab init -q *>$null
Set-Content -LiteralPath (Join-Path $ccMsgTab 'a.md') -Value 'clean prose'
& git -C $ccMsgTab add -A *>$null
& git -C $ccMsgTab -c user.name="$CC_BOT_NAME" -c user.email="$CC_BOT_MAIL" commit -qm "ref ${ccQueLc}`t548 tab sep" *>$null
Assert-Exit 'commit-message: tab-separated lowercase ID still FAILS' 1 -- pwsh -NoProfile -File $CC_SUT $ccMsgTab

# --- Tracker-prefix configurability (TRACKER_ISSUE_PREFIX) ---------------------
# The issue-ID scan derives from the configured prefix set; unset keeps the
# historical QUE default (proven by the fixtures above). Prefix sentinels are
# runtime-built from halves like every other trip-shape in this file.
$CC_ABC = 'AB' + 'C'
$CC_OPS = 'OP' + 'S'
$ccAbcLc = 'ab' + 'c'
Remove-Item Env:\TRACKER_ISSUE_PREFIX -ErrorAction SilentlyContinue
try {
    # A configured non-default prefix is caught, and the report names it.
    $ccPfx = Join-Path $CC_TMP 'pfx'; New-Item -ItemType Directory -Path $ccPfx -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ccPfx 'a.md') -Value "tracked under ${CC_ABC}-123 for follow-up"
    $env:TRACKER_ISSUE_PREFIX = $CC_ABC
    $ccPfxOut = (& pwsh -NoProfile -File $CC_SUT $ccPfx 2>&1 | Out-String)
    $ccPfxRc = $LASTEXITCODE
    Assert-Eq 'configured prefix issue-ID FAILS' '1' "$ccPfxRc"
    Assert-Contains 'configured-prefix report names the prefix' $ccPfxOut "(${CC_ABC}-<n>)"
    # The same tree passes an UNCONFIGURED run (QUE default) — the documented
    # contract: the guard defends exactly the prefixes it is told about.
    Remove-Item Env:\TRACKER_ISSUE_PREFIX -ErrorAction SilentlyContinue
    Assert-Exit 'non-default prefix passes when unconfigured (QUE default)' 0 -- pwsh -NoProfile -File $CC_SUT $ccPfx

    # Multi-prefix: every configured key is scanned and named.
    $ccPfx2 = Join-Path $CC_TMP 'pfx2'; New-Item -ItemType Directory -Path $ccPfx2 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ccPfx2 'a.md') -Value "see ${CC_OPS}-7 here"
    Set-Content -LiteralPath (Join-Path $ccPfx2 'b.md') -Value "and ${CC_ABC}-9 there"
    $env:TRACKER_ISSUE_PREFIX = "$CC_ABC,$CC_OPS"
    $ccPfx2Out = (& pwsh -NoProfile -File $CC_SUT $ccPfx2 2>&1 | Out-String)
    $ccPfx2Rc = $LASTEXITCODE
    Assert-Eq 'multi-prefix: both configured keys are scanned (FAIL)' '1' "$ccPfx2Rc"
    Assert-Contains 'multi-prefix: first key named' $ccPfx2Out "(${CC_ABC}-<n>)"
    Assert-Contains 'multi-prefix: second key named' $ccPfx2Out "(${CC_OPS}-<n>)"

    # Derived-pattern semantics carry over: lowercase no-hyphen at a boundary
    # trips; a lowercase occurrence embedded inside a word does not.
    $ccPfxLc = Join-Path $CC_TMP 'pfxlc'; New-Item -ItemType Directory -Path $ccPfxLc -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ccPfxLc 'a.md') -Value "stale ref ${ccAbcLc}42 here"
    $env:TRACKER_ISSUE_PREFIX = $CC_ABC
    Assert-Exit 'lowercase no-hyphen (<prefix><NN>) FAILS for a configured prefix' 1 -- pwsh -NoProfile -File $CC_SUT $ccPfxLc
    $ccPfxB = Join-Path $CC_TMP 'pfxb'; New-Item -ItemType Directory -Path $ccPfxB -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ccPfxB 'a.md') -Value "word f${ccAbcLc}123 embedded here"
    Assert-Exit 'embedded lowercase prefix does NOT trip (boundary preserved)' 0 -- pwsh -NoProfile -File $CC_SUT $ccPfxB

    # Prefix read from the target's gitignored local.env when not exported.
    Remove-Item Env:\TRACKER_ISSUE_PREFIX -ErrorAction SilentlyContinue
    $ccPfxLenv = Join-Path $CC_TMP 'pfx-lenv'; New-Item -ItemType Directory -Path $ccPfxLenv -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ccPfxLenv 'a.md') -Value "see ${CC_ABC}-11 here"
    Set-Content -LiteralPath (Join-Path $ccPfxLenv 'local.env') -Value "TRACKER_ISSUE_PREFIX=`"$CC_ABC`""
    Assert-Exit 'prefix read from the target local.env when not exported' 1 -- pwsh -NoProfile -File $CC_SUT $ccPfxLenv

    # TEAM is the reserved documentation placeholder. Lock the exact contract:
    # BOTH placeholder shapes the framework uses — digitless TEAM-NN and
    # bracketed <TEAM>-<digits> (the '>' breaks prefix-digit adjacency) — pass
    # even when TEAM itself is the configured prefix; only a BARE TEAM-<digits>
    # (a shape framework files never carry) trips it.
    $CC_TEAM = 'TE' + 'AM'
    $ccTeam = Join-Path $CC_TMP 'team'; New-Item -ItemType Directory -Path $ccTeam -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ccTeam 'a.md') -Value "reference issues as ${CC_TEAM}-NN in docs"
    Set-Content -LiteralPath (Join-Path $ccTeam 'b.md') -Value "provenance note (<${CC_TEAM}>-147.)"
    $env:TRACKER_ISSUE_PREFIX = $CC_TEAM
    Assert-Exit 'framework placeholder shapes (TEAM-NN, <TEAM>-147) do NOT trip a configured TEAM prefix' 0 -- pwsh -NoProfile -File $CC_SUT $ccTeam
    Set-Content -LiteralPath (Join-Path $ccTeam 'c.md') -Value "bare ${CC_TEAM}-123 here"
    Assert-Exit 'bare TEAM-<digits> DOES trip a configured TEAM prefix' 1 -- pwsh -NoProfile -File $CC_SUT $ccTeam

    # Misconfiguration fails closed, never open: an invalid key (leading digit)
    # and a set-but-only-separators value are both usage errors (exit 2). A
    # set-but-EMPTY value falls back to the QUE default (the local.env.example
    # stub ships empty).
    $env:TRACKER_ISSUE_PREFIX = '1BC'
    Assert-Exit 'invalid prefix entry FAILS closed (exit 2)' 2 -- pwsh -NoProfile -File $CC_SUT $ccClean
    $env:TRACKER_ISSUE_PREFIX = ' , '
    Assert-Exit 'separators-only prefix list FAILS closed (exit 2)' 2 -- pwsh -NoProfile -File $CC_SUT $ccClean
    $env:TRACKER_ISSUE_PREFIX = ''
    Assert-Exit 'empty prefix value falls back to the QUE default (clean tree passes)' 0 -- pwsh -NoProfile -File $CC_SUT $ccClean
} finally {
    Remove-Item Env:\TRACKER_ISSUE_PREFIX -ErrorAction SilentlyContinue
}

# --- Scanner-integrity: a non-directory target is an error, not a pass --------
Assert-Exit 'non-directory target is an error (exit 2)' 2 -- pwsh -NoProfile -File $CC_SUT (Join-Path $CC_TMP 'does-not-exist')

Remove-Item -LiteralPath $CC_TMP -Recurse -Force -ErrorAction SilentlyContinue
