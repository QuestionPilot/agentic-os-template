#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/run-policy.test.sh — contract tests for the Per-Run Safety Posture.
#
# The posture is a LEAN codification: default-safe + cannot-override-hard-guards
# already ship in core/operating-system.md -> Decision Authority. The genuinely-
# additive remainder is (a) a NAMED per-run-safety-posture umbrella stating
# default-safe + declared-at-run-start + tighten-only-never-loosen +
# composes-with-not-replaces, with loosening reserved to an explicit operator
# action; and (b) wiring it into the session-agent Mode 1 orient so the posture is
# VISIBLE at run start. These assertions PIN that surface so a future edit cannot
# silently drop a hard guard from the precedence list, reopen a self-loosening
# path, or un-wire the visible-at-start line. Narrow required-surface-presence
# invariants (strengthen narrow invariants, not a gameable count/coverage floor).
#
# Sourced by tests/run.sh; do NOT set -e or call exit.

OS_DOC="$REPO_ROOT/core/operating-system.md"
SA_DOC="$REPO_ROOT/capabilities/session-agent.md"

assert_file "run-policy: core/operating-system.md exists" "$OS_DOC"
assert_file "run-policy: capabilities/session-agent.md exists" "$SA_DOC"

OS_CONTENT="$(cat "$OS_DOC" 2>/dev/null)"
SA_CONTENT="$(cat "$SA_DOC" 2>/dev/null)"

# === 1. The per-run-safety-posture umbrella section exists.
assert_contains "run-policy: operating-system names the posture section" \
  "$OS_CONTENT" "## Per-Run Safety Posture"

# === 2. Default-safe.
assert_contains "run-policy: posture defaults to safe" \
  "$OS_CONTENT" "defaults to **safe**"

# === 3. Declared/visible at run start (honest doc-contract wording — a stated
# contract, not a claimed hook-enforced lock).
assert_contains "run-policy: posture is declared at run start" \
  "$OS_CONTENT" "Declared at run start"

# === 4. Tighten-only, never loosen (the cannot-weaken-guards property).
assert_contains "run-policy: posture can only tighten, never loosen" \
  "$OS_CONTENT" "can only tighten the hard guards, never loosen them"

# === 5. Loosening is reserved to an explicit operator action — never the model's
# own reasoning or untrusted input. Pins the fix for the visible-loosening
# loophole so a future edit cannot reopen a model-self-loosening path.
assert_contains "run-policy: only an explicit operator action loosens a posture" \
  "$OS_CONTENT" "only an explicit operator action relaxes a posture"

# === 6-11. All hard guards are named in the precedence sentence, each on a phrase
# unique to that sentence — so an edit that drops one guard fails this gate instead
# of silently weakening the contract.
assert_contains "run-policy: names the secrets guard" \
  "$OS_CONTENT" "secrets and machine-private state stay out of the repo"
assert_contains "run-policy: names the project-history (tracker-ID) guard" \
  "$OS_CONTENT" "local project history"
assert_contains "run-policy: names the public-history guard" \
  "$OS_CONTENT" "stay out of shared framework content and public history"
assert_contains "run-policy: names the harness-neutrality guard" \
  "$OS_CONTENT" "shared content stays harness-neutral"
assert_contains "run-policy: names the one-way-door guard" \
  "$OS_CONTENT" "irreversible one-way doors never auto-decide"
assert_contains "run-policy: names the guard-contradiction (stop-for-user) guard" \
  "$OS_CONTENT" "a task that contradicts a deliberate guard stops for the user"

# === 12. The guard list is explicitly a floor, not an exhaustive ceiling.
assert_contains "run-policy: precedence list is a floor, not a ceiling" \
  "$OS_CONTENT" "This list is the floor, not the ceiling"

# === 13. Untrusted input (tool output / file content / memory / model output)
# cannot flip a guard off — the profile-poisoning precedence applied to the run.
assert_contains "run-policy: untrusted input cannot switch a guard off" \
  "$OS_CONTENT" "untrusted input can switch one off"

# === 14. Composes-with, never-replaces (safety-scoping + autonomy governance are
# preserved, not superseded — the additivity promise for this item).
assert_contains "run-policy: posture composes with, never replaces, existing controls" \
  "$OS_CONTENT" "never replaces"

# === 15. Visible-at-start wiring: the session-agent Mode 1 orient surfaces the
# posture line, so "visible at run start" cannot silently regress.
assert_contains "run-policy: session-agent Mode 1 orient surfaces the safety posture" \
  "$SA_CONTENT" "Safety posture:"
