#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/install-dry-run.test.sh
#
# install.sh --dry-run classifies the LIVE target against the freshly-built NEW
# manifest and the OLD installed manifest, and REPORTS the state of every
# framework-managed file WITHOUT writing anything:
#   managed / missing / broken / custom / stale
# It is the install-side counterpart to check-drift.sh --manifest's pass/fail
# gate, and it surfaces a silently-stale installed config (the gap <TEAM>-298 #1
# plugs). This suite pins: the five classes, the no-write guarantee, the
# default-path-unchanged invariant, and that a real install (repair) restores
# managed/broken/missing files while PRESERVING operator-custom (Shape C) ones.

# Portable sha (mirrors install.sh's sha256()).
_dr_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
# Fingerprint a tree as "<relpath>\t<sha>" lines, sorted — for the no-write proof.
_dr_fingerprint() {
  ( cd "$1" && find . -type f | sort | while IFS= read -r f; do
      printf '%s\t%s\n' "$f" "$(_dr_sha "$f")"
    done )
}

DR_DIR="$(mktemp -d)"
DR_TGT="$DR_DIR/tgt"; mkdir -p "$DR_TGT"
DR_ENV="$DR_DIR/local.env"
make_local_env "$DR_ENV" "$DR_TGT"

# Fresh install so the target is fully in sync with the current framework.
dr_install=0
AI_CONFIG_LOCAL_ENV="$DR_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1 || dr_install=$?
assert_eq "install.sh exits 0 (dry-run setup)" "0" "$dr_install"

# --- 1) in-sync target: managed>0, zero stale/broken/missing ---------------
dr_status=0
dr_out="$(AI_CONFIG_LOCAL_ENV="$DR_ENV" bash "$REPO_ROOT/scripts/install.sh" --dry-run 2>/dev/null)" || dr_status=$?
assert_eq "--dry-run exits 0 on an in-sync target" "0" "$dr_status"
assert_contains "--dry-run announces it wrote nothing" "$dr_out" "no changes written (dry-run)"
assert_contains "in-sync target: stale 0"   "$dr_out" "stale:   0"
assert_contains "in-sync target: broken 0"  "$dr_out" "broken:  0"
assert_contains "in-sync target: missing 0" "$dr_out" "missing: 0"
assert_contains "in-sync target: declared in sync" "$dr_out" "in sync with the current framework"

# --- 2) --dry-run writes nothing: tree is byte-identical before/after -------
dr_fp_before="$(_dr_fingerprint "$DR_TGT")"
AI_CONFIG_LOCAL_ENV="$DR_ENV" bash "$REPO_ROOT/scripts/install.sh" --dry-run >/dev/null 2>&1 || true
dr_fp_after="$(_dr_fingerprint "$DR_TGT")"
assert_eq "--dry-run leaves the target byte-identical (writes nothing)" "$dr_fp_before" "$dr_fp_after"
# And it leaves no temp build dir behind.
dr_leftover="$(find "$DR_TGT" -maxdepth 1 -name '.install-build.*' 2>/dev/null)"
assert_eq "--dry-run leaves no .install-build.* temp dir" "" "$dr_leftover"

# --- 3) broken + missing + custom in one mutated target --------------------
printf '\nDRYRUN_BROKEN_MARKER\n' >> "$DR_TGT/CLAUDE.md"   # managed file hand-edited → broken
rm -f "$DR_TGT/SKILLS.md"                                  # managed file removed → missing
mkdir -p "$DR_TGT/skills/dry-run-custom-fixture"           # operator Shape C skill → custom
printf -- '---\nname: dry-run-custom-fixture\ndescription: Shape C fixture\n---\n# body\n' \
  > "$DR_TGT/skills/dry-run-custom-fixture/SKILL.md"

dr_out2="$(AI_CONFIG_LOCAL_ENV="$DR_ENV" bash "$REPO_ROOT/scripts/install.sh" --dry-run 2>/dev/null)"
assert_contains "hand-edited CLAUDE.md classified broken" "$dr_out2" "broken:  1"
assert_contains "broken list names CLAUDE.md"             "$dr_out2" "- CLAUDE.md"
assert_contains "removed SKILLS.md classified missing"    "$dr_out2" "missing: 1"
assert_contains "missing list names SKILLS.md"            "$dr_out2" "- SKILLS.md"
assert_contains "operator skill classified custom"        "$dr_out2" "custom:  1"
# The custom skill must NOT appear in any actionable (drift) list.
assert_not_contains "custom skill is not flagged as drift" "$dr_out2" "dry-run-custom-fixture"

# --- 4) repair: a real install restores managed/broken/missing, keeps custom -
dr_repair=0
AI_CONFIG_LOCAL_ENV="$DR_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1 || dr_repair=$?
assert_eq "install (repair) exits 0" "0" "$dr_repair"
assert_file "repair restored the missing SKILLS.md" "$DR_TGT/SKILLS.md"
if [ -f "$DR_TGT/CLAUDE.md" ]; then
  assert_not_contains "repair overwrote the broken CLAUDE.md (marker gone)" \
    "$(cat "$DR_TGT/CLAUDE.md")" "DRYRUN_BROKEN_MARKER"
fi
assert_file "repair PRESERVED the operator-custom skill" \
  "$DR_TGT/skills/dry-run-custom-fixture/SKILL.md"

# --- 5) stale: on-disk matches the OLD manifest but the NEW build differs ----
DR_TGT2="$DR_DIR/tgt2"; mkdir -p "$DR_TGT2"
DR_ENV2="$DR_DIR/local.env2"
make_local_env "$DR_ENV2" "$DR_TGT2"
AI_CONFIG_LOCAL_ENV="$DR_ENV2" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
# Overwrite a managed file, then rewrite the OLD manifest so the on-disk content
# matches the manifest — simulating "installed at an older framework state."
printf 'STALE-FRAMEWORK-STATE\n' > "$DR_TGT2/CLAUDE.md"
dr_stale_sha="$(_dr_sha "$DR_TGT2/CLAUDE.md")"
dr_man="$DR_TGT2/.build-manifest.json"
dr_man_tmp="$(mktemp)"
jq --arg h "$dr_stale_sha" '.generated["CLAUDE.md"] = $h' "$dr_man" > "$dr_man_tmp" && mv "$dr_man_tmp" "$dr_man"
dr_out3="$(AI_CONFIG_LOCAL_ENV="$DR_ENV2" bash "$REPO_ROOT/scripts/install.sh" --dry-run 2>/dev/null)"
assert_contains "matches-old-but-not-new classified stale" "$dr_out3" "stale:   1"
assert_contains "stale list names CLAUDE.md"               "$dr_out3" "- CLAUDE.md"
assert_contains "stale (not broken) — broken stays 0"      "$dr_out3" "broken:  0"
assert_contains "stale target prompts a reconcile"         "$dr_out3" "re-run without --dry-run to reconcile"

# --- 6) --dry-run rejects multi-harness (parity with --build-only) ----------
dr_multi=0
AI_CONFIG_LOCAL_ENV="$DR_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness claude --harness codex --dry-run >/dev/null 2>&1 || dr_multi=$?
assert_eq "--dry-run + multiple --harness is rejected (exit 1)" "1" "$dr_multi"

# --- 7) a managed path replaced by a DIRECTORY classifies broken, never aborts -
# (cross-model adversarial finding: hashing a dir/unreadable path would abort the
# report under set -e instead of reporting it.)
DR_TGT3="$DR_DIR/tgt3"; mkdir -p "$DR_TGT3"
DR_ENV3="$DR_DIR/local.env3"; make_local_env "$DR_ENV3" "$DR_TGT3"
AI_CONFIG_LOCAL_ENV="$DR_ENV3" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
rm -f "$DR_TGT3/CLAUDE.md"; mkdir -p "$DR_TGT3/CLAUDE.md"   # managed file → directory
dr_dir_status=0
dr_out_dir="$(AI_CONFIG_LOCAL_ENV="$DR_ENV3" bash "$REPO_ROOT/scripts/install.sh" --dry-run 2>/dev/null)" || dr_dir_status=$?
assert_eq "--dry-run exits 0 when a managed file is replaced by a directory" "0" "$dr_dir_status"
assert_contains "directory-where-a-file-is-expected classified broken" "$dr_out_dir" "broken:  1"
assert_contains "broken list names the directory-occupied path" "$dr_out_dir" "- CLAUDE.md"

# --- 8) --dry-run needs no write access to the target (builds in a system temp) -
# (cross-model adversarial finding: a dry-run must not write a temp build under
# the live target, so it must run against a read-only target.)
DR_TGT4="$DR_DIR/tgt4"; mkdir -p "$DR_TGT4"
DR_ENV4="$DR_DIR/local.env4"; make_local_env "$DR_ENV4" "$DR_TGT4"
AI_CONFIG_LOCAL_ENV="$DR_ENV4" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
chmod -R a-w "$DR_TGT4"
dr_ro_status=0
dr_ro_out="$(AI_CONFIG_LOCAL_ENV="$DR_ENV4" bash "$REPO_ROOT/scripts/install.sh" --dry-run 2>/dev/null)" || dr_ro_status=$?
dr_ro_build="$(find "$DR_TGT4" -maxdepth 1 -name '.install-build.*' 2>/dev/null)"
chmod -R u+w "$DR_TGT4"     # restore so the final rm -rf can clean up
assert_eq "--dry-run exits 0 against a read-only target" "0" "$dr_ro_status"
assert_contains "--dry-run reports against a read-only target" "$dr_ro_out" "dry-run state"
assert_eq "--dry-run writes no build dir under a read-only target" "" "$dr_ro_build"

rm -rf "$DR_DIR"
