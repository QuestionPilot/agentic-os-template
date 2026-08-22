#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/editorial.test.sh — assert editorial deliverables.
#
# Scope:
# - Root CLAUDE.md + AGENTS.md soften REQUIRED-language for Linear +
# Obsidian: they remain the framework's canonical examples, but the
# entrypoints accept equivalents (a tracker-agnostic + vault-agnostic
# posture so a future operator on Jira + Notion is not locked out).
# - core/operating-system.md no longer carries bare `(QUE-NN)` attribution
# parentheticals; standalone-read invariant for fresh-clone operators.
#
# Test files are SOURCED by tests/run.sh — do NOT `exit`, do NOT re-source
# lib.sh, do NOT set -e. Just call assert_*.

WORKFLOW="$REPO_ROOT/.github/workflows/install-render-stable.yml"
ROOT_CLAUDE="$REPO_ROOT/CLAUDE.md"
ROOT_AGENTS="$REPO_ROOT/AGENTS.md"
OS_DOC="$REPO_ROOT/core/operating-system.md"

assert_file "install-render-stable.yml exists" "$WORKFLOW"
assert_file "root CLAUDE.md exists" "$ROOT_CLAUDE"
assert_file "root AGENTS.md exists" "$ROOT_AGENTS"
assert_file "core/operating-system.md exists" "$OS_DOC"

# ---- C. Linear/Obsidian REQUIRED-language softened in root entrypoints ------
# The pre-fix root entrypoints carried hard "assumes the machine has" +
# "If either is missing, install or connect before relying on framework
# workflows" prose, which locks a fresh public-template operator into Linear
# Obsidian. Soften to "default / canonical example, equivalents accepted."
claude_body="$(cat "$ROOT_CLAUDE")"
agents_body="$(cat "$ROOT_AGENTS")"

# Negative: the old prose's hard "If either is missing, install or connect
# before relying on framework workflows" sentence is the wording the
# genericization is intended to soften.
assert_not_contains "root CLAUDE.md drops 'install or connect before relying' hard-require prose" \
  "$claude_body" "install or connect before relying on framework workflows"
assert_not_contains "root AGENTS.md drops 'install or connect before relying' hard-require prose" \
  "$agents_body" "install or connect before relying on framework workflows"

# Negative (Codex F-3 amendment): the old "Required Dependencies" heading + "This framework
# assumes the machine has" framing must be gone — both lock the operator
# into Linear/Obsidian.
assert_not_contains "root CLAUDE.md drops '## Required Dependencies' heading" \
  "$claude_body" "## Required Dependencies"
assert_not_contains "root AGENTS.md drops '## Required Dependencies' heading" \
  "$agents_body" "## Required Dependencies"
assert_not_contains "root CLAUDE.md drops 'This framework assumes the machine has' framing" \
  "$claude_body" "This framework assumes the machine has"
assert_not_contains "root AGENTS.md drops 'This framework assumes the machine has' framing" \
  "$agents_body" "This framework assumes the machine has"

# Positive: the new prose names Linear/Obsidian as the framework's default /
# canonical examples and accepts equivalents. The genericization is a
# semantic shift, not a one-word swap — assert both the canonical-example
# framing and the acceptance of equivalents.
assert_contains "root CLAUDE.md uses 'canonical example' framing for tracker/vault" \
  "$claude_body" "canonical example"
assert_contains "root AGENTS.md uses 'canonical example' framing for tracker/vault" \
  "$agents_body" "canonical example"
assert_contains "root CLAUDE.md accepts tracker equivalents (names alternatives)" \
  "$claude_body" "accepts equivalents"
assert_contains "root AGENTS.md accepts tracker equivalents (names alternatives)" \
  "$agents_body" "accepts equivalents"

# Codex F-2 amendment: assert the graceful-degradation claim in the new
# entrypoint prose is matched by an explicit degrade phrase. Verified
# against capabilities/session-agent.md:88-89 ("framework gracefully
# degrades —... a one-line warning surfaces the missing surface") and
# capabilities/self-audit.md:62 ("script degrades gracefully and notes
# 'skipped: <surface> not configured'") — the entrypoint prose mirrors
# those surfaces, not invents them.
assert_contains "root CLAUDE.md asserts spine capabilities degrade gracefully without tracker" \
  "$claude_body" "degrade gracefully"
assert_contains "root AGENTS.md asserts spine capabilities degrade gracefully without tracker" \
  "$agents_body" "degrade gracefully"

# ---- D. Standalone-read invariant — six named files free of QUE-NN refs ----
# Bare `(QUE-NN)` attribution at end-of-paragraph is the pattern the
# editorial sweep targets — these dangle for a fresh public-template
# operator with no Linear-issue context. Narrative QUE-NN references that
# explain *what* (not *who-filed-it*) must also be restructured.
#
# Codex F-1 amendment: the plan names six standalone-read files. Scan ALL
# six (not just core/operating-system.md). The same invariant applies to
# the new test file itself — it ships in the public template — except this
# test deliberately documents the (QUE-NN) pattern in its grep assertions,
# so it's exempted from the scan and tested only structurally.
README_DOC="$REPO_ROOT/README.md"
CLOSEOUT_DOC="$REPO_ROOT/core/closeout.md"
BOOTSTRAP_DOC="$REPO_ROOT/playbooks/new-machine-bootstrap.md"

assert_file "README.md exists" "$README_DOC"
assert_file "core/closeout.md exists" "$CLOSEOUT_DOC"
assert_file "playbooks/new-machine-bootstrap.md exists" "$BOOTSTRAP_DOC"

# usr/bin/grep -E to dodge the macOS ugrep shim (per
# reference_shell_grep_overlay). Match `(QUE-<digits>)` parentheticals AND
# narrative `QUE-<digits>` mentions in one pass.
for doc in "$README_DOC" "$ROOT_CLAUDE" "$ROOT_AGENTS" "$OS_DOC" "$CLOSEOUT_DOC" "$BOOTSTRAP_DOC"; do
  rel="${doc#$REPO_ROOT/}"
  assert_exit "$rel: no QUE-NN attribution (standalone-read invariant)" 1 \
    -- /usr/bin/grep -qE 'QUE-[0-9]+' "$doc"
done

# ---- E. Workflow + Makefile audit (Codex F-4) -------------------------------
# Scope per dispatch brief: audit `Makefile` + `.github/workflows/*.yml`
# for operator-only assumptions: no QUE-NN identifiers in any of
# these operator-build infrastructure files for the public-template ship.
MAKEFILE="$REPO_ROOT/Makefile"
assert_file "Makefile exists" "$MAKEFILE"
assert_exit "Makefile has no QUE-NN identifiers" 1 \
  -- /usr/bin/grep -qE 'QUE-[0-9]+' "$MAKEFILE"

# Loop over every workflow file in.github/workflows/ via git ls-files —
# bash globs skip dotfiles by default (per feedback_bash_globs_skip_dotfiles),
# and we want all tracked YAML regardless. The workflow files are
# CI-internal infrastructure; comments naming QUE-XX dangling identifiers
# would be opaque to a public-template operator.
workflows_dir="$REPO_ROOT/.github/workflows"
if [ -d "$workflows_dir" ]; then
  while IFS= read -r yml; do
    [ -n "$yml" ] || continue
    full="$REPO_ROOT/$yml"
    rel="${full#$REPO_ROOT/}"
    assert_exit "$rel: no QUE-NN identifiers in workflow comments" 1 \
      -- /usr/bin/grep -qE 'QUE-[0-9]+' "$full"
  done < <(cd "$REPO_ROOT" && git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
fi
