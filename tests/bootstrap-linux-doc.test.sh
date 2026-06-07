#!/usr/bin/env bash
# tests/bootstrap-linux-doc.test.sh — playbooks/new-machine-bootstrap.md
# must contain a Linux (apt-based) walked path covering the same steps as the
# macOS section.
#
# Test files are SOURCED by tests/run.sh — do NOT `exit`, do NOT re-source
# lib.sh, do NOT set -e. Just call assert_*.

BOOTSTRAP_PLAYBOOK="$REPO_ROOT/playbooks/new-machine-bootstrap.md"

assert_file "bootstrap-linux-doc: playbook exists" "$BOOTSTRAP_PLAYBOOK"

_pb="$(cat "$BOOTSTRAP_PLAYBOOK" 2>/dev/null)"

# --- Extract the Linux section (from '### Linux' through the next '###' heading) ---
# This scopes subsequent assertions to the Linux section only (Codex F-1: don't
# rely on whole-file token presence which passes even if content is in wrong section).
_linux_section="$(awk '/^### Linux/{found=1} found && /^### / && !/^### Linux/{found=0} found{print}' \
    "$BOOTSTRAP_PLAYBOOK" 2>/dev/null)"

assert_contains "bootstrap-linux-doc: playbook has a Linux (apt-based) section heading" \
    "$_linux_section" "### Linux (apt-based)"

# --- apt-get update in the Linux section ---
assert_contains "bootstrap-linux-doc: Linux section contains apt-get update" \
    "$_linux_section" "apt-get update"

# --- apt-get install in the Linux section (prerequisite step) ---
assert_contains "bootstrap-linux-doc: Linux section contains apt-get install" \
    "$_linux_section" "apt-get install"

# --- clone step in the Linux section ---
assert_contains "bootstrap-linux-doc: Linux section mentions git clone" \
    "$_linux_section" "git clone"

# --- bootstrap.sh invocation in the Linux section ---
assert_contains "bootstrap-linux-doc: Linux section references bootstrap.sh" \
    "$_linux_section" "bootstrap.sh"

# --- validate.sh step in the Linux section ---
assert_contains "bootstrap-linux-doc: Linux section references validate.sh" \
    "$_linux_section" "validate.sh"

# --- spine verification in the Linux section ---
assert_contains "bootstrap-linux-doc: Linux section references session-agent spine verification" \
    "$_linux_section" "session-agent"

# --- apt is documented as a pre-step, not implied as run by bootstrap.sh ---
# The playbook must NOT claim bootstrap.sh runs apt automatically.
assert_not_contains "bootstrap-linux-doc: Linux section does not claim bootstrap.sh invokes apt automatically" \
    "$_linux_section" "bootstrap.sh falls back to apt"

# --- No real local home paths baked in ---
# Runtime-construct the sentinel from non-matching halves so the test source
# does not self-trip validate.sh's absolute-path scanner. (feedback_self_tripping_test_source)
_linux_doc_pii_prefix="/Use"
_linux_doc_pii_suffix="rs/"
_linux_doc_pii="${_linux_doc_pii_prefix}${_linux_doc_pii_suffix}"
assert_not_contains "bootstrap-linux-doc: playbook contains no macOS home paths" \
    "$_pb" "$_linux_doc_pii"
