#!/usr/bin/env bash
# tests/install-orphan-hardening.test.sh
#
# Hardens scripts/install.sh's orphan-skill deletion loop against three attack
# classes surfaced by the adversarial review (Codex F-8):
#
# 1. Path traversal — manifest-supplied paths containing ".." / "." / "/"
# segments could cause rm -rf to escape $TARGET/skills/. The pre-fix
# loop derived $orphan from `split("/")[1]` of a manifest key WITHOUT
# sanitization; a hand-edited.build-manifest.json with key
# "skills/../etc/passwd" yielded $orphan = ".." and the candidate
# [-d "$TARGET/skills/$orphan" ] succeeded ($TARGET/skills/.. IS
# $TARGET). The empty hash-validation loop then never decremented
# all_stale from its initial value 1, and rm -rf "$TARGET/skills/.."
# resolved to rm -rf "$TARGET" — catastrophic on a populated harness.
#
# 2. Control characters — manifest-supplied names containing newlines / tabs /
# escape sequences / leading dots-with-prefix (.install-bak.*) could
# bypass shell-quoting assumptions or wipe in-flight backups.
#
# 3. Hash-match requires POSITIVE evidence — the original loop initialized
# all_stale=1 and only flipped to 0 on a confirmed mismatch. If the
# orphan dir had ZERO matching manifest entries (empty subdir, or
# manifest mismatch on key shape), the loop body never executed and the
# initial 1 survived → unrelated content got deleted. The hardened
# contract requires at least ONE file under the orphan path to be
# hash-validated against the manifest before deletion is allowed.
#
# Fixture discipline (per [[feedback_self_tripping_test_source]] +
# [[feedback_orphan_staged_fixtures]]):
#
# - Sentinel paths planted under temp dirs via mktemp -d; no real $TARGET
# contamination.
# - The manifest is hand-edited with the attack key AFTER the first install
# landed a clean baseline — we never ship a poisoned manifest as a tracked
# fixture.
# - Each block ends with `rm -rf "$<block>_DIR"`. The runner's `_fail` helper
# does NOT exit (it just increments TESTS_FAILED and continues), so the
# end-of-block cleanup runs even when assertions fail. The single
# exception: if `mktemp -d` itself errors, that block's setup never
# succeeds and there's nothing to clean.
# - Manifest-key construction uses runtime jq with literal-string args so the
# `..` / control-char tokens never appear as test-source literals that
# might trip future scanners.

if ! command -v jq >/dev/null 2>&1; then
  _skip "orphan-skill hardening (jq required)"
  return 0 2>/dev/null || exit 0
fi

# --- Q107-T1: positive control — well-formed orphan with hash-match deletes ---
# This pins the existing happy-path behavior survives the hardening rewrite —
# orphan cleanup must still work when the inputs are clean.
T1_DIR="$(mktemp -d)"
T1_TGT="$T1_DIR/tgt"; mkdir -p "$T1_TGT"
T1_ENV="$T1_DIR/local.env"
make_local_env "$T1_ENV" "$T1_TGT"

# First install — populates a clean state with current capability set.
AI_CONFIG_LOCAL_ENV="$T1_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Simulate a previous framework version having compiled an extra "que107-stale"
# skill: add it to the manifest with its on-disk hash, then re-install.
mkdir -p "$T1_TGT/skills/que107-stale"
printf -- '---\nname: que107-stale\ndescription: stale framework skill\n---\nstale body\n' \
  > "$T1_TGT/skills/que107-stale/SKILL.md"
T1_HASH="$(shasum -a 256 "$T1_TGT/skills/que107-stale/SKILL.md" | cut -d' ' -f1)"
jq --arg h "$T1_HASH" '.generated["skills/que107-stale/SKILL.md"] = $h' \
  "$T1_TGT/.build-manifest.json" > "$T1_TGT/.build-manifest.json.tmp"
mv "$T1_TGT/.build-manifest.json.tmp" "$T1_TGT/.build-manifest.json"

AI_CONFIG_LOCAL_ENV="$T1_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

if [ -d "$T1_TGT/skills/que107-stale" ]; then
  _fail "well-formed orphan with hash-match deleted" "skills/que107-stale still present"
else
  _pass "well-formed orphan with hash-match deleted"
fi

rm -rf "$T1_DIR"

# --- Q107-T2: path traversal `..` rejected with WARNING — $TARGET NOT wiped ---
# Hand-edit the OLD manifest to contain key "skills/<traversal-token>/x" with
# arbitrary hash. Pre-hardening: split("/")[1] yields the traversal token;
# [-d "$TARGET/skills/$orphan" ] succeeds ($TARGET/skills/.. == $TARGET).
# The dangerous path the pre-hardening code COULD reach is rm -rf
# "$TARGET/skills/..", but the attack only succeeds when the missing-file
# branch is also bypassed (i.e. orphan-named files actually exist with
# matching hashes on disk under the resolved path). POSIX rm refuses to
# remove paths ending in "/.." as a defense-in-depth floor at the OS layer
# — but the hardening contract requires that install.sh ACTIVELY rejects
# before reaching rm, printing a warning. The two assertions here (sentinel
# preserved + warning printed) distinguish active rejection from incidental
# rm-refusal.
T2_DIR="$(mktemp -d)"
T2_TGT="$T2_DIR/tgt"; mkdir -p "$T2_TGT"
T2_ENV="$T2_DIR/local.env"
make_local_env "$T2_ENV" "$T2_TGT"

AI_CONFIG_LOCAL_ENV="$T2_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Sentinel: an unrelated file directly under $TARGET (a sibling of skills/)
# whose survival proves $TARGET wasn't wiped by a traversal-driven rm.
printf 'sentinel content\n' > "$T2_TGT/que107-sentinel.txt"

# The traversal token is built at runtime from non-matching halves so the test
# source itself doesn't contain a literal `..` segment after `skills/`.
T2_TRAVERSAL="$(printf '%s%s' '.' '.')"
T2_KEY="skills/${T2_TRAVERSAL}/x"

# Hand-edit the OLD manifest: inject the attack key. Use jq --arg for safe
# literal-string handling.
jq --arg k "$T2_KEY" --arg h "deadbeef" '.generated[$k] = $h' \
  "$T2_TGT/.build-manifest.json" > "$T2_TGT/.build-manifest.json.tmp"
mv "$T2_TGT/.build-manifest.json.tmp" "$T2_TGT/.build-manifest.json"

# Re-install. Capture stderr — the hardened install.sh must emit a warning
# when it rejects the unsafe orphan name.
T2_LOG="$T2_DIR/install.log"
T2_EXIT=0
AI_CONFIG_LOCAL_ENV="$T2_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>"$T2_LOG" || T2_EXIT=$?

# $TARGET sentinel must survive (defense-in-depth assertion — even if the
# active rejection failed, POSIX rm should block; this is the catastrophic
# floor).
assert_file "\$TARGET sentinel preserved against \`..\` orphan attack" \
  "$T2_TGT/que107-sentinel.txt"

# Active rejection: install.sh must emit a warning naming the unsafe orphan
# value. The actual warning text is a contract detail of the hardening; the
# test asserts a token that the implementation MUST include.
T2_WARN="$(cat "$T2_LOG" 2>/dev/null || true)"
assert_contains "install.sh emits warning on \`..\` orphan rejection" \
  "$T2_WARN" "unsafe orphan"

# install.sh must NOT abort the install on rejection — log+skip is the contract.
assert_eq "install.sh exit code on \`..\` orphan rejection is 0" "0" "$T2_EXIT"

rm -rf "$T2_DIR"

# --- Q107-T3: current-dir `.` rejected with WARNING — skills/ NOT wiped ---
# Same attack class as T2 but the traversal token is single-dot. Same incidental
# POSIX rm protection applies — we assert active rejection via warning.
T3_DIR="$(mktemp -d)"
T3_TGT="$T3_DIR/tgt"; mkdir -p "$T3_TGT"
T3_ENV="$T3_DIR/local.env"
make_local_env "$T3_ENV" "$T3_TGT"

AI_CONFIG_LOCAL_ENV="$T3_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Plant a Shape C operator-authored skill — its survival proves skills/ wasn't
# wiped by the current-dir traversal.
mkdir -p "$T3_TGT/skills/que107-shape-c-survivor"
printf -- '---\nname: que107-shape-c-survivor\n---\nshape c body\n' \
  > "$T3_TGT/skills/que107-shape-c-survivor/SKILL.md"

# Inject current-dir traversal token via runtime literal — same shape pattern
# as T2 to avoid test-source `skills/./` literal.
T3_CURRENT="$(printf '%s' '.')"
T3_KEY="skills/${T3_CURRENT}/y"

jq --arg k "$T3_KEY" --arg h "cafebabe" '.generated[$k] = $h' \
  "$T3_TGT/.build-manifest.json" > "$T3_TGT/.build-manifest.json.tmp"
mv "$T3_TGT/.build-manifest.json.tmp" "$T3_TGT/.build-manifest.json"

T3_LOG="$T3_DIR/install.log"
T3_EXIT=0
AI_CONFIG_LOCAL_ENV="$T3_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>"$T3_LOG" || T3_EXIT=$?

assert_file "Shape C survivor preserved against \`.\` orphan attack" \
  "$T3_TGT/skills/que107-shape-c-survivor/SKILL.md"
T3_WARN="$(cat "$T3_LOG" 2>/dev/null || true)"
assert_contains "install.sh emits warning on \`.\` orphan rejection" \
  "$T3_WARN" "unsafe orphan"
assert_eq "install.sh exit code on \`.\` orphan rejection is 0" "0" "$T3_EXIT"

rm -rf "$T3_DIR"

# --- Q107-T4: control character (TAB) in orphan name rejected with WARNING ---
# Hand-edit the OLD manifest with a key whose subdir component embeds a TAB.
# Note: an LF-embedded name would get serialized by jq -r as two separate
# output lines (one before LF, one after), so each "half" would survive into
# orphan iteration as a benign-looking name — caught by the empty-evidence
# preservation guard (T5), not the control-char rejection guard. TAB is the
# canonical control-char rejection case because jq -r preserves TAB
# in-line without splitting the output.
T4_DIR="$(mktemp -d)"
T4_TGT="$T4_DIR/tgt"; mkdir -p "$T4_TGT"
T4_ENV="$T4_DIR/local.env"
make_local_env "$T4_ENV" "$T4_TGT"

AI_CONFIG_LOCAL_ENV="$T4_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Plant a Shape C survivor — its preservation proves the control-char-named
# orphan didn't sweep adjacent skills.
mkdir -p "$T4_TGT/skills/que107-t4-survivor"
printf -- '---\nname: que107-t4-survivor\n---\nbody\n' \
  > "$T4_TGT/skills/que107-t4-survivor/SKILL.md"

# Construct a TAB-embedded subdir name at runtime ($'...' is a bash-only
# literal but tests run under bash).
T4_TAB_NAME=$'attacker\tname'
T4_KEY="skills/${T4_TAB_NAME}/z"

jq --arg k "$T4_KEY" --arg h "feedface" '.generated[$k] = $h' \
  "$T4_TGT/.build-manifest.json" > "$T4_TGT/.build-manifest.json.tmp"
mv "$T4_TGT/.build-manifest.json.tmp" "$T4_TGT/.build-manifest.json"

T4_LOG="$T4_DIR/install.log"
T4_EXIT=0
AI_CONFIG_LOCAL_ENV="$T4_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>"$T4_LOG" || T4_EXIT=$?

assert_file "survivor preserved against control-char orphan attack" \
  "$T4_TGT/skills/que107-t4-survivor/SKILL.md"
T4_WARN="$(cat "$T4_LOG" 2>/dev/null || true)"
assert_contains "install.sh emits warning on control-char orphan rejection" \
  "$T4_WARN" "unsafe orphan"
assert_eq "install.sh exit code on control-char rejection is 0" "0" "$T4_EXIT"

rm -rf "$T4_DIR"

# --- Q107-T5: orphan dir with zero manifest path-matches is preserved ---
#
# Demonstrates the all_stale=1-initial-survives-empty-loop gap. Pre-hardening:
# the OLD manifest *names* `<orphan>` as managed (via `split("/")[1]` value)
# but contains ZERO entries whose.key starts with `skills/<orphan>/`. The
# inner while-read loop iterates every manifest entry; the case-match
# `skills/<orphan>/*` never fires → loop body never executes → all_stale
# stays at the initial value 1 → rm -rf deletes the on-disk content.
#
# The trick that surfaces this state cleanly: a manifest entry whose key shape
# is `skills/<orphan>` (no trailing slash, no nested file) — `split("/")[1]`
# yields `<orphan>`, qualifying it for the orphans list, but the inner case
# `skills/<orphan>/*` requires a `/` after `<orphan>` and never matches.
T5_DIR="$(mktemp -d)"
T5_TGT="$T5_DIR/tgt"; mkdir -p "$T5_TGT"
T5_ENV="$T5_DIR/local.env"
make_local_env "$T5_ENV" "$T5_TGT"

AI_CONFIG_LOCAL_ENV="$T5_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Plant a dir with operator-authored content — should survive any cleanup.
mkdir -p "$T5_TGT/skills/que107-no-evidence"
printf 'operator content\n' > "$T5_TGT/skills/que107-no-evidence/operator-file.md"

# Manifest key shape: "skills/que107-no-evidence" (no trailing path) so
# split("/")[1] yields "que107-no-evidence" but the inner case-match
# `skills/que107-no-evidence/*` finds nothing. This isolates the
# all_stale-initial-1-survives bug from the hash-mismatch branch.
jq --arg k "skills/que107-no-evidence" --arg h "0000abcd" \
  '.generated[$k] = $h' \
  "$T5_TGT/.build-manifest.json" > "$T5_TGT/.build-manifest.json.tmp"
mv "$T5_TGT/.build-manifest.json.tmp" "$T5_TGT/.build-manifest.json"

T5_EXIT=0
AI_CONFIG_LOCAL_ENV="$T5_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1 || T5_EXIT=$?

# The operator-authored file MUST survive — zero hash-validated evidence under
# this orphan name means there's nothing for the loop to confirm-stale-against;
# the hardened contract requires positive hash evidence before deletion.
assert_file "orphan dir without hash evidence is preserved" \
  "$T5_TGT/skills/que107-no-evidence/operator-file.md"
assert_eq "install.sh exit code on no-hash-evidence preservation is 0" "0" "$T5_EXIT"

rm -rf "$T5_DIR"

# --- Q107-T6: LF in manifest key — scope-doc test ---
# Documents the LF case explicitly: jq -r emits an internal LF as an output
# line break, so a manifest key like "skills/<half-a>${LF}<half-b>/x" yields
# TWO orphan candidates ("<half-a>" and "<half-b>") rather than one. Neither
# half matches the control-char rejection guard (they're benign by then), but
# the empty-evidence guard (T5) protects both: no manifest entry matches
# "skills/<half-a>/*" or "skills/<half-b>/*". The exact assertion: an
# operator-authored Shape C skill named with one of the LF-half values
# survives.
T6_DIR="$(mktemp -d)"
T6_TGT="$T6_DIR/tgt"; mkdir -p "$T6_TGT"
T6_ENV="$T6_DIR/local.env"
make_local_env "$T6_ENV" "$T6_TGT"

AI_CONFIG_LOCAL_ENV="$T6_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Plant Shape C skills whose names happen to collide with the LF-halves; their
# survival proves the LF-driven false-positive orphans were correctly preserved
# by the empty-evidence guard.
mkdir -p "$T6_TGT/skills/que107-lf-half-a"
printf 'half-a\n' > "$T6_TGT/skills/que107-lf-half-a/SKILL.md"
mkdir -p "$T6_TGT/skills/que107-lf-half-b"
printf 'half-b\n' > "$T6_TGT/skills/que107-lf-half-b/SKILL.md"

# Inject LF-bearing key at runtime.
T6_LF_NAME=$(printf 'que107-lf-half-a\nque107-lf-half-b')
T6_KEY="skills/${T6_LF_NAME}/z"
jq --arg k "$T6_KEY" --arg h "deadbeef" '.generated[$k] = $h' \
  "$T6_TGT/.build-manifest.json" > "$T6_TGT/.build-manifest.json.tmp"
mv "$T6_TGT/.build-manifest.json.tmp" "$T6_TGT/.build-manifest.json"

T6_EXIT=0
AI_CONFIG_LOCAL_ENV="$T6_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1 || T6_EXIT=$?

assert_file "LF-driven false-positive orphan half-a preserved" \
  "$T6_TGT/skills/que107-lf-half-a/SKILL.md"
assert_file "LF-driven false-positive orphan half-b preserved" \
  "$T6_TGT/skills/que107-lf-half-b/SKILL.md"
assert_eq "install.sh exit code on LF-driven preservation is 0" "0" "$T6_EXIT"

rm -rf "$T6_DIR"

# --- Q107-T7: symlink orphan rejected with WARNING ---
# Adversarial pass finding (Codex). A symlinked orphan directory would have
# rm -rf only remove the link itself, but the hash validation reads under
# $TARGET/$rel follow the symlink. That asymmetry is not what the hash gate is
# designed to handle; the hardened contract rejects the symlink case before
# any filesystem reads.
T7_DIR="$(mktemp -d)"
T7_TGT="$T7_DIR/tgt"; mkdir -p "$T7_TGT"
T7_ENV="$T7_DIR/local.env"
make_local_env "$T7_ENV" "$T7_TGT"

AI_CONFIG_LOCAL_ENV="$T7_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Plant an out-of-tree directory + symlink into $TARGET/skills/que107-symlink.
mkdir -p "$T7_DIR/external/que107-symlink-source"
printf 'external content\n' > "$T7_DIR/external/que107-symlink-source/SKILL.md"
ln -s "$T7_DIR/external/que107-symlink-source" "$T7_TGT/skills/que107-symlink"

# Inject manifest key under skills/que107-symlink/ — the validation would
# read the symlinked file, but the rejection must fire first.
EXT_HASH="$(shasum -a 256 "$T7_TGT/skills/que107-symlink/SKILL.md" | cut -d' ' -f1)"
jq --arg k "skills/que107-symlink/SKILL.md" --arg h "$EXT_HASH" \
  '.generated[$k] = $h' \
  "$T7_TGT/.build-manifest.json" > "$T7_TGT/.build-manifest.json.tmp"
mv "$T7_TGT/.build-manifest.json.tmp" "$T7_TGT/.build-manifest.json"

T7_LOG="$T7_DIR/install.log"
T7_EXIT=0
AI_CONFIG_LOCAL_ENV="$T7_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>"$T7_LOG" || T7_EXIT=$?

# Symlink itself MUST survive (active rejection should fire before rm).
if [ -L "$T7_TGT/skills/que107-symlink" ]; then
  _pass "symlink orphan preserved against deletion attempt"
else
  _fail "symlink orphan preserved against deletion attempt" \
    "symlink at skills/que107-symlink was removed (T7_EXIT=$T7_EXIT)"
fi
# External target MUST also survive.
assert_file "external symlink target preserved" \
  "$T7_DIR/external/que107-symlink-source/SKILL.md"
T7_WARN="$(cat "$T7_LOG" 2>/dev/null || true)"
assert_contains "install.sh emits warning on symlink orphan rejection" \
  "$T7_WARN" "symlink"
assert_eq "install.sh exit code on symlink orphan rejection is 0" "0" "$T7_EXIT"

rm -rf "$T7_DIR"

# --- Q107-T8: jq manifest enumeration failure → orphan cleanup skipped ---
# Adversarial pass finding (Codex). If jq fails to parse the OLD manifest
# (corrupt JSON, jq crash, etc.), the pre-hardening code silently treated the
# resulting empty stream as "no orphans to validate" and proceeded. With the
# all_stale=1 initial value, this was harmless on the no-orphan path, but
# combined with hand-edited or partially-corrupted manifests, a subset of
# manifest entries could process before a parse error, leaving some orphan
# cleanups in an inconsistent state. The hardened contract: any non-zero jq
# exit aborts orphan cleanup entirely (we'd rather LEAVE stale skills than
# risk a partial validation deleting operator content).
#
# T8-strength (Codex 2026-06-17 cross-model review of the PS-twin port): the
# prior fixture planted a Shape C file that was NEVER manifest-authored. A
# Shape C subdir is not a hash-gated orphan candidate, so it survives whether
# or not cleanup correctly skipped — the preservation assertion proved nothing
# about the destructive path. We now plant a subdir constructed EXACTLY like
# the T1 deletion target (a genuine stale orphan) and assert IT survives, so
# the assertion rides on a REAL deletion candidate (T1 proves it is deletable
# on a valid manifest) instead of a file that survives unconditionally.
#
# Subtlety: corrupting the OLD manifest destroys its `.generated` entry, so the
# "would-be-deleted" property is NOT re-derivable inside this test — no valid
# manifest is left to enumerate against. It is established by CONSTRUCTION-
# PARALLEL to T1 (identical render + on-disk hash + manifest authorship), which
# T1 independently proves leads to deletion on a valid manifest.
#
# Scope of proof (Codex cross-model review, conf-75): this asserts the safe
# OUTCOME — a real, T1-deletable candidate is NOT removed on corrupt input — it
# does NOT isolate the explicit `manifest enumeration failed` abort. Corrupt
# input fails safe at TWO independent points: orphan ENUMERATION reads the same
# OLD manifest (its jq yields an empty managed set, so the rm -rf loop has
# nothing to iterate) AND the abort returns before that loop. A fixture cannot
# single out the abort, since deletion needs the (corrupt) manifest for both
# enumeration and the hash gate; isolating it alone would require harness
# instrumentation of the loop, deliberately out of scope.
T8_DIR="$(mktemp -d)"
T8_TGT="$T8_DIR/tgt"; mkdir -p "$T8_TGT"
T8_ENV="$T8_DIR/local.env"
make_local_env "$T8_ENV" "$T8_TGT"

AI_CONFIG_LOCAL_ENV="$T8_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Plant a GENUINE stale-orphan candidate, constructed EXACTLY like the T1
# deletion target: render skills/que107-t8-orphan/SKILL.md and record its
# on-disk hash in the OLD manifest. On a VALID manifest this is a confirmed
# stale orphan — manifest-authored, hash-matched, absent from the NEW build —
# i.e. the precise shape T1 proves WOULD be deleted. (We author the manifest
# entry for construction fidelity even though the corruption below destroys it;
# see the block-header subtlety.)
mkdir -p "$T8_TGT/skills/que107-t8-orphan"
printf -- '---\nname: que107-t8-orphan\ndescription: stale framework skill\n---\nstale body\n' \
  > "$T8_TGT/skills/que107-t8-orphan/SKILL.md"
T8_HASH="$(shasum -a 256 "$T8_TGT/skills/que107-t8-orphan/SKILL.md" | cut -d' ' -f1)"
jq --arg h "$T8_HASH" '.generated["skills/que107-t8-orphan/SKILL.md"] = $h' \
  "$T8_TGT/.build-manifest.json" > "$T8_TGT/.build-manifest.json.tmp"
mv "$T8_TGT/.build-manifest.json.tmp" "$T8_TGT/.build-manifest.json"

# Corrupt the manifest: replace with un-parseable text. This DESTROYS the
# que107-t8-orphan entry just authored — which is the point: the candidate's
# would-be-deleted property is carried by the T1-identical construction above,
# NOT by anything readable now. The OLD manifest is what install.sh reads to
# enumerate orphans; the NEW manifest at $BUILD/... is fresh and well-formed.
printf 'not valid json {{{\n' > "$T8_TGT/.build-manifest.json"

T8_LOG="$T8_DIR/install.log"
T8_EXIT=0
AI_CONFIG_LOCAL_ENV="$T8_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>"$T8_LOG" || T8_EXIT=$?

# The stale-orphan candidate MUST survive: a corrupt OLD manifest yields an
# empty orphan set AND triggers the enumeration-failed abort, so the rm -rf
# loop never runs against a real deletion candidate. Asserting on a subdir T1
# proves is deletable on a valid manifest is the meaningful signal — an
# unrelated Shape C file would have survived regardless and proved nothing.
assert_file "stale-orphan candidate preserved on corrupt-manifest path" \
  "$T8_TGT/skills/que107-t8-orphan/SKILL.md"
# A warning explaining the skip MUST be printed.
T8_WARN="$(cat "$T8_LOG" 2>/dev/null || true)"
assert_contains "install.sh emits warning on corrupt-manifest enumeration" \
  "$T8_WARN" "manifest enumeration failed"
assert_eq "install.sh exit code on corrupt-manifest skip is 0" "0" "$T8_EXIT"

rm -rf "$T8_DIR"
