#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/linear-setup.test.sh — linear/linear-setup.md +
# stub-collapse on linear/README.md + inbound references from
# agentic-os-template/README.md + templates/local.env.example.
#
# Mirrors the tests/vault-guide.test.sh shape. Sourced by tests/run.sh;
# uses assert_* helpers from tests/lib.sh. Never call `exit` — failures bubble
# through assertion counters.

# --- T1: canonical doc + stub exist ---
assert_file "linear/linear-setup.md exists" \
  "$REPO_ROOT/linear/linear-setup.md"
assert_file "linear/README.md exists" \
  "$REPO_ROOT/linear/README.md"

# --- T2: linear-setup.md has all 7 expected H2 sections ---
# Spec §4 names the 7 sections. Test pins their H2 headers as anchors so a
# future doc rewrite that drops a section breaks loud, not silent.
ls_body="$(cat "$REPO_ROOT/linear/linear-setup.md" 2>/dev/null || printf '')"
for header in \
  "## 1. Purpose and Audience" \
  "## 2. Role in the Agentic OS" \
  "## 3. First-Time Setup" \
  "## 4. Operating Instructions" \
  "## 5. How the AI Uses Linear at Runtime" \
  "## 6. Templates" \
  "## 7. Failure Modes"; do
  assert_contains "linear-setup.md contains section: $header" \
    "$ls_body" "$header"
done

# --- T3: linear-setup §2 + §5 carry summary-canonical-source labels per
# C-2 body-staleness clause (mirror of vault-guide.md §2/§8 pattern).
# Codex F2 BLOCKING in the review pinned this to link-shape, not
# substring — repeat that strictness here.
assert_contains "linear-setup §2 labels canonical source with Markdown link to core/memory-model.md" \
  "$ls_body" "Summary — canonical source is [\`core/memory-model.md\`](../core/memory-model.md)"
assert_contains "linear-setup §5 labels canonical source with Markdown link to capabilities/session-agent.md" \
  "$ls_body" "[\`capabilities/session-agent.md\`](../capabilities/session-agent.md)"
assert_contains "linear-setup §5 labels canonical source with Markdown link to capabilities/closeout.md" \
  "$ls_body" "[\`capabilities/closeout.md\`](../capabilities/closeout.md)"

# --- T4: §3 First-time setup documents BOTH surface options as first-class ---
# Per spec §7: Option A (linear CLI, schpet/linear-cli) + Option B (Linear MCP) — Claude Code's
# official connector + Codex via openai/plugins/linear. Test pins the
# concrete URLs + the "first-class" framing.
assert_contains "linear-setup §3 names Option A: linear CLI" \
  "$ls_body" "Option A"
assert_contains "linear-setup §3 names Option B: Linear MCP" \
  "$ls_body" "Option B"
assert_contains "linear-setup §3 cites linear CLI repo URL" \
  "$ls_body" "github.com/schpet/linear-cli"
assert_contains "linear-setup §3 cites openai/plugins/linear for Codex MCP" \
  "$ls_body" "github.com/openai/plugins/tree/main/plugins/linear"
assert_contains "linear-setup §3 documents headless auth env var" \
  "$ls_body" "LINEAR_API_KEY"

# --- T4.5: §3.5 documents uninstall/migration with teardown for stale stubs ---
# Pins the section heading + every canonical teardown command + the verify
# commands. Covers the four per-machine-artifact patterns the section
# addresses: dotdir config stub, dotcache leftover, XDG config, XDG data.
# Each command line is asserted so a future editor that drops one breaks
# loud, not silent.
assert_contains "linear-setup §3.5 names uninstall/migration sub-section" \
  "$ls_body" "### 3.5 Uninstalling or migrating between surfaces"
assert_contains "linear-setup §3.5 documents linear binary removal" \
  "$ls_body" "rm -f ~/.local/bin/linear"
assert_contains "linear-setup §3.5 documents npm uninstall step" \
  "$ls_body" "npm uninstall -g <package-name>"
assert_contains "linear-setup §3.5 documents per-machine config stub sweep" \
  "$ls_body" "rm -rf ~/.<tool-name>"
assert_contains "linear-setup §3.5 documents cache leftover sweep" \
  "$ls_body" "rm -rf ~/.cache/<tool-name>"
assert_contains "linear-setup §3.5 documents XDG config variant sweep" \
  "$ls_body" "rm -rf ~/.config/<tool-name>"
assert_contains "linear-setup §3.5 documents XDG data variant sweep" \
  "$ls_body" "rm -rf ~/.local/share/<tool-name>"
assert_contains "linear-setup §3.5 documents CLI-presence verify (command -v)" \
  "$ls_body" "command -v linear"
assert_contains "linear-setup §3.5 documents CLI-version verify" \
  "$ls_body" "linear --version"

# --- T5: §6 Templates references the 3 existing linear/ template files ---
assert_contains "linear-setup §6 references linear/issue-template.md" \
  "$ls_body" "issue-template.md"
assert_contains "linear-setup §6 references linear/closeout-format.md" \
  "$ls_body" "closeout-format.md"
assert_contains "linear-setup §6 references linear/tool-agnostic-linear.md" \
  "$ls_body" "tool-agnostic-linear.md"

# --- T6: linear/README.md collapsed to <=10 line stub ---
# Mirrors vault-guide.test.sh T6 ceiling.
readme_lines=$(wc -l < "$REPO_ROOT/linear/README.md" 2>/dev/null || printf '0')
if [ "$readme_lines" -le 10 ]; then
  _pass "linear/README.md is a stub (<=10 lines; actual=$readme_lines)"
else
  _fail "linear/README.md exceeds stub ceiling" \
    "expected <=10 lines, got $readme_lines"
fi

# --- T7: stub references linear-setup.md ---
readme_body="$(cat "$REPO_ROOT/linear/README.md" 2>/dev/null || printf '')"
assert_contains "linear/README.md references linear-setup.md" \
  "$readme_body" "linear-setup.md"

# --- T8: inbound references from the fresh-clone path ---
root_readme="$(cat "$REPO_ROOT/README.md" 2>/dev/null || printf '')"
env_body="$(cat "$REPO_ROOT/templates/local.env.example" 2>/dev/null || printf '')"
assert_contains "agentic-os-template/README.md Layout table references linear/linear-setup.md" \
  "$root_readme" "linear/linear-setup.md"
assert_contains "templates/local.env.example references linear/linear-setup.md" \
  "$env_body" "linear/linear-setup.md"

# --- T10: harness-leak guard — no.claude/skills/ etc. in shared content ---
# Catches the scenario Codex F-2 BLOCKING surfaced (harness-config-path
# leak in shared docs). Scans linear/linear-setup.md + the new
# linear/README.md stub.
harness_leak=0
for f in "$REPO_ROOT/linear/linear-setup.md" "$REPO_ROOT/linear/README.md"; do
  if [ -f "$f" ] && grep -qE '\.claude/|\.codex/|\.agents/' "$f"; then
    _fail "$(basename "$(dirname "$f")")/$(basename "$f") leaks harness-config path" \
      "found one of: .claude/  .codex/  .agents/"
    harness_leak=1
  fi
done
if [ "$harness_leak" -eq 0 ]; then
  _pass "no harness-config-path leak in linear-setup.md / linear/README.md"
fi

# --- T11: operator-specific-name guard — runtime-construct sentinels per
# [[feedback_self_tripping_test_source]] so this test source does NOT itself
# self-trip check-drift.sh's personal-name scan. Also catches the hyphenated
# workspace-slug form that the case-insensitive non-hyphen sentinels miss
# (Codex MT-1 strengthened the guard from concat-only to slug-form-too).
sentinel_personal="$(printf '%s%s' 'Hen' 'do')"
sentinel_retired="$(printf '%s%s' 'Question' 'Pilot')"
sentinel_slug="$(printf '%s-%s' 'question' 'pilot')"
name_leak=0
for f in "$REPO_ROOT/linear/linear-setup.md" "$REPO_ROOT/linear/README.md"; do
  if [ -f "$f" ]; then
    hits="$(grep -niF -e "$sentinel_personal" -e "$sentinel_retired" -e "$sentinel_slug" "$f" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      _fail "$(basename "$(dirname "$f")")/$(basename "$f") leaks operator-specific identifier" \
        "found one of the runtime-constructed sentinels"
      name_leak=1
    fi
  fi
done
if [ "$name_leak" -eq 0 ]; then
  _pass "no operator-specific-name leak in linear-setup.md / linear/README.md"
fi

# --- T12: Codex harness entrypoint retains the two-Linear-surfaces framing ---
# Re-homed from the deleted cli-transition test: Linear remains one of
# the framework's two permanent contracts, so harnesses/codex/AGENTS.template.md
# must keep the "two Linear access surfaces" framing even after the tool-layer
# purge. Without this, a future edit could drop the active-work contract from the
# Codex entrypoint and the suite would still pass.
codex_tmpl="$(cat "$REPO_ROOT/harnesses/codex/AGENTS.template.md" 2>/dev/null || printf '')"
assert_contains "harnesses/codex/AGENTS.template.md retains 'two Linear access surfaces' framing" \
  "$codex_tmpl" "two Linear access surfaces"
