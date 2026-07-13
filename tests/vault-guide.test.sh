#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/vault-guide.test.sh — obsidian/vault-guide.md +
# start-template.md + handshake-template.md + stub-collapse on README +
# vault-structure + inbound references from agentic-os-template/README.md +
# playbooks/new-machine-bootstrap.md + templates/local.env.example.
#
# Sourced by tests/run.sh; uses assert_* helpers from tests/lib.sh.
# Never call `exit` — failures bubble through assertion counters.

# --- T1: canonical doc + templates exist ---
assert_file "obsidian/vault-guide.md exists" \
  "$REPO_ROOT/obsidian/vault-guide.md"
assert_file "obsidian/start-template.md exists" \
  "$REPO_ROOT/obsidian/start-template.md"
assert_file "obsidian/handshake-template.md exists" \
  "$REPO_ROOT/obsidian/handshake-template.md"

# --- T2: vault-guide.md has all 9 expected H2 sections ---
# Spec §3 names the 9 sections. Test pins their H2 headers as anchors so a
# future doc rewrite that drops a section breaks loud, not silent.
vg_body="$(cat "$REPO_ROOT/obsidian/vault-guide.md" 2>/dev/null || printf '')"
for header in \
  "## 1. Purpose and Audience" \
  "## 2. Role in the Agentic OS" \
  "## 3. First-Time Setup" \
  "## 4. Folder Structure" \
  "## 5. \`00-System/\` Notes" \
  "## 6. \`50-Outputs/\` Convention" \
  "## 7. Templates" \
  "## 8. How the AI Uses the Vault at Runtime" \
  "## 9. Failure Modes"; do
  assert_contains "vault-guide.md contains section: $header" \
    "$vg_body" "$header"
done

# --- T3: vault-guide §2 + §8 carry summary-canonical-source labels per
# C-2 body-staleness clause (the design's drift-mitigation contract).
# Spec rule: "labeled 'summary — canonical source is X' with a link". The
# label must be a real Markdown link, not just a code-formatted path string —
# otherwise a future doc author can't follow the canonical source without
# guessing the path. (Codex pre-PR review F2 BLOCKING strengthened this from
# substring-only to link-shape pinning.)
assert_contains "vault-guide §2 labels canonical source with Markdown link to core/memory-model.md" \
  "$vg_body" "Summary — canonical source is [\`core/memory-model.md\`](../core/memory-model.md)"
assert_contains "vault-guide §8 labels canonical source with Markdown link to capabilities/session-agent.md" \
  "$vg_body" "[\`capabilities/session-agent.md\`](../capabilities/session-agent.md)"
assert_contains "vault-guide §8 labels canonical source with Markdown link to capabilities/closeout.md" \
  "$vg_body" "[\`capabilities/closeout.md\`](../capabilities/closeout.md)"

# --- T4: start-template.md carries the minimum-contract sections that
# vault-guide §7 names (Read Order, Working Rule, Linear Boundary, Closeout,
# Health Check). Test pins each as an H2 anchor.
st_body="$(cat "$REPO_ROOT/obsidian/start-template.md" 2>/dev/null || printf '')"
for header in \
  "## Read Order" \
  "## Working Rule" \
  "## Linear Boundary" \
  "## Closeout" \
  "## Health Check"; do
  assert_contains "start-template.md contains minimum-contract section: $header" \
    "$st_body" "$header"
done

# --- T5: handshake-template.md ships the YAML frontmatter contract
# (title / tags / linear / status keys; linear-handshake tag).
ht_body="$(cat "$REPO_ROOT/obsidian/handshake-template.md" 2>/dev/null || printf '')"
for token in "title:" "tags:" "linear-handshake" "linear:" "status:"; do
  assert_contains "handshake-template.md frontmatter contains: $token" \
    "$ht_body" "$token"
done

# --- T6: README.md + vault-structure.md collapsed to <=10 line stubs ---
# Spec says 2-4 lines; allow up to 10 to absorb a code-fence or template list.
readme_lines=$(wc -l < "$REPO_ROOT/obsidian/README.md" 2>/dev/null || printf '0')
vs_lines=$(wc -l < "$REPO_ROOT/obsidian/vault-structure.md" 2>/dev/null || printf '0')
if [ "$readme_lines" -le 10 ]; then
  _pass "obsidian/README.md is a stub (<=10 lines; actual=$readme_lines)"
else
  _fail "obsidian/README.md exceeds stub ceiling" \
    "expected <=10 lines, got $readme_lines"
fi
if [ "$vs_lines" -le 10 ]; then
  _pass "obsidian/vault-structure.md is a stub (<=10 lines; actual=$vs_lines)"
else
  _fail "obsidian/vault-structure.md exceeds stub ceiling" \
    "expected <=10 lines, got $vs_lines"
fi

# --- T7: stubs reference vault-guide ---
readme_body="$(cat "$REPO_ROOT/obsidian/README.md" 2>/dev/null || printf '')"
vs_body="$(cat "$REPO_ROOT/obsidian/vault-structure.md" 2>/dev/null || printf '')"
assert_contains "obsidian/README.md references vault-guide" \
  "$readme_body" "vault-guide.md"
assert_contains "obsidian/vault-structure.md references vault-guide" \
  "$vs_body" "vault-guide.md"

# --- T8: inbound references from the fresh-clone path ---
root_readme="$(cat "$REPO_ROOT/README.md" 2>/dev/null || printf '')"
playbook_body="$(cat "$REPO_ROOT/playbooks/new-machine-bootstrap.md" 2>/dev/null || printf '')"
env_body="$(cat "$REPO_ROOT/templates/local.env.example" 2>/dev/null || printf '')"
assert_contains "agentic-os-template/README.md Layout table references vault-guide.md" \
  "$root_readme" "obsidian/vault-guide.md"
assert_contains "playbooks/new-machine-bootstrap.md references vault-guide.md" \
  "$playbook_body" "vault-guide.md"
assert_contains "templates/local.env.example references vault-guide.md" \
  "$env_body" "vault-guide.md"

# --- T9: harness-leak guard — no `.claude/skills/` (or `.codex/` /
# `.agents/`) substring in any shared obsidian/ content. Catches the
# scenario Codex F-2 BLOCKING called out in the design review.
harness_leak=0
while IFS= read -r f; do
  if grep -qE '\.claude/|\.codex/|\.agents/' "$f"; then
    _fail "obsidian/$(basename "$f") leaks harness-config path" \
      "found one of: .claude/  .codex/  .agents/"
    harness_leak=1
  fi
done < <(find "$REPO_ROOT/obsidian" -maxdepth 1 -type f -name '*.md')
if [ "$harness_leak" -eq 0 ]; then
  _pass "no harness-config-path leak in any obsidian/*.md"
fi

# --- T10: operator-specific-name guard — runtime-construct sentinels per
# [[feedback_self_tripping_test_source]] so this test source does NOT itself
# self-trip check-drift.sh's personal-name scan. Constructs are split-and-join
# from non-matching halves so this file's
# raw bytes never spell the forbidden tokens.
sentinel_personal="$(printf '%s%s' 'Hen' 'do')"
sentinel_retired="$(printf '%s%s' 'Question' 'Pilot')"
name_leak=0
while IFS= read -r f; do
  # Case-insensitive scan for the runtime-constructed sentinels.
  if grep -qiF -e "$sentinel_personal" -e "$sentinel_retired" "$f"; then
    _fail "obsidian/$(basename "$f") leaks operator-specific identifier" \
      "found one of the runtime-constructed sentinels"
    name_leak=1
  fi
done < <(find "$REPO_ROOT/obsidian" -maxdepth 1 -type f -name '*.md')
if [ "$name_leak" -eq 0 ]; then
  _pass "no operator-specific-name leak in any obsidian/*.md"
fi
