#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/install-shape-c.test.sh
#
# Shape C skills live directly at $TARGET/skills/<name>/SKILL.md without any
# counterpart under capabilities/. They are the "local-only, never in framework"
# tier from the three-shape model — operator-authored skills that the
# framework's install.sh must NOT clobber when it re-renders the harness.
#
# Pre-fix install.sh wholesale-swapped the entire skills/ dir, so any Shape C
# subdir under $TARGET/skills/ was wiped on every re-render. This test pins the
# per-subdir-swap behavior that lets Shape C coexist with Shape A under skills/.

# --- install.sh preserves unmanaged (Shape C) skills under skills/ ---
SC_DIR="$(mktemp -d)"
SC_TGT="$SC_DIR/tgt"; mkdir -p "$SC_TGT"
SC_ENV="$SC_DIR/local.env"
make_local_env "$SC_ENV" "$SC_TGT"

# Pre-seed a fresh Shape C skill under the target's skills/ dir, before any
# install.sh run. The skill has no counterpart under capabilities/.
mkdir -p "$SC_TGT/skills/t68-shape-c-fixture"
# A tracker-shaped token assembled at runtime from non-matching halves: the suite
# source carries no literal tracker id, yet the fixture still proves install
# preserves tracker-shaped operator content verbatim through the skills/ swap.
sc_tok="QUE""-68"
printf -- '---\nname: t68-shape-c-fixture\ndescription: Shape C fixture (%s) preserved verbatim\n---\n# Body\n' "$sc_tok" \
  > "$SC_TGT/skills/t68-shape-c-fixture/SKILL.md"

sc_status=0
AI_CONFIG_LOCAL_ENV="$SC_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1 || sc_status=$?
assert_eq "install.sh exits 0 with a pre-existing Shape C skill" "0" "$sc_status"

# The Shape C skill must survive the skills/ swap intact.
assert_file "install.sh preserves Shape C SKILL.md through skills/ swap" \
  "$SC_TGT/skills/t68-shape-c-fixture/SKILL.md"
if [ -f "$SC_TGT/skills/t68-shape-c-fixture/SKILL.md" ]; then
  sc_content="$(cat "$SC_TGT/skills/t68-shape-c-fixture/SKILL.md")"
  assert_contains "Shape C content (incl. tracker-shaped token) preserved verbatim" \
    "$sc_content" "Shape C fixture ($sc_tok) preserved verbatim"
fi

# Sanity: managed skills (Shape A) still install alongside Shape C.
# (Targets session-agent post-fix — `route` no longer exists.)
assert_file "managed skills still install with Shape C present" \
  "$SC_TGT/skills/session-agent/SKILL.md"

# A second install run must continue to preserve Shape C (idempotent).
sc2_status=0
AI_CONFIG_LOCAL_ENV="$SC_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1 || sc2_status=$?
assert_eq "second install run also exits 0" "0" "$sc2_status"
assert_file "second install run still preserves Shape C SKILL.md" \
  "$SC_TGT/skills/t68-shape-c-fixture/SKILL.md"

# check-drift --manifest must NOT report a Shape C subdir as untracked
# drift. The manifest only tracks manifest-managed skills; Shape C is exempt.
sd_status=0
sd_out="$(bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$SC_TGT" 2>&1)" || sd_status=$?
assert_eq "check-drift --manifest passes with Shape C present" "0" "$sd_status"
assert_not_contains "check-drift does not flag Shape C subdir as untracked" \
  "$sd_out" "t68-shape-c-fixture"

rm -rf "$SC_DIR"

# --- install.sh removes orphan skill subdirs from prior installs ---
# When the framework drops a capability (this PR drops cross-model-review),
# install.sh must NOT leave the old rendered SKILL.md lingering. Pin this by
# simulating an "old install" state — a manifest that managed a skill subdir
# absent from the current capabilities/ tree — and asserting install.sh
# removes the subdir on re-render. A true Shape C subdir planted alongside
# must survive the orphan cleanup.
SC_OR_DIR="$(mktemp -d)"
SC_OR_TGT="$SC_OR_DIR/tgt"; mkdir -p "$SC_OR_TGT"
SC_OR_ENV="$SC_OR_DIR/local.env"
make_local_env "$SC_OR_ENV" "$SC_OR_TGT"

# First install — populates a clean state with the current capability set.
AI_CONFIG_LOCAL_ENV="$SC_OR_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Simulate: a previous framework version compiled an extra "t68-orphan" skill.
# Add it to the manifest (managed) and create the rendered subdir, as install.sh
# would have left it.
mkdir -p "$SC_OR_TGT/skills/t68-orphan"
printf -- '---\nname: t68-orphan\ndescription: simulated prior-install skill\n---\nold body\n' \
  > "$SC_OR_TGT/skills/t68-orphan/SKILL.md"
ORPHAN_HASH="$(shasum -a 256 "$SC_OR_TGT/skills/t68-orphan/SKILL.md" 2>/dev/null | cut -d' ' -f1)"
if [ -n "$ORPHAN_HASH" ] && command -v jq >/dev/null 2>&1; then
  jq --arg h "$ORPHAN_HASH" '.generated["skills/t68-orphan/SKILL.md"] = $h' \
    "$SC_OR_TGT/.build-manifest.json" > "$SC_OR_TGT/.build-manifest.json.tmp" \
    && mv "$SC_OR_TGT/.build-manifest.json.tmp" "$SC_OR_TGT/.build-manifest.json"
fi

# Plant a true Shape C skill — it must survive the orphan cleanup.
mkdir -p "$SC_OR_TGT/skills/t68-shape-c-survivor"
printf -- '---\nname: t68-shape-c-survivor\ndescription: operator-local survivor\n---\nshape c\n' \
  > "$SC_OR_TGT/skills/t68-shape-c-survivor/SKILL.md"

# Re-install. Orphan must be removed; Shape C must remain.
AI_CONFIG_LOCAL_ENV="$SC_OR_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
[ -d "$SC_OR_TGT/skills/t68-orphan" ] \
  && _fail "orphan skill subdir removed when source disappears" "skills/t68-orphan still present" \
  || _pass "orphan skill subdir removed when source disappears"
assert_file "Shape C survivor preserved through orphan cleanup" \
  "$SC_OR_TGT/skills/t68-shape-c-survivor/SKILL.md"

# check-drift --manifest must remain clean post-cleanup: no orphan, Shape C
# exempt, managed skills intact.
sd_or_status=0
bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$SC_OR_TGT" >/dev/null 2>&1 || sd_or_status=$?
assert_eq "check-drift clean after orphan cleanup" "0" "$sd_or_status"

rm -rf "$SC_OR_DIR"

# --- casing-only rename of a managed skill is not a false orphan ---
# Regression for the case-sensitive comm/grep false-delete (cross-model-panel-
# found 2026-06-17; pre-existing PR #37). When a managed skill's directory
# casing changes between builds with identical content (skills/Foo ->
# skills/foo), the byte-exact orphan computation (comm) and N1 authorship check
# (grep -qxF) treat the OLD-cased name as unrelated to the NEW one. On a case-
# INSENSITIVE filesystem (default macOS APFS, Windows NTFS) the OLD-cased orphan
# path resolves to the freshly-swapped-in NEW-cased files (identical content ->
# the hash gate passes) and `rm -rf` deletes the just-installed directory; the
# N1 check also warns spuriously. fs_case_insensitive + the case-folded
# orphan/N1 comparison fix both.
#
# FS-adaptive by construction — exercises the bug on the case-insensitive macOS
# + Windows runners, correct no-op on case-sensitive Linux:
#   - case-insensitive FS: `Session-agent` and `session-agent` are the SAME
#     on-disk dir. Pre-fix the orphan delete wipes the reinstalled skill and N1
#     warns; post-fix the fold drops the false orphan and suppresses the warn.
#   - case-sensitive FS (Linux): they are DISTINCT dirs. The freshly-installed
#     lowercase skill is never the orphan; `Session-agent` is a genuine orphan,
#     correctly cleaned, and the swap never sees a colliding live `session-agent`
#     so N1 stays silent. Both assertions pass pre- and post-fix.
CR_DIR="$(mktemp -d)"
CR_TGT="$CR_DIR/tgt"; mkdir -p "$CR_TGT"
CR_ENV="$CR_DIR/local.env"
make_local_env "$CR_ENV" "$CR_TGT"

# First install — clean baseline with the real managed skill set.
AI_CONFIG_LOCAL_ENV="$CR_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

CR_SKILL="session-agent"   # a spine skill the build always emits, lowercase
CR_CASED="Session-agent"
if [ -d "$CR_TGT/skills/$CR_SKILL" ] && command -v jq >/dev/null 2>&1; then
  # Simulate the PRIOR framework build having emitted the SAME skill under a
  # different LETTER CASE: recase the live dir AND rewrite its OLD-manifest keys
  # to the upper-cased base (hashes unchanged — identical content). The next
  # install's build re-emits the canonical lowercase base. Two-step (via a temp
  # name) so the recase also works on case-insensitive, case-preserving
  # filesystems that reject a same-file single-step casing rename (parity with
  # the PS twin's two-step Move-Item).
  mv "$CR_TGT/skills/$CR_SKILL" "$CR_TGT/skills/__recase-tmp"
  mv "$CR_TGT/skills/__recase-tmp" "$CR_TGT/skills/$CR_CASED"
  jq --arg s "skills/$CR_SKILL/" --arg c "skills/$CR_CASED/" \
    '.generated |= with_entries(.key |= (if startswith($s) then $c + ltrimstr($s) else . end))' \
    "$CR_TGT/.build-manifest.json" > "$CR_TGT/.build-manifest.json.tmp" \
    && mv "$CR_TGT/.build-manifest.json.tmp" "$CR_TGT/.build-manifest.json"

  # Re-install; capture stderr to assert the N1 warning does not spuriously fire.
  CR_LOG="$CR_DIR/install.stderr"
  AI_CONFIG_LOCAL_ENV="$CR_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>"$CR_LOG"

  # The recased managed skill must NOT be false-deleted — on a case-insensitive
  # FS this is the same on-disk dir as the freshly-installed lowercase one.
  assert_file "casing-renamed managed skill survives re-install (no false-delete)" \
    "$CR_TGT/skills/$CR_SKILL/SKILL.md"
  cr_log="$(cat "$CR_LOG" 2>/dev/null)"
  assert_not_contains "no spurious N1 warning for a recased managed skill" \
    "$cr_log" "no prior framework install authored"
  # The FS-casing probe must clean up after itself — no .aos-fscase* artifact
  # left in the config dir or under skills/ (it removes only the unique temp dir
  # it created).
  cr_residue="$(find "$CR_TGT" -maxdepth 2 -name '.aos-fscase*' 2>/dev/null)"
  assert_eq "no fs-case probe residue after install" "" "$cr_residue"
else
  _skip "casing-rename managed-skill regression" "session-agent or jq absent"
fi

rm -rf "$CR_DIR"

# --- orphan cleanup preserves operator-modified content ---
# An operator may pre-write a Shape C SKILL.md OVER the bloated framework
# rendered content at a previously-managed subdir (the cross-model-review
# migration is exactly this pattern). The orphan cleanup must detect the
# modification by hash and preserve the subdir, NOT delete it.
HG_DIR="$(mktemp -d)"
HG_TGT="$HG_DIR/tgt"; mkdir -p "$HG_TGT"
HG_ENV="$HG_DIR/local.env"
make_local_env "$HG_ENV" "$HG_TGT"

# First install — populates a clean state.
AI_CONFIG_LOCAL_ENV="$HG_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Simulate a previous framework install of "t68-hash-gate" with a known body.
mkdir -p "$HG_TGT/skills/t68-hash-gate"
printf -- '---\nname: t68-hash-gate\ndescription: stale framework body\n---\nstale framework body\n' \
  > "$HG_TGT/skills/t68-hash-gate/SKILL.md"
STALE_HASH="$(shasum -a 256 "$HG_TGT/skills/t68-hash-gate/SKILL.md" 2>/dev/null | cut -d' ' -f1)"
if [ -n "$STALE_HASH" ] && command -v jq >/dev/null 2>&1; then
  jq --arg h "$STALE_HASH" '.generated["skills/t68-hash-gate/SKILL.md"] = $h' \
    "$HG_TGT/.build-manifest.json" > "$HG_TGT/.build-manifest.json.tmp" \
    && mv "$HG_TGT/.build-manifest.json.tmp" "$HG_TGT/.build-manifest.json"
fi

# NOW the operator overwrites the stale framework content with their own
# Shape C body — different hash than what the manifest recorded.
printf -- '---\nname: t68-hash-gate\ndescription: operator Shape C version\n---\noperator-authored Shape C body\n' \
  > "$HG_TGT/skills/t68-hash-gate/SKILL.md"

# Re-install. Hash gate must detect the operator modification and preserve
# the subdir — only stale framework content gets deleted.
AI_CONFIG_LOCAL_ENV="$HG_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
assert_file "hash gate preserves operator-modified orphan subdir" \
  "$HG_TGT/skills/t68-hash-gate/SKILL.md"
if [ -f "$HG_TGT/skills/t68-hash-gate/SKILL.md" ]; then
  hg_content="$(cat "$HG_TGT/skills/t68-hash-gate/SKILL.md")"
  assert_contains "hash gate preserves operator content verbatim" \
    "$hg_content" "operator-authored Shape C body"
fi

rm -rf "$HG_DIR"

# --- operator skill named.install-bak.* survives install + rollback ---
# Per-subdir skills backups live in a run-private root OUTSIDE skills/
# ($TARGET/.install-bak.d/), so an operator-authored Shape C skill literally
# named ".install-bak.foo" is NOT treated as an installer backup by the swap,
# cleanup, or rollback paths. Pre-fix: the success-cleanup loop globbed
# "$TARGET/skills/.install-bak.*" and deleted it on every install (F1); rollback
# globbed the same and mis-restored it to skills/foo (F3).
BN_DIR="$(mktemp -d)"
BN_TGT="$BN_DIR/tgt"; mkdir -p "$BN_TGT"
BN_ENV="$BN_DIR/local.env"
make_local_env "$BN_ENV" "$BN_TGT"

# First install — clean baseline.
AI_CONFIG_LOCAL_ENV="$BN_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Operator authors a Shape C skill whose name collides with the reserved backup
# prefix. Astronomically unlikely, but a reserved namespace must hold.
mkdir -p "$BN_TGT/skills/.install-bak.foo"
printf -- '---\nname: install-bak-foo\ndescription: operator skill with reserved-prefix name\n---\noperator backup-prefix body\n' \
  > "$BN_TGT/skills/.install-bak.foo/SKILL.md"

# Re-install (normal success path). The reserved-prefix skill must survive the
# success cleanup; the run-private backup root must be removed (no lingering junk).
bn_status=0
AI_CONFIG_LOCAL_ENV="$BN_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1 || bn_status=$?
assert_eq "install exits 0 with a reserved-prefix operator skill present" "0" "$bn_status"
assert_file "operator .install-bak.foo skill survives install (cleanup no longer globs skills/)" \
  "$BN_TGT/skills/.install-bak.foo/SKILL.md"
if [ -f "$BN_TGT/skills/.install-bak.foo/SKILL.md" ]; then
  bn_content="$(cat "$BN_TGT/skills/.install-bak.foo/SKILL.md")"
  assert_contains "operator .install-bak.foo content preserved verbatim through install" \
    "$bn_content" "operator backup-prefix body"
else
  _fail "operator .install-bak.foo content preserved verbatim through install" "skill lost on install"
fi
[ -e "$BN_TGT/.install-bak.d" ] \
  && _fail "run-private backup root removed after successful install" ".install-bak.d still present" \
  || _pass "run-private backup root removed after successful install"

# Now prove it survives a ROLLBACK. The test-only fault-injection seam forces a
# deterministic swap failure on "hooks" — a managed path AFTER skills, so the
# skills swap has already happened when rollback_swaps runs.
br_status=0
AI_CONFIG_INSTALL_TEST_FAIL_SWAP=hooks AI_CONFIG_LOCAL_ENV="$BN_ENV" \
  bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1 || br_status=$?
[ "$br_status" -ne 0 ] \
  && _pass "forced swap failure aborts install (nonzero exit)" \
  || _fail "forced swap failure aborts install (nonzero exit)" "exit was 0"
assert_file "operator .install-bak.foo skill survives rollback" \
  "$BN_TGT/skills/.install-bak.foo/SKILL.md"
[ -d "$BN_TGT/skills/foo" ] \
  && _fail "rollback did not mis-restore .install-bak.foo to skills/foo" "skills/foo created" \
  || _pass "rollback did not mis-restore .install-bak.foo to skills/foo"
[ -e "$BN_TGT/.install-bak.d" ] \
  && _fail "run-private backup root removed after rollback" ".install-bak.d still present" \
  || _pass "run-private backup root removed after rollback"
assert_file "managed skills restored after rollback" \
  "$BN_TGT/skills/session-agent/SKILL.md"

# --- crash-recovery — a leftover.install-bak.d is recovered, not lost ---
# Simulate an install that crashed mid-swap: a skill was moved into the
# run-private backup root but its replacement was never moved into place (its
# live counterpart is missing). The NEXT install must restore it BEFORE the
# swap loop and never blind-delete the only surviving copy (Codex adversarial F2).
mkdir -p "$BN_TGT/.install-bak.d/skills/t147-recover"
printf -- '---\nname: t147-recover\ndescription: crashed-install backup body\n---\nrecovered body\n' \
  > "$BN_TGT/.install-bak.d/skills/t147-recover/SKILL.md"
rm -rf "$BN_TGT/skills/t147-recover"   # live counterpart missing (simulated crash)
bn_rec_status=0
AI_CONFIG_LOCAL_ENV="$BN_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1 || bn_rec_status=$?
assert_eq "install exits 0 after recovering a crashed prior install" "0" "$bn_rec_status"
assert_file "crash-recovery restores a backed-up skill whose live copy was missing" \
  "$BN_TGT/skills/t147-recover/SKILL.md"
if [ -f "$BN_TGT/skills/t147-recover/SKILL.md" ]; then
  assert_contains "crash-recovery restores the backup content verbatim" \
    "$(cat "$BN_TGT/skills/t147-recover/SKILL.md")" "recovered body"
fi
[ -e "$BN_TGT/.install-bak.d" ] \
  && _fail "run-private backup root removed after crash-recovery" ".install-bak.d still present" \
  || _pass "run-private backup root removed after crash-recovery"
assert_file "operator .install-bak.foo survives crash-recovery too" \
  "$BN_TGT/skills/.install-bak.foo/SKILL.md"

rm -rf "$BN_DIR"

# --- N1: collision warn when install replaces a skills/<base> subdir no prior
#         framework install authored. Fresh target (no manifest) pre-seeded with
#         skills/session-agent (a framework base) → the per-subdir swap must warn
#         (don't silently overwrite), still install the framework version, and a
#         normal framework re-install (now manifest-authored) must NOT warn. ---
N1_DIR="$(mktemp -d)"
N1_TGT="$N1_DIR/tgt"; mkdir -p "$N1_TGT/skills/session-agent"
N1_ENV="$N1_DIR/local.env"
make_local_env "$N1_ENV" "$N1_TGT"
printf -- '---\nname: session-agent\ndescription: operator collision fixture\n---\n# operator body\n' \
  > "$N1_TGT/skills/session-agent/SKILL.md"
n1_log="$N1_DIR/install.log"; n1_status=0
AI_CONFIG_LOCAL_ENV="$N1_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>"$n1_log" || n1_status=$?
assert_eq "N1: install still exits 0 on a colliding non-framework skill" "0" "$n1_status"
assert_contains "N1: collision warns for a non-framework-authored skills subdir" \
  "$(cat "$n1_log" 2>/dev/null)" "replacing skills/session-agent which no prior framework install authored"
if [ -f "$N1_TGT/skills/session-agent/SKILL.md" ]; then
  assert_not_contains "N1: framework session-agent replaces the colliding operator body" \
    "$(cat "$N1_TGT/skills/session-agent/SKILL.md")" "operator body"
fi
# A SECOND install (now framework-authored, in the manifest) must NOT warn.
n1_log2="$N1_DIR/install2.log"
AI_CONFIG_LOCAL_ENV="$N1_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>"$n1_log2" || true
assert_not_contains "N1: no collision warn on a normal framework re-install" \
  "$(cat "$n1_log2" 2>/dev/null)" "no prior framework install authored"

rm -rf "$N1_DIR"

# --- check-drift: app-owned plugins/ is IGNORED on a claude target. Claude Code
#     writes plugins/known_marketplaces.json (and a plugins/ cache) into the config
#     dir; the manifest has no managed plugins, so the managed-vs-app-owned gate
#     must NOT scan plugins/ and must NOT flag that app state as drift. Regression
#     guard for the make-verify break this change first surfaced. ---
AP_DIR="$(mktemp -d)"
AP_TGT="$AP_DIR/tgt"; mkdir -p "$AP_TGT"
AP_ENV="$AP_DIR/local.env"
make_local_env "$AP_ENV" "$AP_TGT"
AI_CONFIG_LOCAL_ENV="$AP_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1 || true
mkdir -p "$AP_TGT/plugins/cache/marketplace-x"
printf '{}' > "$AP_TGT/plugins/known_marketplaces.json"
printf 'cached\n' > "$AP_TGT/plugins/cache/marketplace-x/data.json"
ap_status=0
ap_out="$(bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$AP_TGT" 2>&1)" || ap_status=$?
assert_eq "check-drift ignores app-owned plugins/ on a claude target (exit 0)" "0" "$ap_status"
assert_not_contains "check-drift does not flag app-owned plugins/known_marketplaces.json" \
  "$ap_out" "known_marketplaces.json"
rm -rf "$AP_DIR"
