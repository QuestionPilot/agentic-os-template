#!/usr/bin/env bash
# tests/drift.test.sh — manifest-drift detection for check-drift.sh.

# Build a clean target.
DR_OUT="$(mktemp -d)/target"; mkdir -p "$DR_OUT"
DR_ENV="$(mktemp -d)/local.env"
make_local_env "$DR_ENV" "$DR_OUT"
AI_CONFIG_LOCAL_ENV="$DR_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Clean target: drift check passes.
assert_exit "drift check passes on a clean build" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$DR_OUT"

# Hand-edit a generated skill file: drift check must fail.
printf '\nHAND EDIT\n' >> "$DR_OUT/skills/session-agent/SKILL.md"
assert_exit "drift check fails after a generated file is hand-edited" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$DR_OUT"

rm -rf "$DR_OUT"

# --- --manifest flags an untracked file in the generated tree ---
DR2_OUT="$(mktemp -d)/target"; mkdir -p "$DR2_OUT"
DR2_ENV="$(mktemp -d)/local.env"
make_local_env "$DR2_ENV" "$DR2_OUT"
AI_CONFIG_LOCAL_ENV="$DR2_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Clean build passes the extra-file check.
assert_exit "drift check passes a clean build (extra-file check)" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$DR2_OUT"

# an untracked file INSIDE a manifest-managed skill subdir is still
# drift (someone hand-edited inside a managed skill). The Shape C exemption
# only covers UNMANAGED skill subdirs, not the contents of managed ones.
# (Targets session-agent post-fix — `route` no longer exists.)
printf 'rogue\n' > "$DR2_OUT/skills/session-agent/intruder.md"
assert_exit "drift check fails on an untracked file in a managed skill" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$DR2_OUT"
rm -f "$DR2_OUT/skills/session-agent/intruder.md"

# an untracked subdir under skills/ that the manifest does not manage
# is a Shape C operator-local skill — exempt from the drift check. install.sh's
# per-subdir swap preserves these; check-drift recognizes them by the absence
# of any manifest-managed files for that subdir.
mkdir -p "$DR2_OUT/skills/shape-c-fixture"
printf -- '---\nname: shape-c-fixture\ndescription: Shape C drift exemption fixture\n---\n# body\n' \
  > "$DR2_OUT/skills/shape-c-fixture/SKILL.md"
assert_exit "drift check passes with an unmanaged Shape C skill subdir" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$DR2_OUT"
rm -rf "$DR2_OUT/skills/shape-c-fixture"

# An untracked file directly under hooks/ (no Shape C semantics for hooks —
# every entry is manifest-managed) must still fail the extra-file check.
printf '#!/bin/bash\n' > "$DR2_OUT/hooks/intruder.sh"
assert_exit "drift check fails on an untracked hook" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$DR2_OUT"
rm -f "$DR2_OUT/hooks/intruder.sh"

# F-2: the Shape C exemption is only for SUBDIR-structured content
# (`skills/<name>/...`). A file placed directly under `skills/` (no subdir,
# e.g. `skills/rogue.md`) is not Shape C — it must still register as drift.
printf 'rogue at top\n' > "$DR2_OUT/skills/rogue.md"
assert_exit "drift check fails on a file directly under skills/ (no subdir)" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$DR2_OUT"
rm -f "$DR2_OUT/skills/rogue.md"

rm -rf "$DR2_OUT"

# --- portability scan must not false-positive on regex code ---
# check-drift.sh's full (non-manifest) scan runs over the whole repo, which now
# includes vendored third-party JS snapshots full of regex literals like `:\s`.
# The Windows-path heuristic must be tight enough (`[A-Za-z]:\Users`, not a bare
# `[A-Za-z]:\`) not to flag those. This runs the real script over the real repo;
# it fails if the heuristic regresses or a genuine machine path is committed.
assert_exit "check-drift.sh portability scan passes on the repo" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh"

# --- Operator personal-naming denylist is enforced (operator-private) ---
# The personal-naming denylist lives in the operator-private fragment
# scripts/lib/operator-naming-check.sh, which check-drift.sh dot-sources only
# when present (and the public-snapshot ship-set excludes). So this behavior is
# operator-private: guard it on the fragment's presence, mirroring check-drift's
# own conditional sourcing. A public-template adopter has no operator handle to
# defend against, so the check is correctly vestigial there — skip. The sentinel
# handle is CONSTRUCTED at runtime from non-matching halves so this test SOURCE
# carries no operator literal ([[feedback_self_tripping_test_source]]), matching
# the .mcp.json sentinel below. Cleanup is NOT trap-based: test files are sourced
# into the runner, so trap EXIT would persist across files (see tests/run.sh).
if [ -f "$REPO_ROOT/scripts/lib/operator-naming-check.sh" ]; then
  _handle="$(printf '%s%s' 'Hen' 'do')"
  HV_INJECT="$REPO_ROOT/.test-operator-naming-injection.md"
  printf 'sentinel: %s Vault appears here\n' "$_handle" > "$HV_INJECT"
  assert_exit "check-drift.sh fails when the operator handle is reintroduced" 1 -- \
    bash "$REPO_ROOT/scripts/check-drift.sh"
  rm -f "$HV_INJECT"

  # Lowercase YAML-tag form proves the case-insensitive flag is doing work —
  # without -i this would NOT match and the test would falsely pass.
  _handle_lc="$(printf '%s%s' 'hen' 'do')"
  HV_LOWER_INJECT="$REPO_ROOT/.test-operator-naming-lower-injection.md"
  printf 'sentinel: %s-vault/template appears here\n' "$_handle_lc" > "$HV_LOWER_INJECT"
  assert_exit "check-drift.sh fails when the lowercase operator handle is reintroduced" 1 -- \
    bash "$REPO_ROOT/scripts/check-drift.sh"
  rm -f "$HV_LOWER_INJECT"
  unset _handle _handle_lc
else
  _skip "check-drift.sh fails when the operator handle is reintroduced" \
    "operator-naming-check.sh absent (public-template adopter)"
  _skip "check-drift.sh fails when the lowercase operator handle is reintroduced" \
    "operator-naming-check.sh absent (public-template adopter)"
fi

# ---.mcp.json (per-project MCP config) is excluded from
# the path scan + personal-naming scan ---
# Operator-installed MCP servers may write a.mcp.json at project root pinning
# absolute paths (e.g. PATH-hijack mitigation patterns). The file is
# gitignored — machine-local install state, parallel to local.env. Without the
# --exclude=.mcp.json amendment the path scan and the personal-naming scan would
# both false-positive on the absolute operator home-directory path string. (:
# the historical example here was codegraph, unwired from the framework; the
# exclusion stays — any operator-installed MCP follows the same pattern.)
#
# Skip-if-real preserves the real.mcp.json on this machine (existing real
# install proves the exclusion works in-situ); clean machines exercise the
# inject-and-cleanup path. Same discipline as the validate.test.sh F-2
# settings.local.json case.
#
# The sentinel path is CONSTRUCTED at runtime from non-matching halves so
# this test source never matches the path scan or the personal-naming scan when drift
# scans tests/. Same pattern as the H6 test below
# ([[feedback_self_tripping_test_source]]).
if [ -e "$REPO_ROOT/.mcp.json" ]; then
  _skip "check-drift.sh skips .mcp.json" \
    "real .mcp.json present at \$REPO_ROOT — refusing to overwrite"
else
  mcp_prefix='/U'
  mcp_path_body='sers/h'
  mcp_user_a='end'
  mcp_user_b='ohome'
  mcp_tail='/.local/bin/sentinel-tool'
  mcp_full="$mcp_prefix$mcp_path_body$mcp_user_a$mcp_user_b$mcp_tail"
  printf '{ "command": "%s" }\n' "$mcp_full" > "$REPO_ROOT/.mcp.json"
  unset mcp_prefix mcp_path_body mcp_user_a mcp_user_b mcp_tail mcp_full
  assert_exit "check-drift.sh skips .mcp.json" 0 -- \
    bash "$REPO_ROOT/scripts/check-drift.sh"
  rm -f "$REPO_ROOT/.mcp.json"
fi

# --- a home path inside a harness gitlink file does NOT
# false-trip the path scan ---
# Real git worktrees write a.git gitlink FILE (not directory) containing
# "gitdir: <absolute-path-to-main-repo-gitdir>". Inside harness-managed
# worktrees (.claude/worktrees/<branch>/.git), that absolute path contains
# Users/<operator>/. The existing --exclude-dir=.claude /.codex /.agents
# prune in check-drift.sh's path scan covers this — but no test pinned the
# behavior. Without the prune (or if a future refactor narrows it), the
# Hh-operator path inside the gitlink would false-trip.
#
# This test plants a fake.claude/worktrees/<branch>/.git gitlink file
# containing the home-prefix sentinel and asserts check-drift PASSes. Skip-
# if-real preserves any pre-existing harness worktree state.
#
# Sentinel constructed at runtime (per [[feedback_self_tripping_test_source]]).
DR_T66_FAKE_WT=".claude/worktrees/.test-t66-c1-fake-wt-$$-${RANDOM:-x}"
if [ -e "$REPO_ROOT/$DR_T66_FAKE_WT" ]; then
  _skip "check-drift.sh skips /Users/ inside harness gitlink" \
    "collision with real worktree path — refusing to overwrite"
else
  mkdir -p "$REPO_ROOT/$DR_T66_FAKE_WT"
  c1_prefix='/U'
  c1_path_body='sers/test-t66-c1/.test-claude-config/repo.git/worktrees/branch'
  c1_full="${c1_prefix}${c1_path_body}"
  printf 'gitdir: %s\n' "$c1_full" > "$REPO_ROOT/$DR_T66_FAKE_WT/.git"
  unset c1_prefix c1_path_body c1_full
  assert_exit "check-drift.sh skips /Users/ inside harness gitlink" 0 -- \
    bash "$REPO_ROOT/scripts/check-drift.sh"
  rm -rf "$REPO_ROOT/$DR_T66_FAKE_WT"
  # Best-effort empty-dir cleanup (don't disturb real worktrees/ dir)
  rmdir "$REPO_ROOT/.claude/worktrees" 2>/dev/null || true
  rmdir "$REPO_ROOT/.claude" 2>/dev/null || true
fi

# --- positive + negative regex coverage ---
# Cross-model review (Codex+Gemini) flagged the new C-1 pattern needed
# positive AND negative test coverage. The five cases below pin the intended
# behavior of the tightened class-shape pattern:
# POSITIVE — mac home prefix + path; linux home prefix + path; mac home
# prefix without trailing slash (added by the /? amendment);
# Windows drive home prefix + path — all trip the gate.
# NEGATIVE — bare home prefix without a username segment does NOT trip
# the gate (the OLD bare-substring pattern would have caught
# it; the new class-shape pattern explicitly skips).
#
# Each case injects a sentinel.md at $REPO_ROOT, runs check-drift,
# asserts exit code, removes inline. Sentinels are runtime-constructed
# from non-matching halves so this test source itself doesn't self-trip
# the gate (per [[feedback_self_tripping_test_source]]). Description
# strings deliberately avoid the literal home-prefix substring for the
# same reason — the path-scan would otherwise match the assertion label
# when it scans tests/drift.test.sh.

# --- positive: mac home prefix + user + trailing path ---
DR_C1_POS_M="$REPO_ROOT/.test-t66-c1-mac-pos-$$-${RANDOM:-x}.md"
c1_p='/Us'
c1_b='ers/test-t66-c1-pos/path'
printf '%s%s\n' "$c1_p" "$c1_b" > "$DR_C1_POS_M"
unset c1_p c1_b
assert_exit "check-drift catches mac home prefix + user + path" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh"
rm -f "$DR_C1_POS_M"

# --- positive: linux home prefix + user + trailing path ---
DR_C1_POS_L="$REPO_ROOT/.test-t66-c1-linux-pos-$$-${RANDOM:-x}.md"
c1_p='/h'
c1_b='ome/test-t66-c1-pos/path'
printf '%s%s\n' "$c1_p" "$c1_b" > "$DR_C1_POS_L"
unset c1_p c1_b
assert_exit "check-drift catches linux home prefix + user + path" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh"
rm -f "$DR_C1_POS_L"

# --- positive: mac home prefix + user, NO trailing slash (cross-model
# amendment — the original pattern required trailing slash and missed
# bare-home-dir references) ---
DR_C1_POS_NS="$REPO_ROOT/.test-t66-c1-no-trail-$$-${RANDOM:-x}.md"
c1_p='/Us'
c1_b='ers/test-t66-c1-no-trail'
printf '%s%s\n' "$c1_p" "$c1_b" > "$DR_C1_POS_NS"
unset c1_p c1_b
assert_exit "check-drift catches mac home prefix + user with no trailing slash" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh"
rm -f "$DR_C1_POS_NS"

# --- positive: Windows drive home prefix + user + path ---
DR_C1_POS_W="$REPO_ROOT/.test-t66-c1-win-pos-$$-${RANDOM:-x}.md"
c1_drive='C:'
c1_p='\Us'
c1_b='ers\test-t66-c1-pos\path'
printf '%s%s%s\n' "$c1_drive" "$c1_p" "$c1_b" > "$DR_C1_POS_W"
unset c1_drive c1_p c1_b
assert_exit "check-drift catches Windows drive home prefix + user + path" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh"
rm -f "$DR_C1_POS_W"

# --- negative: bare home prefix without a username segment does NOT trip ---
# The OLD pattern would catch this (bare-substring `/Users/`); the NEW
# class-shape pattern requires `[^/]+` after, so bare home with no user
# is intentionally skipped. Same for `/home/`.
DR_C1_NEG_M="$REPO_ROOT/.test-t66-c1-bare-mac-neg-$$-${RANDOM:-x}.md"
c1_p='/Us'
c1_b='ers/'
printf '%s%s\n' "$c1_p" "$c1_b" > "$DR_C1_NEG_M"
unset c1_p c1_b
assert_exit "check-drift skips bare mac home with no user segment" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh"
rm -f "$DR_C1_NEG_M"

# --- portability scan catches concrete paths in tracked plans ---
# Before: check-drift.sh's path scan used --exclude-dir=plans, hiding
# concrete personal home-prefix paths under docs/plans/*.md from the gate.
# The implementation plans both carried personal home-prefix
# paths in their bash command examples (H5 scrubbed them, H6
# narrowed the exclusion so a future regression is caught). The sentinel
# path is CONSTRUCTED at runtime — the home-prefix literal is never written
# in this source — so the test file itself does not match the path scan
# when drift scans tests/.
# docs/ is excluded from the public template ship-set, so docs/plans/ may not
# exist on a fresh template clone — create it so the fixture can be planted.
mkdir -p "$REPO_ROOT/docs/plans"
H6_INJECT="$REPO_ROOT/docs/plans/test-t52-h6-leak.md"
h6_prefix='/U'
h6_body='sers/test-t52-h6/sentinel'
printf '%s%s\n' "$h6_prefix" "$h6_body" > "$H6_INJECT"
unset h6_prefix h6_body
assert_exit "check-drift.sh catches concrete-home-prefix path in docs/plans/" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh"
rm -f "$H6_INJECT"

# --- cross-model-out/ runtime artifacts are pruned from check-drift.sh ---
# The cross-model-review skill files run outputs under cross-model-out/<run>/
# (codex-review.md, gemini-review.md, reconciled.md, log.md). `codex exec`
# prepends a `workdir: <abs-path>` metadata header on every output, so even
# a clean review body carries an operator-absolute path on line 1. Without
# the prune, that workdir line trips check-drift.sh's path-leak scan and
# blocks `bash scripts/validate.sh` from the worktree until the file is
# hand-sanitized — see [[runtime_cross_model_review_artifacts]] for the
# 2026-05-24 live discovery during PR #21. The fix: cross-model-out/
# in.gitignore + --exclude-dir=cross-model-out on the three broad
# repo_root-walking scans in check-drift.sh.
#
# Sentinel is runtime-constructed from non-matching halves so this test
# source does not self-trip the path scan when drift scans tests/ (mirrors
# the H6 pattern above). The dir name is unique-per-test ($$-$RANDOM,
# parallel to DR_T66_FAKE_WT at line 149) to avoid colliding with a real
# review run that happens to land here. Skip-if-exists guard preserves the
# real run if the fixture name collides (vanishingly rare).
DR_T87_DIR="cross-model-out/.test-t87-leak-$$-${RANDOM:-x}"
if [ -e "$REPO_ROOT/$DR_T87_DIR" ]; then
  _skip "check-drift.sh prunes cross-model-out/ runtime artifacts" \
    "fixture collision: $REPO_ROOT/$DR_T87_DIR exists"
else
  mkdir -p "$REPO_ROOT/$DR_T87_DIR"
  # Fixture pins the cross-model-out/ prune for the active scans (machine-path,
  # plus the personal-naming scan when the operator fragment is present) so a
  # future regression that drops --exclude-dir=cross-model-out fails this single
  # assertion. The sentinels are runtime-constructed from non-matching halves so
  # this test source does not self-trip the scans when drift scans tests/.
  cmr_prefix='/U'
  cmr_body='sers/test-t87/Claude - Local/agentic-os-template'
  hd_a='Hen'; hd_b='do'
  {
    printf 'workdir: %s%s\nmodel: gpt-5.5\n\n' "$cmr_prefix" "$cmr_body"
    printf '# Review repo by %s%s\n' "$hd_a" "$hd_b"
  } > "$REPO_ROOT/$DR_T87_DIR/codex-review.md"
  unset cmr_prefix cmr_body hd_a hd_b
  assert_exit "check-drift.sh prunes cross-model-out/ runtime artifacts" 0 -- \
    bash "$REPO_ROOT/scripts/check-drift.sh"
  rm -rf "$REPO_ROOT/$DR_T87_DIR"
fi

# --- the broad content scans enumerate the COMMITTABLE set
# (`git ls-files --cached --others --exclude-standard`), so GITIGNORED runtime
# artifacts are pruned while tracked + untracked-not-ignored content is still
# scanned. The machine-path sentinel is assembled at runtime from non-matching
# halves so this test source does not self-trip the scan (per
# [[feedback_self_tripping_test_source]]). Each fixture asserts its gitignore
# precondition before the behavioral assertion — a misconfigured.gitignore would
# otherwise make these pass vacuously. ---
q213_home='/Us''ers/test-t213/Projects/foo/bar.js'

# (a) THE FIX: a gitignored.codegraph/*.log carrying an absolute home path (the
# field case: codegraph's.codegraph/daemon.log) is PRUNED -> exit 0. Under the
# pre-fix `grep -r` walk this exited 1. Unique filename + rmdir-if-created so
# a real codegraph install's state is never touched.
DR_Q213_IGN_DIR="$REPO_ROOT/.codegraph"
DR_Q213_IGN="$DR_Q213_IGN_DIR/.test-t213-daemon-$$-${RANDOM:-x}.log"
DR_Q213_MADE_DIR=0
[ -d "$DR_Q213_IGN_DIR" ] || { mkdir -p "$DR_Q213_IGN_DIR"; DR_Q213_MADE_DIR=1; }
if [ -e "$DR_Q213_IGN" ]; then
  _skip "check-drift.sh prunes gitignored .codegraph runtime log" "fixture collision: $DR_Q213_IGN"
else
  printf 'indexed at %s\n' "$q213_home" > "$DR_Q213_IGN"
  if git -C "$REPO_ROOT" check-ignore -q "$DR_Q213_IGN"; then
    assert_exit "check-drift.sh prunes gitignored .codegraph runtime log" 0 -- \
      bash "$REPO_ROOT/scripts/check-drift.sh"
  else
    _fail "check-drift.sh prunes gitignored .codegraph runtime log" \
      "precondition failed: fixture is not gitignored: $DR_Q213_IGN"
  fi
  rm -f "$DR_Q213_IGN"
fi
[ "$DR_Q213_MADE_DIR" -eq 1 ] && rmdir "$DR_Q213_IGN_DIR" 2>/dev/null || true

# (b) a gitignored *.log anywhere proves it is the.gitignore decision, not a
# hardcoded.codegraph special-case -> exit 0.
DR_Q213_LOG="$REPO_ROOT/.test-t213-stray-$$-${RANDOM:-x}.log"
if [ -e "$DR_Q213_LOG" ]; then
  _skip "check-drift.sh prunes a gitignored *.log file" "fixture collision: $DR_Q213_LOG"
else
  printf 'wrote %s\n' "$q213_home" > "$DR_Q213_LOG"
  if git -C "$REPO_ROOT" check-ignore -q "$DR_Q213_LOG"; then
    assert_exit "check-drift.sh prunes a gitignored *.log file" 0 -- \
      bash "$REPO_ROOT/scripts/check-drift.sh"
  else
    _fail "check-drift.sh prunes a gitignored *.log file" \
      "precondition failed: *.log not gitignored"
  fi
  rm -f "$DR_Q213_LOG"
fi

# (c) REGRESSION GUARD: an untracked-but-NOT-ignored (committable) file with the
# same machine path is STILL caught -> exit 1. Pins that narrowed the scan
# to gitignored-only; a future "tracked-only" switch would false-PASS here (the
# hazard in [[feedback_git_lsfiles_test_skips_untracked]]). Untracked-not-ignored
# is itself committable content, so this also covers the AC's "a tracked file
# still fails" without mutating the index.
DR_Q213_COMMIT="$REPO_ROOT/.test-t213-committable-$$-${RANDOM:-x}.md"
if [ -e "$DR_Q213_COMMIT" ]; then
  _skip "check-drift.sh still catches a committable machine path" "fixture collision: $DR_Q213_COMMIT"
else
  printf 'leak at %s\n' "$q213_home" > "$DR_Q213_COMMIT"
  if git -C "$REPO_ROOT" check-ignore -q "$DR_Q213_COMMIT"; then
    _skip "check-drift.sh still catches a committable machine path" \
      "unexpected: .md fixture is gitignored"
  else
    assert_exit "check-drift.sh still catches a committable machine path" 1 -- \
      bash "$REPO_ROOT/scripts/check-drift.sh"
  fi
  rm -f "$DR_Q213_COMMIT"
fi

# (d) AC literal + Codex adversarial F4: a TRACKED file with the machine path is
# STILL caught -> exit 1. Staged via `git add -f` (tracked via --cached), then
# UNSTAGED + removed immediately so no orphan survives (per
# [[feedback_orphan_staged_fixtures]]). Runs in CI (fresh clone) / isolated
# worktree, never operator-main.
DR_Q213_TRACKED="$REPO_ROOT/.test-t213-tracked-$$-${RANDOM:-x}.md"
if [ -e "$DR_Q213_TRACKED" ]; then
  _skip "check-drift.sh catches a TRACKED machine path" "fixture collision: $DR_Q213_TRACKED"
else
  printf 'leak at %s\n' "$q213_home" > "$DR_Q213_TRACKED"
  git -C "$REPO_ROOT" add -f -- "$DR_Q213_TRACKED" >/dev/null 2>&1
  assert_exit "check-drift.sh catches a TRACKED machine path" 1 -- \
    bash "$REPO_ROOT/scripts/check-drift.sh"
  git -C "$REPO_ROOT" reset -q -- "$DR_Q213_TRACKED" >/dev/null 2>&1 || true
  rm -f "$DR_Q213_TRACKED"
fi
unset q213_home DR_Q213_IGN_DIR DR_Q213_IGN DR_Q213_MADE_DIR DR_Q213_LOG DR_Q213_COMMIT DR_Q213_TRACKED

# --- content scans FAIL CLOSED on a listed-but-unreadable file -------
# A committable file `git ls-files` enumerates but the scanner cannot read must
# FAIL, never be silently skipped into a pass. Modeled as a file staged via
# `git add -f` then removed from the worktree: still in --cached (LISTED), absent
# on disk (grep cannot read it). The bash twin already fails closed via grep's
# exit-2 tri-state; this pins that contract and is the parity sibling of
# check-drift.ps1's new Test-ScanPath fail-closed (PS previously swallowed the
# ReadLines error via catch{}). Content carries no machine path / secret so the
# unreadable file is the sole failure cause. Index reset in cleanup; runs in CI /
# isolated worktree, never operator-main.
DR_Q248="$REPO_ROOT/.test-t248-unreadable-$$-${RANDOM:-x}.md"
if [ -e "$DR_Q248" ]; then
  _skip "check-drift.sh fails closed on an unreadable listed file" "fixture collision: $DR_Q248"
else
  printf 'placeholder\n' > "$DR_Q248"
  git -C "$REPO_ROOT" add -f -- "$DR_Q248" >/dev/null 2>&1
  rm -f "$DR_Q248"
  assert_exit "check-drift.sh fails closed on an unreadable listed file" 1 -- \
    bash "$REPO_ROOT/scripts/check-drift.sh"
  git -C "$REPO_ROOT" reset -q -- "$DR_Q248" >/dev/null 2>&1 || true
fi
unset DR_Q248

# --- --auto: multi-home drift gate (<TEAM>-394) -----------------------------
# `make drift` runs check-drift.sh --auto so the gate covers EVERY rendered
# harness home, not just $CLAUDE_CONFIG_DIR. Fixture: render a claude home and
# a codex home into space-containing paths (exercises the local.env
# backslash-unescape parse), name both in a synthetic local.env via
# AI_CONFIG_LOCAL_ENV, leave hermes unset. All env vars cleared so resolution
# comes from the fixture local.env, never operator machine state.
AU_DIR="$(mktemp -d)"
AU_CLAUDE="$AU_DIR/claude home"; AU_CODEX="$AU_DIR/codex home"
mkdir -p "$AU_CLAUDE" "$AU_CODEX"
AU_ENV1="$AU_DIR/le-claude"; make_local_env "$AU_ENV1" "$AU_CLAUDE"
AI_CONFIG_LOCAL_ENV="$AU_ENV1" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
AU_ENV2="$AU_DIR/le-codex"; make_codex_env "$AU_ENV2" "$AU_CODEX"
AI_CONFIG_LOCAL_ENV="$AU_ENV2" bash "$REPO_ROOT/scripts/install.sh" --harness codex >/dev/null 2>&1

# .agents co-render fixture: a codex build with AGENTS_DIR set mirrors the
# codex spine skills into the overlay byte-identically, preserves operator
# subdirs (Shape C), and writes an "agents" manifest the --auto gate covers.
# Space-containing path exercises the same local.env parse as the harness homes.
AU_AGENTS="$AU_DIR/agents overlay"
mkdir -p "$AU_AGENTS/skills/opskill"
printf 'operator content — must survive the co-render\n' > "$AU_AGENTS/skills/opskill/SKILL.md"
# A same-name subdir with NO prior agents manifest is a collision with
# operator content — the co-render must replace it with an N1-style warn.
mkdir -p "$AU_AGENTS/skills/session-agent"
printf 'stale hand copy — must be replaced with a warn\n' > "$AU_AGENTS/skills/session-agent/SKILL.md"
AU_ENV3="$AU_DIR/le-codex-agents"
{ printf 'CODEX_HOME=%q\n' "$AU_CODEX"
  printf 'OBSIDIAN_VAULT_PATH=%q\n' "/tmp/test-vault"
  printf 'AGENTS_DIR=%q\n' "$AU_AGENTS"
} > "$AU_ENV3"
# --dry-run never touches the overlay (the co-render runs only on a real install).
au_dry_out="$(AI_CONFIG_LOCAL_ENV="$AU_ENV3" bash "$REPO_ROOT/scripts/install.sh" --harness codex --dry-run 2>&1)"
assert_not_contains "--dry-run performs no co-render" "$au_dry_out" "co-rendered"
assert_exit "--dry-run writes no agents manifest" 1 -- test -f "$AU_AGENTS/.build-manifest.json"
au_co_out="$(AI_CONFIG_LOCAL_ENV="$AU_ENV3" bash "$REPO_ROOT/scripts/install.sh" --harness codex 2>&1)"; au_co_rc=$?
assert_eq "codex install with AGENTS_DIR set succeeds" "0" "$au_co_rc"
assert_contains "codex install co-renders the spine skills into AGENTS_DIR" \
  "$au_co_out" "co-rendered"
assert_contains "co-render N1-warns when replacing an unauthored same-name subdir" \
  "$au_co_out" "no prior co-render authored it"
assert_exit "co-rendered session-agent is byte-identical to the codex render" 0 -- \
  cmp -s "$AU_CODEX/skills/session-agent/SKILL.md" "$AU_AGENTS/skills/session-agent/SKILL.md"
assert_exit "operator (Shape C) subdir in the overlay survives the co-render" 0 -- \
  test -f "$AU_AGENTS/skills/opskill/SKILL.md"
au_mani_harness="$(jq -r '.harness' "$AU_AGENTS/.build-manifest.json" 2>/dev/null)"
assert_eq "agents manifest is labeled with its own harness name" "agents" "$au_mani_harness"

AU_AUTO_ENV="$AU_DIR/local.env"
{ printf 'CLAUDE_CONFIG_DIR=%q\n' "$AU_CLAUDE"
  printf 'CODEX_HOME=%q\n' "$AU_CODEX"
  printf 'AGENTS_DIR=%q\n' "$AU_AGENTS"
} > "$AU_AUTO_ENV"

au_out="$(env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u HERMES_HOME -u AGENTS_DIR \
  AI_CONFIG_LOCAL_ENV="$AU_AUTO_ENV" \
  bash "$REPO_ROOT/scripts/check-drift.sh" --auto 2>&1)"; au_rc=$?
assert_eq "--auto passes with three clean rendered homes" "0" "$au_rc"
assert_contains "--auto checked the claude home (local.env resolution, space in path)" \
  "$au_out" "checking claude render at $AU_CLAUDE"
assert_contains "--auto checked the codex home (local.env resolution, space in path)" \
  "$au_out" "checking codex render at $AU_CODEX"
assert_contains "--auto checked the agents co-render (local.env resolution, space in path)" \
  "$au_out" "checking agents render at $AU_AGENTS"
assert_contains "--auto skips the unset hermes home loudly" \
  "$au_out" "hermes (HERMES_HOME) not set; skipping"

# A hand-edit to a MIRRORED skill in the overlay is drift like any other
# render — the whole point of the agents manifest (a silent re-divergence
# between .agents and $CODEX_HOME is what makes codex's duplicate-name
# resolution ambiguous). The operator subdir stays exempt.
printf '\nHAND EDIT\n' >> "$AU_AGENTS/skills/closeout/SKILL.md"
au5_out="$(env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u HERMES_HOME -u AGENTS_DIR \
  AI_CONFIG_LOCAL_ENV="$AU_AUTO_ENV" \
  bash "$REPO_ROOT/scripts/check-drift.sh" --auto 2>&1)"; au5_rc=$?
assert_eq "--auto fails when the agents co-render drifts" "1" "$au5_rc"
assert_contains "--auto names the hand-edited mirrored skill" \
  "$au5_out" "skills/closeout/SKILL.md was hand-edited"
# Re-running the codex install re-converges the mirror (the cure path).
AI_CONFIG_LOCAL_ENV="$AU_ENV3" bash "$REPO_ROOT/scripts/install.sh" --harness codex >/dev/null 2>&1
assert_exit "re-render re-converges the drifted mirror" 0 -- \
  cmp -s "$AU_CODEX/skills/closeout/SKILL.md" "$AU_AGENTS/skills/closeout/SKILL.md"

# Stale-prune: a base the PRIOR agents manifest authored but the new build no
# longer produces must be deleted (panel finding — a removed spine capability
# must not survive as an unmanaged skill). Ownership rule: only prior-managed
# bases are pruned; the operator subdir stays.
mkdir -p "$AU_AGENTS/skills/zzz-gone"
printf 'stale managed copy\n' > "$AU_AGENTS/skills/zzz-gone/SKILL.md"
jq '.generated["skills/zzz-gone/SKILL.md"] = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$AU_AGENTS/.build-manifest.json" > "$AU_AGENTS/.build-manifest.json.tmp" \
  && mv "$AU_AGENTS/.build-manifest.json.tmp" "$AU_AGENTS/.build-manifest.json"
au_pr_out="$(AI_CONFIG_LOCAL_ENV="$AU_ENV3" bash "$REPO_ROOT/scripts/install.sh" --harness codex 2>&1)"
assert_contains "co-render prunes a prior-managed base absent from the new build" \
  "$au_pr_out" "pruned stale mirrored skill skills/zzz-gone"
assert_exit "pruned stale base is gone from the overlay" 1 -- test -e "$AU_AGENTS/skills/zzz-gone"
assert_exit "operator subdir survives the prune pass" 0 -- test -f "$AU_AGENTS/skills/opskill/SKILL.md"

# Relative AGENTS_DIR is rejected up front — a relative spelling of the live
# overlay would bypass the string-compare guard (panel finding).
AU_ENV4="$AU_DIR/le-codex-agents-rel"
{ printf 'CODEX_HOME=%q\n' "$AU_CODEX"
  printf 'OBSIDIAN_VAULT_PATH=%q\n' "/tmp/test-vault"
  printf 'AGENTS_DIR=%s\n' ".agents"
} > "$AU_ENV4"
au_rel_out="$(AI_CONFIG_LOCAL_ENV="$AU_ENV4" bash "$REPO_ROOT/scripts/install.sh" --harness codex 2>&1)"; au_rel_rc=$?
assert_eq "relative AGENTS_DIR fails the install" "1" "$au_rel_rc"
assert_contains "relative AGENTS_DIR rejection names the rule" \
  "$au_rel_out" "must be an absolute path"

# AGENTS_DIR aliasing the codex target is refused — the manifest rewrite
# would truncate the very codex manifest it reads (panel finding).
AU_ENV5="$AU_DIR/le-codex-agents-alias"
{ printf 'CODEX_HOME=%q\n' "$AU_CODEX"
  printf 'OBSIDIAN_VAULT_PATH=%q\n' "/tmp/test-vault"
  printf 'AGENTS_DIR=%q\n' "$AU_CODEX"
} > "$AU_ENV5"
au_alias_out="$(AI_CONFIG_LOCAL_ENV="$AU_ENV5" bash "$REPO_ROOT/scripts/install.sh" --harness codex 2>&1)"; au_alias_rc=$?
assert_eq "AGENTS_DIR == CODEX_HOME fails the install" "1" "$au_alias_rc"
assert_contains "overlap rejection names the disjointness rule" \
  "$au_alias_out" "must be disjoint"

# Drift in ONE home fails the whole gate — and the other homes still get
# checked (no fail-fast bail that would hide a second home's drift).
printf '\nHAND EDIT\n' >> "$AU_CLAUDE/skills/session-agent/SKILL.md"
au2_out="$(env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u HERMES_HOME -u AGENTS_DIR \
  AI_CONFIG_LOCAL_ENV="$AU_AUTO_ENV" \
  bash "$REPO_ROOT/scripts/check-drift.sh" --auto 2>&1)"; au2_rc=$?
assert_eq "--auto fails when one home drifts" "1" "$au2_rc"
assert_contains "--auto still checks the clean codex home after the claude failure" \
  "$au2_out" "checking codex render at $AU_CODEX"

# Env var wins over local.env AND a resolved-but-unrendered home FAILS the
# gate (panel F1: no missing-manifest fail-open — the old single-home Makefile
# recipe failed this case too; a deleted manifest must never read as green).
AU_EMPTY="$AU_DIR/empty"; mkdir -p "$AU_EMPTY"
au3_out="$(env -u CODEX_HOME -u HERMES_HOME \
  CLAUDE_CONFIG_DIR="$AU_EMPTY" AI_CONFIG_LOCAL_ENV="$AU_AUTO_ENV" \
  bash "$REPO_ROOT/scripts/check-drift.sh" --auto 2>&1)"; au3_rc=$?
assert_eq "--auto FAILS when a resolved home has no rendered manifest (no fail-open skip)" "1" "$au3_rc"
assert_contains "--auto env var wins over local.env (gate runs against the env dir)" \
  "$au3_out" "checking claude render at $AU_EMPTY (via env)"
assert_contains "--auto missing-manifest failure names the manifest" \
  "$au3_out" "no .build-manifest.json"

# Nothing resolvable at all (no env vars, missing local.env): every home skips
# and the gate exits 0 — the fresh-clone degrade contract `make verify` needs.
au4_out="$(env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u HERMES_HOME \
  AI_CONFIG_LOCAL_ENV="$AU_DIR/nonexistent.env" \
  bash "$REPO_ROOT/scripts/check-drift.sh" --auto 2>&1)"; au4_rc=$?
assert_eq "--auto exits 0 when nothing is resolvable (fresh-clone degrade)" "0" "$au4_rc"
assert_contains "--auto reports every unresolvable home" \
  "$au4_out" "claude (CLAUDE_CONFIG_DIR) not set; skipping"
rm -rf "$AU_DIR"
unset AU_DIR AU_CLAUDE AU_CODEX AU_ENV1 AU_ENV2 AU_AUTO_ENV AU_EMPTY
unset au_out au_rc au2_out au2_rc au3_out au3_rc au4_out au4_rc
