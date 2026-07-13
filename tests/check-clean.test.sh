#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/check-clean.test.sh — the public-repo cleanliness guard (scripts/check-clean.sh).
#
# Sourced by tests/run.sh; uses assert_* helpers from tests/lib.sh. Never call
# `exit` — failures bubble through the assertion counters.
#
# The guard is proven against SYNTHETIC dirty/clean fixtures built here, NOT
# against the live framework tree (which carries issue IDs by design). All
# planted sentinels are assembled at runtime from non-matching halves per
# [[feedback_self_tripping_test_source]], so this test's own source never
# self-trips the guard when the guard later scans a tree containing it.

CC_SUT="$REPO_ROOT/scripts/check-clean.sh"

if [ ! -f "$CC_SUT" ]; then
  _fail "check-clean.sh present" "missing: $CC_SUT"
else
  CC_TMP="$(mktemp -d)"

  # Runtime-built sentinel fragments (no contiguous trip-shape in this source).
  _CC_QUE="QU""E"          # issue-ID prefix
  _CC_USERS="Us""ers"      # macOS home segment
  _CC_HOME="ho""me"        # Linux home segment
  _CC_AT='@'               # email separator

  # --- DIRTY fixture: one file per marker class -----------------------------
  cc_dirty="$CC_TMP/dirty"; mkdir -p "$cc_dirty"
  printf 'tracked under %s-2024 for follow-up\n' "$_CC_QUE"        > "$cc_dirty/issue.md"
  printf 'config lives at /%s/realdev/project/work\n' "$_CC_USERS" > "$cc_dirty/macpath.txt"
  printf 'linux build dir /%s/realdev/out\n' "$_CC_HOME"           > "$cc_dirty/linuxpath.txt"
  printf 'reach me at realdev%sacme-corp.io anytime\n' "$_CC_AT"   > "$cc_dirty/email.txt"

  assert_exit "check-clean FAILS on a dirty tree" 1 -- bash "$CC_SUT" "$cc_dirty"

  cc_dirty_out="$(bash "$CC_SUT" "$cc_dirty" 2>&1)"
  assert_contains "dirty report names the issue-ID class" "$cc_dirty_out" "tracker issue ID"
  assert_contains "dirty report names the home-path class" "$cc_dirty_out" "home path"
  assert_contains "dirty report names the email class"     "$cc_dirty_out" "email"

  # --- Per-class isolation: each class alone trips the guard -----------------
  cc_q="$CC_TMP/q"; mkdir -p "$cc_q"
  printf 'see %s-1 detail\n' "$_CC_QUE" > "$cc_q/a.md"
  assert_exit "issue-ID alone FAILS" 1 -- bash "$CC_SUT" "$cc_q"

  # Lowercase, no-hyphen tracker token (que<NN>) — the class the old uppercase +
  # required-hyphen ISSUE_RE missed (real issue numbers survived as lowercase
  # identifiers in tracked test/script files). Built at runtime so this source
  # carries no contiguous trip-shape.
  _CC_QUE_LC="qu""e"
  cc_qlc="$CC_TMP/qlc"; mkdir -p "$cc_qlc"
  printf 'stale skill named %s107-stale here\n' "$_CC_QUE_LC" > "$cc_qlc/a.md"
  assert_exit "lowercase no-hyphen issue-ID (que<NN>) FAILS" 1 -- bash "$CC_SUT" "$cc_qlc"

  # Boundary: ordinary words ending in "que" + digits (unique/opaque/technique
  # class) must NOT trip this fail-closed gate — the lowercase arm requires a left
  # boundary, so a "que" embedded inside a word is ignored. Words assembled at
  # runtime (uni+que+100 …) so this source carries no contiguous trip-shape.
  cc_ok="$CC_TMP/ok"; mkdir -p "$cc_ok"
  printf 'uni%s100 opa%s22 techni%s5 here\n' "$_CC_QUE_LC" "$_CC_QUE_LC" "$_CC_QUE_LC" > "$cc_ok/a.md"
  assert_exit "benign words ending in 'que'+digits do NOT trip (word boundary)" 0 -- bash "$CC_SUT" "$cc_ok"

  cc_p="$CC_TMP/p"; mkdir -p "$cc_p"
  printf 'path /%s/realperson/x\n' "$_CC_USERS" > "$cc_p/a.md"
  assert_exit "home-path alone FAILS" 1 -- bash "$CC_SUT" "$cc_p"

  cc_e="$CC_TMP/e"; mkdir -p "$cc_e"
  printf 'write person%sreal-domain.net\n' "$_CC_AT" > "$cc_e/a.md"
  assert_exit "real email alone FAILS" 1 -- bash "$CC_SUT" "$cc_e"

  # --- CLEAN fixture: placeholders + allowed domains + plain prose -----------
  cc_clean="$CC_TMP/clean"; mkdir -p "$cc_clean"
  printf 'home is /%s/<name>/ or /%s/$USER/ — fill in your own\n' "$_CC_USERS" "$_CC_HOME" > "$cc_clean/paths.md"
  printf 'example contact you%sexample.com or bot%susers.noreply.github.com\n' "$_CC_AT" "$_CC_AT" > "$cc_clean/contact.md"
  printf 'a perfectly ordinary sentence with nothing to hide\n' > "$cc_clean/readme.md"

  assert_exit "check-clean PASSES on a clean tree (placeholders + allowed domains)" 0 -- bash "$CC_SUT" "$cc_clean"

  # --- Operator-token layer (component-split aware) -------------------------
  # A tree whose only marker is a fake operator token: passes when no tokens are
  # configured (the CI case), fails once the token is configured.
  cc_tok="$CC_TMP/tok"; mkdir -p "$cc_tok"
  printf 'a note mentioning Zubble in passing\n' > "$cc_tok/note.md"

  assert_exit "token-only tree PASSES when no tokens configured (CI case)" 0 -- \
    env -u OPERATOR_PII_TOKENS bash "$CC_SUT" "$cc_tok"
  assert_exit "operator token FAILS when configured (component-split)" 1 -- \
    env OPERATOR_PII_TOKENS="Zubble,Wozzle" bash "$CC_SUT" "$cc_tok"

  # Token match is case-insensitive.
  cc_tokci="$CC_TMP/tokci"; mkdir -p "$cc_tokci"
  printf 'lowercase mention of zubble here\n' > "$cc_tokci/note.md"
  assert_exit "operator token match is case-insensitive" 1 -- \
    env OPERATOR_PII_TOKENS="Zubble" bash "$CC_SUT" "$cc_tokci"

  # --- local.env sourcing: tokens read from the target tree's local.env ------
  # local.env itself is excluded from the scan, so the token is read from it and
  # matched in OTHER files, not in local.env.
  cc_lenv="$CC_TMP/lenv"; mkdir -p "$cc_lenv"
  printf 'a note mentioning Zubble in passing\n' > "$cc_lenv/note.md"
  printf 'OPERATOR_PII_TOKENS="Zubble,Wozzle"\n' > "$cc_lenv/local.env"
  assert_exit "tokens are read from the target local.env when not exported" 1 -- \
    env -u OPERATOR_PII_TOKENS bash "$CC_SUT" "$cc_lenv"

  # --- Cross-model review hardening (Codex adversarial pass) -----------------
  # HIGH-2: JSON/source-escaped Windows path (C:\\Users\\name) is caught.
  cc_win="$CC_TMP/win"; mkdir -p "$cc_win"
  _CC_DBS='\\'   # two literal backslashes (the JSON-escaped form)
  printf 'cache C:%s%s%srealdev%sAppData\n' "$_CC_DBS" "$_CC_USERS" "$_CC_DBS" "$_CC_DBS" > "$cc_win/w.json"
  assert_exit "escaped Windows backslash path FAILS (HIGH-2)" 1 -- bash "$CC_SUT" "$cc_win"

  # HIGH-3: an allowed domain that is only a PREFIX of a real domain must FAIL.
  cc_eb="$CC_TMP/ebypass"; mkdir -p "$cc_eb"
  printf 'bot%susers.noreply.github.com.attacker.net here\n' "$_CC_AT" > "$cc_eb/a.md"
  assert_exit "allowed-domain prefix bypass FAILS (HIGH-3 exact-domain)" 1 -- bash "$CC_SUT" "$cc_eb"

  # MED-1: CRLF + inline-comment local.env still yields the token.
  cc_crlf="$CC_TMP/crlf"; mkdir -p "$cc_crlf"
  printf 'a note mentioning Zubble\n' > "$cc_crlf/n.md"
  printf 'OPERATOR_PII_TOKENS="Zubble" # my tokens\r\n' > "$cc_crlf/local.env"
  assert_exit "CRLF + inline-comment local.env still reads the token (MED-1)" 1 -- \
    env -u OPERATOR_PII_TOKENS bash "$CC_SUT" "$cc_crlf"

  # MED-2: a multi-word token catches a single component.
  cc_split="$CC_TMP/split"; mkdir -p "$cc_split"
  printf 'meeting with Jane about the deal\n' > "$cc_split/m.md"
  assert_exit "multi-word token catches one component (MED-2)" 1 -- \
    env OPERATOR_PII_TOKENS="Jane Doe" bash "$CC_SUT" "$cc_split"

  # HIGH-1 (partial): a git-tracked local.env /.mcp.json is itself a leak.
  cc_git="$CC_TMP/gitrepo"; mkdir -p "$cc_git"
  ( cd "$cc_git" && git init -q && printf 'CLAUDE_CONFIG_DIR=x\n' > local.env && git add local.env ) >/dev/null 2>&1
  assert_exit "a git-tracked local.env is flagged (HIGH-1)" 1 -- bash "$CC_SUT" "$cc_git"

  # --- deferred adversarial findings (git ls-files enumeration) ------
  # The shared root is enumerate-tracked-blobs instead of a recursive
  # basename-excluded filesystem grep. Each fixture below is a real git repo so
  # the guard exercises its tracked-file path; sentinels stay runtime-built from
  # non-matching halves so this source never self-trips the guard.

  # HIGH-1 (full): a committed file that happens to share the guard's BASENAME
  # at a NON-self path must still be scanned. The old basename --exclude skipped
  # `check-clean.sh` ANYWHERE in the tree, so a planted docs/check-clean.sh leak
  # was invisible. Exact repo-relative self-exclusion scans it.
  cc_bn="$CC_TMP/basename"; mkdir -p "$cc_bn/docs"
  ( cd "$cc_bn" && git init -q ) >/dev/null 2>&1
  printf '# decoy, not the real guard\ntracked under %s-9 here\n' "$_CC_QUE" > "$cc_bn/docs/check-clean.sh"
  ( cd "$cc_bn" && git add -A ) >/dev/null 2>&1
  assert_exit "committed docs/check-clean.sh leak FAILS (HIGH-1 basename bypass)" 1 -- bash "$CC_SUT" "$cc_bn"

  # HIGH-5: a UTF-16LE (no BOM) tracked file carrying a leak must FAIL. The old
  # grep -I classified the NUL-laden bytes as binary and skipped them. The fix
  # reads bytes and strips NUL (de-UTF16s ASCII) before scanning.
  cc_u16="$CC_TMP/utf16"; mkdir -p "$cc_u16"
  ( cd "$cc_u16" && git init -q ) >/dev/null 2>&1
  _cc_leak="${_CC_QUE}-5"
  printf '%s' "$_cc_leak" \
    | LC_ALL=C awk '{ n=length($0); for(i=1;i<=n;i++){ printf "%s%c", substr($0,i,1), 0 } }' \
    > "$cc_u16/notes.txt"
  ( cd "$cc_u16" && git add -A ) >/dev/null 2>&1
  assert_exit "UTF-16 (no BOM) tracked leak FAILS (HIGH-5 binary fail-closed)" 1 -- bash "$CC_SUT" "$cc_u16"

  # HIGH-5: an unreadable tracked file must FAIL closed, never silently pass.
  # Benign content so the ONLY trip reason is fail-closed; on the rare host that
  # reads 000 files (root) the benign file simply passes — skipped there. CI is
  # non-root.
  cc_unr="$CC_TMP/unreadable"; mkdir -p "$cc_unr"
  ( cd "$cc_unr" && git init -q ) >/dev/null 2>&1
  printf 'benign placeholder line\n' > "$cc_unr/blob.bin"
  ( cd "$cc_unr" && git add -A ) >/dev/null 2>&1
  chmod 000 "$cc_unr/blob.bin" 2>/dev/null || true
  if [ -r "$cc_unr/blob.bin" ]; then
    _skip "unreadable tracked file FAILS closed (HIGH-5)" "host reads 000 files (root?)"
  else
    assert_exit "unreadable tracked file FAILS closed (HIGH-5)" 1 -- bash "$CC_SUT" "$cc_unr"
  fi
  chmod 644 "$cc_unr/blob.bin" 2>/dev/null || true

  # HIGH-4: a high-signal token split across a hard line-wrap must FAIL. The old
  # line-by-line scan never saw QUE-\n123 / alice@\ncorp as one token.
  cc_ml="$CC_TMP/multiline"; mkdir -p "$cc_ml"
  printf 'see %s-\n123 for context\n' "$_CC_QUE" > "$cc_ml/wrap.md"
  assert_exit "multi-line split issue-ID FAILS (HIGH-4)" 1 -- bash "$CC_SUT" "$cc_ml"

  cc_mle="$CC_TMP/multiline-email"; mkdir -p "$cc_mle"
  printf 'contact realdev%s\nacme-corp.io soon\n' "$_CC_AT" > "$cc_mle/w.md"
  assert_exit "multi-line split email FAILS (HIGH-4 email)" 1 -- bash "$CC_SUT" "$cc_mle"

  # MED-symlink: a tracked symlink whose TARGET text is a home path must FAIL.
  # The old recursive grep never read the link target.
  cc_sym="$CC_TMP/symlink"; mkdir -p "$cc_sym"
  ( cd "$cc_sym" && git init -q ) >/dev/null 2>&1
  ln -s "/${_CC_USERS}/realdev/secret" "$cc_sym/link" 2>/dev/null || true
  ( cd "$cc_sym" && git add -A ) >/dev/null 2>&1
  if [ -L "$cc_sym/link" ]; then
    assert_exit "tracked symlink target home-path FAILS (MED-symlink)" 1 -- bash "$CC_SUT" "$cc_sym"
  else
    _skip "tracked symlink target home-path FAILS (MED-symlink)" "symlink unsupported on host"
  fi

  # Regression guard: a CLEAN git tree (placeholders + allowed domains) still
  # PASSES under git enumeration — no false positives from the blob/multi-line
  # passes.
  cc_gclean="$CC_TMP/gitclean"; mkdir -p "$cc_gclean"
  ( cd "$cc_gclean" && git init -q ) >/dev/null 2>&1
  printf 'home is /%s/<name>/ — fill in your own\n' "$_CC_USERS" > "$cc_gclean/readme.md"
  printf 'contact you%sexample.com anytime\n' "$_CC_AT" >> "$cc_gclean/readme.md"
  ( cd "$cc_gclean" && git add -A ) >/dev/null 2>&1
  assert_exit "clean git tree PASSES under git-enumeration (no FP)" 0 -- bash "$CC_SUT" "$cc_gclean"

  # --- hardening from the Codex forced adversarial pass ------

  # F2: an operator token split across a hard line-wrap must FAIL — the
  # multi-line pass must cover tokens too, not only structural patterns. The
  # token is a runtime-built fake ("Zubble"+"wozzle") so this source carries no
  # real operator handle and does not self-trip the repo PII scans.
  cc_tokml="$CC_TMP/token-multiline"; mkdir -p "$cc_tokml"
  printf 'see Zubble\nwozzle notes\n' > "$cc_tokml/n.md"
  assert_exit "operator token split across a wrap FAILS (F2 multi-line tokens)" 1 -- \
    env OPERATOR_PII_TOKENS="Zubblewozzle" bash "$CC_SUT" "$cc_tokml"

  # F3: a Windows home path escaped with MORE than two backslashes (a JSON string
  # nested inside a source string) must still FAIL.
  cc_w4="$CC_TMP/win4"; mkdir -p "$cc_w4"
  _CC_QBS='\\\\'   # four literal backslashes
  printf 'path C:%sUsers%srealdev%s.ssh\n' "$_CC_QBS" "$_CC_QBS" "$_CC_QBS" > "$cc_w4/w.json"
  assert_exit "4-backslash Windows home path FAILS (F3 nested escape)" 1 -- bash "$CC_SUT" "$cc_w4"

  # F4: in filesystem (non-git) mode a present local.env carrying a leak must
  # FAIL — the tracked-file check is git-only, leaving a fs-mode gap.
  cc_fslenv="$CC_TMP/fs-lenv"; mkdir -p "$cc_fslenv"
  printf 'OPERATOR_PII_TOKENS="Zubble"\nNOTE=/%s/realdev/secret\n' "$_CC_USERS" > "$cc_fslenv/local.env"
  assert_exit "fs-mode leaky local.env FAILS (F4 git/fs gap)" 1 -- \
    env -u OPERATOR_PII_TOKENS bash "$CC_SUT" "$cc_fslenv"

  # F6: a case-varied excluded-dir name (Cross-Model-Out vs cross-model-out) must
  # still be scanned — exclusion is case-SENSITIVE, matching the bash globs.
  cc_casedir="$CC_TMP/casedir"; mkdir -p "$cc_casedir/Cross-Model-Out"
  printf 'tracked under %s-6 here\n' "$_CC_QUE" > "$cc_casedir/Cross-Model-Out/leak.md"
  assert_exit "case-varied excluded dir is still scanned (F6 case-sensitive exclusion)" 1 -- bash "$CC_SUT" "$cc_casedir"

  # F1: a tracked file with a non-ASCII name carrying a leak must FAIL — robust
  # NUL-delimited enumeration, no path-quoting bypass or spurious skip.
  cc_uni="$CC_TMP/unicode"; mkdir -p "$cc_uni"
  ( cd "$cc_uni" && git init -q ) >/dev/null 2>&1
  printf 'tracked under %s-1 here\n' "$_CC_QUE" > "$cc_uni/café.md"
  ( cd "$cc_uni" && git add -A ) >/dev/null 2>&1
  assert_exit "tracked non-ASCII filename leak FAILS (F1 -z enumeration)" 1 -- bash "$CC_SUT" "$cc_uni"

  # --- Commit-metadata identity check (opt-in via COMMIT_IDENTITY_ALLOWLIST) --
  # Content scans cannot see commit metadata; these fixtures prove the guard's
  # metadata arm. Identities are runtime-built (allowed email domain) so this
  # source carries no real identity and no contiguous email shape.
  _CC_BOT_NAME="Bot Fixture"
  _CC_BOT_MAIL="bot${_CC_AT}example.com"
  _CC_BOT_ID="$_CC_BOT_NAME <$_CC_BOT_MAIL>"
  _CC_ROGUE_NAME="Real Dev"
  _CC_ROGUE_MAIL="real.dev${_CC_AT}acme-corp.io"

  # Bot-only commits + allowlist => PASS, and the PASS line reports coverage.
  cc_idok="$CC_TMP/id-ok"; mkdir -p "$cc_idok"
  ( cd "$cc_idok" && git init -q && printf 'clean prose\n' > a.md && git add -A &&
    git -c user.name="$_CC_BOT_NAME" -c user.email="$_CC_BOT_MAIL" commit -qm one ) >/dev/null 2>&1
  assert_exit "commit-identity: bot-only branch PASSES with allowlist" 0 -- \
    env COMMIT_IDENTITY_ALLOWLIST="$_CC_BOT_ID" bash "$CC_SUT" "$cc_idok"
  cc_idok_out="$(env COMMIT_IDENTITY_ALLOWLIST="$_CC_BOT_ID" bash "$CC_SUT" "$cc_idok" 2>&1)"
  assert_contains "commit-identity: PASS line reports checked count" "$cc_idok_out" "1 branch commit(s) identity-checked"

  # Rogue author+committer => FAIL naming both fields.
  cc_idbad="$CC_TMP/id-bad"; mkdir -p "$cc_idbad"
  ( cd "$cc_idbad" && git init -q && printf 'clean prose\n' > a.md && git add -A &&
    git -c user.name="$_CC_ROGUE_NAME" -c user.email="$_CC_ROGUE_MAIL" commit -qm one ) >/dev/null 2>&1
  assert_exit "commit-identity: rogue identity FAILS" 1 -- \
    env COMMIT_IDENTITY_ALLOWLIST="$_CC_BOT_ID" bash "$CC_SUT" "$cc_idbad"
  cc_idbad_out="$(env COMMIT_IDENTITY_ALLOWLIST="$_CC_BOT_ID" bash "$CC_SUT" "$cc_idbad" 2>&1)"
  assert_contains "commit-identity: FAIL names the author field" "$cc_idbad_out" "author not allowlisted"
  assert_contains "commit-identity: FAIL names the committer field" "$cc_idbad_out" "committer not allowlisted"

  # Allowed author but rogue COMMITTER => still FAILS (committer is checked too).
  cc_idcom="$CC_TMP/id-committer"; mkdir -p "$cc_idcom"
  ( cd "$cc_idcom" && git init -q && printf 'clean prose\n' > a.md && git add -A &&
    git -c user.name="$_CC_ROGUE_NAME" -c user.email="$_CC_ROGUE_MAIL" \
      commit -qm one --author="$_CC_BOT_ID" ) >/dev/null 2>&1
  cc_idcom_out="$(env COMMIT_IDENTITY_ALLOWLIST="$_CC_BOT_ID" bash "$CC_SUT" "$cc_idcom" 2>&1)"; cc_idcom_rc=$?
  assert_eq "commit-identity: rogue committer behind allowed author FAILS" "1" "$cc_idcom_rc"
  assert_contains "commit-identity: committer-only leak names the committer" "$cc_idcom_out" "committer not allowlisted"
  assert_not_contains "commit-identity: allowed author is not flagged" "$cc_idcom_out" "author not allowlisted"

  # Allowlist UNSET => documented no-op even on the rogue repo, and the PASS
  # line says so (coverage is never silently overstated).
  cc_idskip_out="$(env -u COMMIT_IDENTITY_ALLOWLIST bash "$CC_SUT" "$cc_idbad" 2>&1)"; cc_idskip_rc=$?
  assert_eq "commit-identity: unset allowlist is a no-op (exit 0)" "0" "$cc_idskip_rc"
  assert_contains "commit-identity: skip is reported on the PASS line" "$cc_idskip_out" "commit-identity check skipped"

  # Set-but-empty-after-parsing allowlist is a misconfiguration => fail-closed.
  assert_exit "commit-identity: empty-parse allowlist FAILS closed" 1 -- \
    env COMMIT_IDENTITY_ALLOWLIST=" , " bash "$CC_SUT" "$cc_idok"

  # Allowlist read from the target's gitignored local.env (env unset).
  printf 'COMMIT_IDENTITY_ALLOWLIST="%s"\n' "$_CC_BOT_ID" > "$cc_idbad/local.env"
  cc_idlenv_out="$(env -u COMMIT_IDENTITY_ALLOWLIST bash "$CC_SUT" "$cc_idbad" 2>&1)"; cc_idlenv_rc=$?
  assert_eq "commit-identity: allowlist picked up from target local.env" "1" "$cc_idlenv_rc"
  assert_contains "commit-identity: local.env-sourced check flags the rogue commit" "$cc_idlenv_out" "author not allowlisted"

  # Range scoping: rogue commit BELOW the default-branch ref is published
  # history (not this branch's to re-litigate); only ahead-of-base commits are
  # checked, so a bot-only ahead set PASSES.
  cc_idrange="$CC_TMP/id-range"; mkdir -p "$cc_idrange"
  ( cd "$cc_idrange" && git init -q && printf 'clean prose\n' > a.md && git add -A &&
    git -c user.name="$_CC_ROGUE_NAME" -c user.email="$_CC_ROGUE_MAIL" commit -qm old &&
    git update-ref refs/remotes/origin/main HEAD &&
    printf 'more clean prose\n' > b.md && git add -A &&
    git -c user.name="$_CC_BOT_NAME" -c user.email="$_CC_BOT_MAIL" commit -qm new ) >/dev/null 2>&1
  cc_idrange_out="$(env COMMIT_IDENTITY_ALLOWLIST="$_CC_BOT_ID" bash "$CC_SUT" "$cc_idrange" 2>&1)"; cc_idrange_rc=$?
  assert_eq "commit-identity: only ahead-of-default commits are checked" "0" "$cc_idrange_rc"
  assert_contains "commit-identity: range-scoped run reports 1 checked" "$cc_idrange_out" "1 branch commit(s) identity-checked"

  # Adversarial regression: a local TAG named origin/main resolves BEFORE the
  # remote-tracking ref (gitrevisions order) — with bare refnames it would
  # shadow the no-base fallback and empty the range. Full refs/remotes/ names
  # are immune: the remoteless rogue repo is still fully checked and FAILS.
  cc_idtag="$CC_TMP/id-tagshadow"; mkdir -p "$cc_idtag"
  ( cd "$cc_idtag" && git init -q && printf 'clean prose\n' > a.md && git add -A &&
    git -c user.name="$_CC_ROGUE_NAME" -c user.email="$_CC_ROGUE_MAIL" commit -qm one &&
    git tag origin/main ) >/dev/null 2>&1
  assert_exit "commit-identity: tag named origin/main cannot shadow the fallback range" 1 -- \
    env COMMIT_IDENTITY_ALLOWLIST="$_CC_BOT_ID" bash "$CC_SUT" "$cc_idtag"

  # Adversarial regression: the no-commits skip is benign ONLY for an unborn
  # repo (zero commits anywhere) — that path passes with the explicit note.
  cc_idunborn="$CC_TMP/id-unborn"; mkdir -p "$cc_idunborn"
  ( cd "$cc_idunborn" && git init -q ) >/dev/null 2>&1
  cc_idunborn_out="$(env COMMIT_IDENTITY_ALLOWLIST="$_CC_BOT_ID" bash "$CC_SUT" "$cc_idunborn" 2>&1)"; cc_idunborn_rc=$?
  assert_eq "commit-identity: unborn repo passes with the no-commits note" "0" "$cc_idunborn_rc"
  assert_contains "commit-identity: unborn repo names the no-commits path" "$cc_idunborn_out" "no commits to check"

  # --- Tracker-prefix configurability (TRACKER_ISSUE_PREFIX) ------------------
  # The issue-ID scan derives from the configured prefix set; unset keeps the
  # historical QUE default (proven by the fixtures above). Prefix sentinels are
  # runtime-built from halves like every other trip-shape in this file.
  _CC_ABC="AB""C"
  _CC_OPS="OP""S"

  # A configured non-default prefix is caught, and the report names it.
  cc_pfx="$CC_TMP/pfx"; mkdir -p "$cc_pfx"
  printf 'tracked under %s-123 for follow-up\n' "$_CC_ABC" > "$cc_pfx/a.md"
  cc_pfx_out="$(env TRACKER_ISSUE_PREFIX="$_CC_ABC" bash "$CC_SUT" "$cc_pfx" 2>&1)"; cc_pfx_rc=$?
  assert_eq "configured prefix issue-ID FAILS" "1" "$cc_pfx_rc"
  assert_contains "configured-prefix report names the prefix" "$cc_pfx_out" "(${_CC_ABC}-<n>)"
  # The same tree passes an UNCONFIGURED run (QUE default) — the documented
  # contract: the guard defends exactly the prefixes it is told about.
  assert_exit "non-default prefix passes when unconfigured (QUE default)" 0 -- \
    env -u TRACKER_ISSUE_PREFIX bash "$CC_SUT" "$cc_pfx"

  # Multi-prefix: every configured key is scanned and named.
  cc_pfx2="$CC_TMP/pfx2"; mkdir -p "$cc_pfx2"
  printf 'see %s-7 here\n' "$_CC_OPS" > "$cc_pfx2/a.md"
  printf 'and %s-9 there\n' "$_CC_ABC" > "$cc_pfx2/b.md"
  cc_pfx2_out="$(env TRACKER_ISSUE_PREFIX="${_CC_ABC},${_CC_OPS}" bash "$CC_SUT" "$cc_pfx2" 2>&1)"; cc_pfx2_rc=$?
  assert_eq "multi-prefix: both configured keys are scanned (FAIL)" "1" "$cc_pfx2_rc"
  assert_contains "multi-prefix: first key named" "$cc_pfx2_out" "(${_CC_ABC}-<n>)"
  assert_contains "multi-prefix: second key named" "$cc_pfx2_out" "(${_CC_OPS}-<n>)"

  # Derived-pattern semantics carry over: lowercase no-hyphen at a boundary
  # trips; a lowercase occurrence embedded inside a word does not.
  _CC_ABC_LC="ab""c"
  cc_pfxlc="$CC_TMP/pfxlc"; mkdir -p "$cc_pfxlc"
  printf 'stale ref %s42 here\n' "$_CC_ABC_LC" > "$cc_pfxlc/a.md"
  assert_exit "lowercase no-hyphen (<prefix><NN>) FAILS for a configured prefix" 1 -- \
    env TRACKER_ISSUE_PREFIX="$_CC_ABC" bash "$CC_SUT" "$cc_pfxlc"
  cc_pfxb="$CC_TMP/pfxb"; mkdir -p "$cc_pfxb"
  printf 'word f%s123 embedded here\n' "$_CC_ABC_LC" > "$cc_pfxb/a.md"
  assert_exit "embedded lowercase prefix does NOT trip (boundary preserved)" 0 -- \
    env TRACKER_ISSUE_PREFIX="$_CC_ABC" bash "$CC_SUT" "$cc_pfxb"

  # Prefix read from the target's gitignored local.env when not exported.
  cc_pfxlenv="$CC_TMP/pfx-lenv"; mkdir -p "$cc_pfxlenv"
  printf 'see %s-11 here\n' "$_CC_ABC" > "$cc_pfxlenv/a.md"
  printf 'TRACKER_ISSUE_PREFIX="%s"\n' "$_CC_ABC" > "$cc_pfxlenv/local.env"
  assert_exit "prefix read from the target local.env when not exported" 1 -- \
    env -u TRACKER_ISSUE_PREFIX bash "$CC_SUT" "$cc_pfxlenv"

  # TEAM is the reserved documentation placeholder. Lock the exact contract:
  # BOTH placeholder shapes the framework uses — digitless TEAM-NN and
  # bracketed <TEAM>-<digits> (the '>' breaks prefix-digit adjacency) — pass
  # even when TEAM itself is the configured prefix; only a BARE TEAM-<digits>
  # (a shape framework files never carry) trips it.
  _CC_TEAM="TE""AM"
  cc_team="$CC_TMP/team"; mkdir -p "$cc_team"
  printf 'reference issues as %s-NN in docs\n' "$_CC_TEAM" > "$cc_team/a.md"
  printf 'provenance note (<%s>-147.)\n' "$_CC_TEAM" > "$cc_team/b.md"
  assert_exit "framework placeholder shapes (TEAM-NN, <TEAM>-147) do NOT trip a configured TEAM prefix" 0 -- \
    env TRACKER_ISSUE_PREFIX="$_CC_TEAM" bash "$CC_SUT" "$cc_team"
  printf 'bare %s-123 here\n' "$_CC_TEAM" > "$cc_team/c.md"
  assert_exit "bare TEAM-<digits> DOES trip a configured TEAM prefix" 1 -- \
    env TRACKER_ISSUE_PREFIX="$_CC_TEAM" bash "$CC_SUT" "$cc_team"

  # Misconfiguration fails closed, never open: an invalid key (leading digit)
  # and a set-but-only-separators value are both usage errors (exit 2). A
  # set-but-EMPTY value falls back to the QUE default (the local.env.example
  # stub ships empty).
  assert_exit "invalid prefix entry FAILS closed (exit 2)" 2 -- \
    env TRACKER_ISSUE_PREFIX="1BC" bash "$CC_SUT" "$cc_clean"
  assert_exit "separators-only prefix list FAILS closed (exit 2)" 2 -- \
    env TRACKER_ISSUE_PREFIX=" , " bash "$CC_SUT" "$cc_clean"
  assert_exit "empty prefix value falls back to the QUE default (clean tree passes)" 0 -- \
    env TRACKER_ISSUE_PREFIX="" bash "$CC_SUT" "$cc_clean"

  # --- Scanner-integrity: a non-directory target is an error, not a pass -----
  assert_exit "non-directory target is an error (exit 2)" 2 -- bash "$CC_SUT" "$CC_TMP/does-not-exist"

  rm -rf "$CC_TMP"
fi
