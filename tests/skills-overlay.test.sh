#!/usr/bin/env bash
# tests/skills-overlay.test.sh — Exercises the operator-skills-overlay
# splice in install.sh's compile_entrypoint across the scenarios the Codex
# adversarial review flagged, plus the happy path:
# 1. overlay present → content spliced, marker consumed
# 2. set-but-missing → warns + exits 0 + spine-only (Codex F2)
# 3. marker in overlay → neutralized, no "resolves empty" die (Codex F3)
# 4. @@VAR@@ in overlay → resolved (splice precedes the @@VAR@@ loop)
# Mirrored by tests/skills-overlay.test.ps1 (twin-parity: each runner globs only
# its own extension, so per-file assertions must live in BOTH twins). Build the
# marker from halves so this source isn't a stray second literal copy.

SO_DIR="$(mktemp -d)"
SO_TGT="$SO_DIR/cfg"
SO_FIXTURE="$REPO_ROOT/tests/fixtures/ci.local.env"
SO_MARK="@@OPERATOR_SKILLS""_OVERLAY@@"

# _so_build <overlay-path-or-empty> → echoes "<exit-status>|<build-dir>"; stderr
# of the install run is captured to $SO_DIR/stderr.
_so_build() {
  local overlay_path="$1" env_file="$SO_DIR/local.env" status=0 out
  { cat "$SO_FIXTURE"
    printf '\nCLAUDE_CONFIG_DIR=%q\n' "$SO_TGT"
    [ -n "$overlay_path" ] && printf 'SKILLS_OVERLAY_PATH=%q\n' "$overlay_path"
  } > "$env_file"
  out="$(AI_CONFIG_LOCAL_ENV="$env_file" bash "$REPO_ROOT/scripts/install.sh" \
    --harness claude --build-only 2>"$SO_DIR/stderr")" || status=$?
  printf '%s|%s' "$status" "$out"
}

_so_marker_count() { grep -cF "$SO_MARK" "$1" 2>/dev/null || true; }

# 1. Happy path — overlay present.
SO_OV1="$SO_DIR/overlay-ok.md"
printf '### Operator routing\n\nSENTINEL_OVERLAY_ROW here\n' > "$SO_OV1"
_res="$(_so_build "$SO_OV1")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "overlay: present render exits 0" "0" "$_st"
if [ -f "$_bd/SKILLS.md" ]; then
  assert_contains "overlay: spliced content appears in rendered SKILLS.md" \
    "$(cat "$_bd/SKILLS.md")" "SENTINEL_OVERLAY_ROW"
  assert_eq "overlay: marker consumed in present render (0 left)" "0" "$(_so_marker_count "$_bd/SKILLS.md")"
else
  _fail "overlay: present build produced a SKILLS.md" "no SKILLS.md under [$_bd]"
fi
[ -n "$_bd" ] && rm -rf "$_bd"

# 2. Codex F2 — SET-but-missing path: warn + exit 0 + spine-only.
_res="$(_so_build "$SO_DIR/nope-not-here.md")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "overlay: set-but-missing render still exits 0 (spine-only fallback)" "0" "$_st"
assert_contains "overlay: set-but-missing warns on stderr" \
  "$(cat "$SO_DIR/stderr")" "is set but the file does not exist"
[ -f "$_bd/SKILLS.md" ] \
  && assert_eq "overlay: set-but-missing leaves no marker in output" "0" "$(_so_marker_count "$_bd/SKILLS.md")"
[ -n "$_bd" ] && rm -rf "$_bd"

# 3. Codex F3 — overlay re-introduces the marker: neutralized, no die.
SO_OV3="$SO_DIR/overlay-marker.md"
printf 'note: operators splice this at the %s marker.\n' "$SO_MARK" > "$SO_OV3"
_res="$(_so_build "$SO_OV3")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "overlay: marker-in-overlay render exits 0 (no resolves-empty die)" "0" "$_st"
[ -f "$_bd/SKILLS.md" ] \
  && assert_eq "overlay: marker-in-overlay neutralized (0 markers left)" "0" "$(_so_marker_count "$_bd/SKILLS.md")"
[ -n "$_bd" ] && rm -rf "$_bd"

# 4. @@VAR@@ inside the overlay resolves (splice precedes the @@VAR@@ loop).
SO_OV4="$SO_DIR/overlay-token.md"
printf 'see @@AI_CONFIG_DIR@@/skills/skill-authoring.md\n' > "$SO_OV4"
_res="$(_so_build "$SO_OV4")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "overlay: path-token-in-overlay render exits 0" "0" "$_st"
if [ -f "$_bd/SKILLS.md" ]; then
  _tok_n="$(grep -cF '@@AI_CONFIG_DIR@@' "$_bd/SKILLS.md" 2>/dev/null || true)"
  assert_eq "overlay: @@AI_CONFIG_DIR@@ inside overlay resolved (0 literal left)" "0" "$_tok_n"
fi
[ -n "$_bd" ] && rm -rf "$_bd"

rm -rf "$SO_DIR"
