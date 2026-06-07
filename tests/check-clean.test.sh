#!/usr/bin/env bash
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

  # --- Scanner-integrity: a non-directory target is an error, not a pass -----
  assert_exit "non-directory target is an error (exit 2)" 2 -- bash "$CC_SUT" "$CC_TMP/does-not-exist"

  rm -rf "$CC_TMP"
fi
