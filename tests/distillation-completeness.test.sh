#!/usr/bin/env bash
# tests/distillation-completeness.test.sh — behavioral tests for
# scripts/check-distillation-completeness.sh.
#
# The check cross-references every feedback/decision memory note in a memory dir
# against the `04-Lessons/*.md` corpus in a lessons dir. A note is DISTILLED when
# its name appears as a whole token anywhere in the Lessons corpus (kebab `-` and
# snake `_` treated as interchangeable). Exit 0 = all distilled (or none to
# check), 1 = one or more undistilled, 2 = usage error.
#
# Sourced by tests/run.sh; do NOT set -e or call exit.

CMD_SCRIPT="$REPO_ROOT/scripts/check-distillation-completeness.sh"

# Helper: write a memory note with a frontmatter type + body.
# _note <dir> <filename> <type> [body]
_note() {
  { printf -- '---\nname: %s\ndescription: "n"\nmetadata:\n  type: %s\n---\n%s\n' \
      "${2%.md}" "$3" "${4:-Body.}"; } > "$1/$2"
}

# === Setup: a lessons dir with one thematic note recording two source notes.
# One source note is recorded kebab-case, one snake-case, to exercise both
# normalization directions. A third name is recorded in the BODY (not Source
# Notes) to prove the whole-file scan counts it.
LES=$(mktemp -d 2>/dev/null) || LES="/tmp/distill-les-$$"
mkdir -p "$LES"
cat > "$LES/2026-06-15 - Example Theme.md" <<'EOF'
---
title: Example Theme
---

## Durable Lesson

Body mentions feedback-body-recorded as a provenance reference inline.

## Source Notes

- feedback-already-kebab
- feedback_already_snake
EOF

# === 1. A memory dir where every feedback note is distilled → exit 0, PASS.
MEM_OK=$(mktemp -d 2>/dev/null) || MEM_OK="/tmp/distill-ok-$$"
mkdir -p "$MEM_OK"
_note "$MEM_OK" "feedback-already-kebab.md" feedback        # recorded kebab in Source Notes
_note "$MEM_OK" "feedback_already_snake.md" feedback        # recorded snake in Source Notes
_note "$MEM_OK" "feedback-body-recorded.md" feedback        # recorded in the lesson BODY
OK_OUT=$(bash "$CMD_SCRIPT" --memory-dir "$MEM_OK" --lessons-dir "$LES" 2>&1)
OK_RC=$?
assert_eq "distill: all-distilled dir exits 0" "0" "$OK_RC"
assert_contains "distill: all-distilled reports PASS" "$OK_OUT" "PASS"
assert_contains "distill: PASS names the count (3 checked)" "$OK_OUT" "all 3 feedback/decision"

# === 2. kebab↔snake normalization, both directions (subset of test 1, asserted
# explicitly): the kebab note matched a snake Source-Notes entry and vice-versa,
# so neither was flagged.
assert_not_contains "distill: kebab note matches snake Source-Notes entry" "$OK_OUT" "feedback-already-kebab.md"
assert_not_contains "distill: snake note matches kebab... (reverse) not flagged" "$OK_OUT" "feedback_already_snake.md"
assert_not_contains "distill: body-recorded name counts (whole-file scan)" "$OK_OUT" "feedback-body-recorded.md"

# === 3. An undistilled feedback note → exit 1, names the file.
MEM_BAD=$(mktemp -d 2>/dev/null) || MEM_BAD="/tmp/distill-bad-$$"
mkdir -p "$MEM_BAD"
_note "$MEM_BAD" "feedback-already-kebab.md" feedback        # distilled
_note "$MEM_BAD" "feedback-never-promoted.md" feedback       # NOT in the lessons corpus
BAD_OUT=$(bash "$CMD_SCRIPT" --memory-dir "$MEM_BAD" --lessons-dir "$LES" 2>&1)
BAD_RC=$?
assert_eq "distill: undistilled note exits 1" "1" "$BAD_RC"
assert_contains "distill: names the undistilled note" "$BAD_OUT" "feedback-never-promoted.md"
assert_not_contains "distill: does not flag the distilled note" "$BAD_OUT" "feedback-already-kebab.md"
assert_contains "distill: failure summary counts undistilled" "$BAD_OUT" "1 of 2 feedback/decision"

# === 4. Decision notes are in scope (by filename prefix). An undistilled
# decision note is flagged.
MEM_DEC=$(mktemp -d 2>/dev/null) || MEM_DEC="/tmp/distill-dec-$$"
mkdir -p "$MEM_DEC"
_note "$MEM_DEC" "decision-undistilled.md" decision
DEC_OUT=$(bash "$CMD_SCRIPT" --memory-dir "$MEM_DEC" --lessons-dir "$LES" 2>&1)
assert_eq "distill: undistilled decision note exits 1" "1" "$?"
assert_contains "distill: names the undistilled decision note" "$DEC_OUT" "decision-undistilled.md"

# === 5. Frontmatter-type selection: a note whose FILENAME is not feedback/
# decision but whose frontmatter type IS feedback is checked (and flagged when
# undistilled); a project/reference note is OUT of scope (never flagged).
MEM_FM=$(mktemp -d 2>/dev/null) || MEM_FM="/tmp/distill-fm-$$"
mkdir -p "$MEM_FM"
_note "$MEM_FM" "home-folder.md" feedback                    # feedback by frontmatter, no prefix
_note "$MEM_FM" "project-active-thing.md" project            # out of scope
_note "$MEM_FM" "reference-stable-pointer.md" reference      # out of scope
FM_OUT=$(bash "$CMD_SCRIPT" --memory-dir "$MEM_FM" --lessons-dir "$LES" 2>&1)
assert_eq "distill: feedback-by-frontmatter note is checked → exit 1" "1" "$?"
assert_contains "distill: flags the no-prefix feedback-typed note" "$FM_OUT" "home-folder.md"
assert_not_contains "distill: ignores project_* notes" "$FM_OUT" "project-active-thing.md"
assert_not_contains "distill: ignores reference_* notes" "$FM_OUT" "reference-stable-pointer.md"

# === 6. Whole-token boundary: a SHORTER name that is a prefix of a distilled
# LONGER name must NOT false-pass. The lessons corpus records only the long name.
MEM_BND=$(mktemp -d 2>/dev/null) || MEM_BND="/tmp/distill-bnd-$$"
mkdir -p "$MEM_BND"
LES_BND=$(mktemp -d 2>/dev/null) || LES_BND="/tmp/distill-les-bnd-$$"
mkdir -p "$LES_BND"
cat > "$LES_BND/lesson.md" <<'EOF'
---
title: Boundary
---
## Source Notes
- feedback-cross-model-review-infra
EOF
_note "$MEM_BND" "feedback-cross-model-review.md" feedback   # PREFIX of the distilled long name
BND_OUT=$(bash "$CMD_SCRIPT" --memory-dir "$MEM_BND" --lessons-dir "$LES_BND" 2>&1)
assert_eq "distill: prefix-name is not falsely matched by a longer distilled name" "1" "$?"
assert_contains "distill: the prefix note is flagged undistilled" "$BND_OUT" "feedback-cross-model-review.md"

# === 7. A memory dir with NO feedback/decision notes → exit 0 (nothing to check).
MEM_NONE=$(mktemp -d 2>/dev/null) || MEM_NONE="/tmp/distill-none-$$"
mkdir -p "$MEM_NONE"
_note "$MEM_NONE" "project-only.md" project
_note "$MEM_NONE" "reference-only.md" reference
assert_exit "distill: no feedback/decision notes exits 0" 0 -- \
  bash "$CMD_SCRIPT" --memory-dir "$MEM_NONE" --lessons-dir "$LES"

# === 8. MEMORY.md is never treated as a feedback note (even if it mentions one).
MEM_IDX=$(mktemp -d 2>/dev/null) || MEM_IDX="/tmp/distill-idx-$$"
mkdir -p "$MEM_IDX"
printf '# Memory Index\n\n- [x](feedback-something.md) — a pointer line\n' > "$MEM_IDX/MEMORY.md"
assert_exit "distill: MEMORY.md alone exits 0 (not a feedback note)" 0 -- \
  bash "$CMD_SCRIPT" --memory-dir "$MEM_IDX" --lessons-dir "$LES"

# === 9. Usage errors: missing dirs and unresolvable env → exit 2.
assert_exit "distill: missing memory dir exits 2" 2 -- \
  bash "$CMD_SCRIPT" --memory-dir "/tmp/no-such-mem-$$" --lessons-dir "$LES"
assert_exit "distill: missing lessons dir exits 2" 2 -- \
  bash "$CMD_SCRIPT" --memory-dir "$MEM_OK" --lessons-dir "/tmp/no-such-les-$$"
assert_exit "distill: no --lessons-dir + no OBSIDIAN_VAULT_PATH exits 2" 2 -- \
  env -i bash "$CMD_SCRIPT" --memory-dir "$MEM_OK"
assert_exit "distill: no --memory-dir + no CLAUDE_CONFIG_DIR exits 2" 2 -- \
  env -i bash "$CMD_SCRIPT" --lessons-dir "$LES"

# === 10. Mixed dir with a space in the lessons path (cloud-vault realism):
# space-safe find. Reuse LES content under a spaced path.
LES_SPACE=$(mktemp -d 2>/dev/null) || LES_SPACE="/tmp/distill les space-$$"
mkdir -p "$LES_SPACE/My Lessons"
cp "$LES/2026-06-15 - Example Theme.md" "$LES_SPACE/My Lessons/"
SPACE_OUT=$(bash "$CMD_SCRIPT" --memory-dir "$MEM_OK" --lessons-dir "$LES_SPACE/My Lessons" 2>&1)
assert_eq "distill: spaced lessons path resolves (all distilled) exit 0" "0" "$?"
assert_contains "distill: spaced-path run reports PASS" "$SPACE_OUT" "PASS"

# === 11. --help exits 0 and prints the script name banner.
HELP_OUT=$(bash "$CMD_SCRIPT" --help 2>&1)
assert_eq "distill: --help exits 0" "0" "$?"
assert_contains "distill: --help prints the banner" "$HELP_OUT" "check-distillation-completeness.sh"

# === 12. Unknown arg → exit 2.
assert_exit "distill: unknown arg exits 2" 2 -- \
  bash "$CMD_SCRIPT" --bogus

# === 13. Bare `feedback.md` / `decision.md` stems are in scope (Codex F3). Give
# them a non-feedback frontmatter type so ONLY the bare-stem filename match can
# select them — proving the `feedback|decision` exact-word alternative, not the
# frontmatter path.
MEM_BARE=$(mktemp -d 2>/dev/null) || MEM_BARE="/tmp/distill-bare-$$"
mkdir -p "$MEM_BARE"
_note "$MEM_BARE" "feedback.md" note
_note "$MEM_BARE" "decision.md" note
BARE_OUT=$(bash "$CMD_SCRIPT" --memory-dir "$MEM_BARE" --lessons-dir "$LES" 2>&1)
assert_eq "distill: bare feedback.md/decision.md stems are in scope → exit 1" "1" "$?"
assert_contains "distill: flags bare feedback.md" "$BARE_OUT" "feedback.md"
assert_contains "distill: flags bare decision.md" "$BARE_OUT" "decision.md"

# Boundary: `feedbackish-thing.md` (non-feedback type) is NOT a feedback note.
MEM_NOTFB=$(mktemp -d 2>/dev/null) || MEM_NOTFB="/tmp/distill-notfb-$$"
mkdir -p "$MEM_NOTFB"
_note "$MEM_NOTFB" "feedbackish-thing.md" reference
assert_exit "distill: feedbackish-* is not a feedback note (exit 0)" 0 -- \
  bash "$CMD_SCRIPT" --memory-dir "$MEM_NOTFB" --lessons-dir "$LES"

# === 14. BOM'd frontmatter-only feedback note (no filename prefix) is in scope
# (Codex F4). Without the BOM strip, the `^---` test fails and the note is
# silently skipped — a false-PASS in a pre-wipe guard.
MEM_BOM=$(mktemp -d 2>/dev/null) || MEM_BOM="/tmp/distill-bom-$$"
mkdir -p "$MEM_BOM"
printf -- '\xef\xbb\xbf---\nname: home-folder\ndescription: "n"\nmetadata:\n  type: feedback\n---\nBody.\n' > "$MEM_BOM/home-folder.md"
BOM_OUT=$(bash "$CMD_SCRIPT" --memory-dir "$MEM_BOM" --lessons-dir "$LES" 2>&1)
assert_eq "distill: BOM'd frontmatter-only feedback note is in scope → exit 1" "1" "$?"
assert_contains "distill: flags the BOM'd no-prefix feedback note" "$BOM_OUT" "home-folder.md"

# --- Cleanup.
rm -rf "$LES" "$MEM_OK" "$MEM_BAD" "$MEM_DEC" "$MEM_FM" "$MEM_BND" "$LES_BND" \
  "$MEM_NONE" "$MEM_IDX" "$LES_SPACE" "$MEM_BARE" "$MEM_NOTFB" "$MEM_BOM"
