#!/usr/bin/env bash
# tests/rule-attribution.test.sh — enforce the prose-rationale +
# out-of-line-vault-lineage attribution convention that REPLACED the inline
# (KEY-NN) suffix convention. The migration retires the publish scrubber, so
# the public-template brain carries no private tracker IDs — a rule states its
# rationale in prose and its originating issue lives out-of-line in the durable
# vault note's `linear:` frontmatter (see core/memory-model.md).
#
# This SUPERSEDES the original per-bullet (KEY-NN) attribution enforcement. It
# asserts the inversion: the governed rule sections carry NO inline tracker-ID
# token and NO legacy `(founding)` / `(harness-mechanic)` suffix, and the two
# entrypoint Ground Rules preambles state the new convention (both halves —
# prose rationale AND the `linear:` frontmatter lineage home).
#
# NON-GOAL: this validates public-file cleanliness of the governed rule sections.
# It does NOT verify that a vault note exists for each rule or that the note
# carries correct lineage — that is a migration-audit concern, not a unit test.
#
# Per [[reference_shell_grep_overlay]] use /usr/bin/grep so the bash subshell
# sees BSD grep semantics, not the interactive zsh ugrep alias. Per
# [[reference_awk_portability]] wrap awk with LC_ALL=C.
#
# Self-trip guard ([[feedback_self_tripping_test_source]]): the forbidden
# tracker-ID class is assembled at runtime from a non-matching key + separator,
# so this file carries no literal issue-shaped token that would self-trip the
# detector or the cleanliness scanner. Label/variable text likewise avoids
# literal issue-shaped tokens.

GREP=/usr/bin/grep

# --- the forbidden attribution forms --------------------------------------
# Tracker-ID class: an UPPERCASE team key + '-' + digits, regardless of
# surrounding parens / brackets / prose. This is the class the new convention
# forbids from public framework rule prose. Forbidding only the parenthesized
# `(KEY-NN)` form is trivially bypassed (`KEY-NN`, `[KEY-NN]`, `Linear KEY-NN`),
# so the detector matches the bare class. Built from halves so this file is
# self-clean against its own scanner.
TRACKER_KEY='QUE'
TRACKER_ID_RE="${TRACKER_KEY}-[0-9]+"
# Legacy parenthetical lineage suffixes the old convention used — also forbidden
# in governed rule sections under the prose-rationale convention.
LEGACY_TOKEN_RE='\((founding|harness-mechanic)\)'
FORBIDDEN_RE="${TRACKER_ID_RE}|${LEGACY_TOKEN_RE}"

# section_rule_content <file> <section-header> — emit a governed rule section's
# body: every line from the section header to the next `## ` header. The WHOLE
# section is in scope, including any managed sub-blocks (e.g. the ctx7-managed
# block in the Codex Ground Rules) — the new convention forbids private tracker
# IDs anywhere in a shipped framework rule section, so nothing is comment-exempt.
section_rule_content() {
  local file="$1" section="$2"
  LC_ALL=C awk -v section="$section" '
    /^## / { in_sec = ($0 == section); next }
    in_sec { print }
  ' "$file"
}

# check_section_clean <file> <section-header> <label> — PASS iff the section's
# rule content carries no forbidden attribution token. A renamed/mistyped/
# deleted section yields an empty body; that is a FAILURE (coverage must not
# silently drop), not a vacuous pass.
check_section_clean() {
  local file="$1" section="$2" label="$3"
  local body hits
  body="$(section_rule_content "$file" "$section")"
  if [ -z "$body" ]; then
    _fail "$label" "governed rule section not found or empty (renamed / mistyped header?)"
    return
  fi
  hits="$(printf '%s\n' "$body" | $GREP -nE "$FORBIDDEN_RE" || true)"
  if [ -z "$hits" ]; then
    _pass "$label (prose rationale — no inline tracker-ID / legacy token)"
  else
    _fail "$label" "governed rule section still carries forbidden attribution token(s):" "$hits"
  fi
}

# === Governed rule sections — must carry NO inline attribution token =========
CLAUDE_TPL="$REPO_ROOT/harnesses/claude/CLAUDE.template.md"
AGENTS_TPL="$REPO_ROOT/harnesses/codex/AGENTS.template.md"

check_section_clean "$CLAUDE_TPL" "## Ground Rules" \
  "claude template Ground Rules"
check_section_clean "$AGENTS_TPL" "## Ground Rules" \
  "codex template Ground Rules"
check_section_clean "$REPO_ROOT/core/memory-model.md" "## Per-Harness Memory Index" \
  "memory-model Per-Harness Memory Index"
check_section_clean "$REPO_ROOT/core/memory-model.md" "## Failure Modes" \
  "memory-model Failure Modes"
check_section_clean "$REPO_ROOT/core/self-improvement.md" "## Inputs — State Deltas" \
  "self-improvement Inputs — State Deltas"
check_section_clean "$REPO_ROOT/core/operating-system.md" "## Working Rules" \
  "operating-system Working Rules"
check_section_clean "$REPO_ROOT/core/tool-use.md" "## Guardrails" \
  "tool-use Guardrails"
check_section_clean "$REPO_ROOT/core/routing.md" "## Avoid" \
  "routing Avoid"
check_section_clean "$REPO_ROOT/core/routing.md" "## Escalate When" \
  "routing Escalate When"

# === Positive: the new convention is stated in both Ground Rules preambles ===
# Both halves — prose rationale AND the out-of-line `linear:` frontmatter home.
CLAUDE_GR="$(section_rule_content "$CLAUDE_TPL" "## Ground Rules")"
assert_contains "claude Ground Rules states the prose-rationale convention" \
  "$CLAUDE_GR" "prose"
assert_contains "claude Ground Rules names the linear: frontmatter lineage home" \
  "$CLAUDE_GR" "linear:"
AGENTS_GR="$(section_rule_content "$AGENTS_TPL" "## Ground Rules")"
assert_contains "codex Ground Rules states the prose-rationale convention" \
  "$AGENTS_GR" "prose"
assert_contains "codex Ground Rules names the linear: frontmatter lineage home" \
  "$AGENTS_GR" "linear:"

# === the vault linear:-frontmatter handshake is documented ==========
# core/memory-model.md is the canonical issue->knowledge home the rule points to.
MEM_MODEL="$(cat "$REPO_ROOT/core/memory-model.md")"
assert_contains "memory-model documents the linear: frontmatter handshake" \
  "$MEM_MODEL" "linear:"
assert_contains "memory-model frames the handshake via frontmatter" \
  "$MEM_MODEL" "frontmatter"

# === Unrelated invariants that share this file (NOT attribution) =============
# These came bundled with the original attribution test; they guard
# SKILLS.template.md substitution safety, not rule attribution. Kept here to
# avoid churn — a future maintainer cleaning up attribution logic MUST NOT
# delete them.
SKILLS_HEAD="$(LC_ALL=C awk 'NR<=20 { print } NR==20 { exit }' \
  "$REPO_ROOT/harnesses/claude/SKILLS.template.md")"
assert_contains "SKILLS.template.md names capabilities/ as canonical source" \
  "$SKILLS_HEAD" "capabilities/"
assert_contains "SKILLS.template.md names harnesses/claude/capabilities/ as Claude-specific canonical source" \
  "$SKILLS_HEAD" "harnesses/claude/capabilities/"
assert_contains "SKILLS.template.md names install.sh as regenerator" \
  "$SKILLS_HEAD" "install.sh"
assert_contains "SKILLS.template.md has do-not-edit-directly clause" \
  "$SKILLS_HEAD" "Do not edit directly"

SKILLS_TPL="$REPO_ROOT/harnesses/claude/SKILLS.template.md"
catalog_token_lines="$(LC_ALL=C awk '/@@CAPABILITY_CATALOG@@/ { c++ } END { print c+0 }' "$SKILLS_TPL")"
assert_eq "SKILLS.template.md has exactly one @@CAPABILITY_CATALOG@@ occurrence (no stray-prose copies)" \
  "1" "$catalog_token_lines"
agents_catalog_token_lines="$(LC_ALL=C awk '/@@CAPABILITY_CATALOG@@/ { c++ } END { print c+0 }' "$AGENTS_TPL")"
assert_eq "AGENTS.template.md has exactly one @@CAPABILITY_CATALOG@@ occurrence" \
  "1" "$agents_catalog_token_lines"

# === Unit tests for the forbidden-token detector ============================
# Assembled at runtime from halves so the test source carries no literal
# issue-shaped token (self-trip guard). Cover the bypass forms the design
# review flagged: bare, bracketed, and prose-embedded tracker IDs.
forbidden_match() { printf '%s\n' "$1" | $GREP -qE "$FORBIDDEN_RE"; }
qid="${TRACKER_KEY}-185"          # runtime-built real-shaped tracker id

# Positive: every inline form of the tracker-ID class must be caught.
assert_eq "detector catches parenthesized (KEY-NN)" "0" \
  "$(forbidden_match "- foo (${qid})"; echo $?)"
assert_eq "detector catches bare KEY-NN (no parens)" "0" \
  "$(forbidden_match "- foo ${qid}"; echo $?)"
assert_eq "detector catches bracketed [KEY-NN]" "0" \
  "$(forbidden_match "- foo [${qid}]"; echo $?)"
assert_eq "detector catches prose-embedded tracker id" "0" \
  "$(forbidden_match "see Linear ${qid} for context"; echo $?)"
assert_eq "detector catches legacy (founding)" "0" \
  "$(forbidden_match "- foo (founding)"; echo $?)"
assert_eq "detector catches legacy (harness-mechanic)" "0" \
  "$(forbidden_match "- foo (harness-mechanic)"; echo $?)"

# Negative controls: benign text must NOT match.
assert_eq "detector ignores lowercase key" "1" \
  "$(forbidden_match "- foo (que-185)"; echo $?)"
assert_eq "detector ignores the word 'founding' in prose (no parens)" "1" \
  "$(forbidden_match "these are the founding rules"; echo $?)"
assert_eq "detector ignores an ordinary hyphenated word" "1" \
  "$(forbidden_match "- a well-formed bullet"; echo $?)"
assert_eq "detector ignores a different team-key shape" "1" \
  "$(forbidden_match "- foo (ABC-1)"; echo $?)"

# === Fixture tests for section scanning =====================================
# Build a fixture with a tracker id sitting AFTER an HTML comment inside a
# section (qid runtime-built per the self-trip guard). The whole section is in
# scope — no comment-exempt region — so the scan must still see the id.
FIX="$(mktemp)"
{
  printf '# Fixture\n\n## Demo Section\n\n'
  printf -- '- a clean bullet\n'
  printf '<!-- a managed sub-block -->\n'
  printf -- '- another bullet (%s)\n' "$qid"
  printf '\n## Next Section\n'
} > "$FIX"
demo_body="$(section_rule_content "$FIX" "## Demo Section")"
assert_eq "section scan covers content AFTER an HTML comment (no comment-exempt)" "0" \
  "$(printf '%s\n' "$demo_body" | $GREP -qE "$FORBIDDEN_RE"; echo $?)"
# A renamed / mistyped section header yields an empty body — the coverage-drop
# guard in check_section_clean turns that into a FAIL, not a vacuous pass.
assert_eq "section scan returns empty for an absent section header" "" \
  "$(section_rule_content "$FIX" "## Nonexistent Section")"
rm -f "$FIX"
