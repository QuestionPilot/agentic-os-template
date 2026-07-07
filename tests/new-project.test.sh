#!/usr/bin/env bash
# tests/new-project.test.sh — behavioral tests for scripts/new-project.sh.
#
# The scaffold copies templates/project-CLAUDE.md + templates/project-AGENTS.md
# into <repo-root>/projects/<name>/ as CLAUDE.md + AGENTS.md — it is the tracked
# consumer of those two templates, so these tests also pin the template CONTRACT
# a scaffolded project depends on (the '## Project context' section the docs
# tell the operator to edit). Exit 0 = scaffolded; 1 = usage/exists/invalid-name/
# missing-template errors.
#
# Scaffolding runs inside a throwaway fixture repo-root (scripts/ + templates/
# copied in) — never against $REPO_ROOT itself, so no projects/ folder is ever
# created in the tree under test.
#
# Sourced by tests/run.sh; do NOT set -e or call exit.

CMD_SCRIPT="$REPO_ROOT/scripts/new-project.sh"
assert_file "np: scripts/new-project.sh exists" "$CMD_SCRIPT"
assert_file "np: scripts/new-project.ps1 twin exists" "$REPO_ROOT/scripts/new-project.ps1"

# _mkfixture <dir> — a minimal framework checkout: the scaffold script + the two
# templates it consumes, laid out at the paths the script derives from its own
# location (repo_root = parent of scripts/).
_mkfixture() {
  local r="$1"
  mkdir -p "$r/scripts" "$r/templates"
  cp "$CMD_SCRIPT" "$r/scripts/"
  cp "$REPO_ROOT/templates/project-CLAUDE.md" "$r/templates/"
  cp "$REPO_ROOT/templates/project-AGENTS.md" "$r/templates/"
}

FIX=$(mktemp -d 2>/dev/null) || FIX="/tmp/np-fix-$$"
_mkfixture "$FIX"

# === 1. Plain scaffold: exit 0, both entrypoints exist, output names the dest.
OUT1=$(bash "$FIX/scripts/new-project.sh" demo 2>&1); RC1=$?
assert_eq "np: scaffold exits 0" "0" "$RC1"
assert_file "np: CLAUDE.md scaffolded" "$FIX/projects/demo/CLAUDE.md"
assert_file "np: AGENTS.md scaffolded" "$FIX/projects/demo/AGENTS.md"
assert_contains "np: output names the created project" "$OUT1" "created project:"
assert_contains "np: output points at the Project context edit" "$OUT1" "## Project context"

# === 1b. Hostile CDPATH cannot corrupt path resolution (the CDPATH= guard,
# same as install.sh). Relative invocation from the fixture root is what makes
# an exported CDPATH bite. Bash-only: the PS twin's Set-Location ignores CDPATH,
# so this test has no .ps1 mirror.
OUT1B=$(cd "$FIX" && CDPATH=. bash scripts/new-project.sh cdpathproj 2>&1); RC1B=$?
assert_eq "np: scaffold immune to exported CDPATH" "0" "$RC1B"
assert_file "np: CDPATH-run scaffold created CLAUDE.md" "$FIX/projects/cdpathproj/CLAUDE.md"

# === 2. Scaffolded entrypoints are byte-identical to their templates.
assert_exit "np: CLAUDE.md byte-identical to project-CLAUDE.md" 0 -- \
  cmp -s "$FIX/templates/project-CLAUDE.md" "$FIX/projects/demo/CLAUDE.md"
assert_exit "np: AGENTS.md byte-identical to project-AGENTS.md" 0 -- \
  cmp -s "$FIX/templates/project-AGENTS.md" "$FIX/projects/demo/AGENTS.md"

# === 3. The template contract: both scaffolded entrypoints carry the
# '## Project context' section the scaffold's next-steps output tells the
# operator to edit.
assert_exit "np: scaffolded CLAUDE.md carries ## Project context" 0 -- \
  grep -q '^## Project context$' "$FIX/projects/demo/CLAUDE.md"
assert_exit "np: scaffolded AGENTS.md carries ## Project context" 0 -- \
  grep -q '^## Project context$' "$FIX/projects/demo/AGENTS.md"

# === 4. Existing destination fails closed with a message naming it.
OUT4=$(bash "$FIX/scripts/new-project.sh" demo 2>&1); RC4=$?
assert_eq "np: existing dest exits 1" "1" "$RC4"
assert_contains "np: existing dest error says already exists" "$OUT4" "already exists"

# === 5. Usage errors: no args, flag-shaped name, unknown second arg.
OUT5=$(bash "$FIX/scripts/new-project.sh" 2>&1); RC5=$?
assert_eq "np: no args exits 1" "1" "$RC5"
assert_contains "np: no args prints usage" "$OUT5" "usage:"
assert_exit "np: flag-shaped name (--git) rejected" 1 -- \
  bash "$FIX/scripts/new-project.sh" --git
assert_exit "np: unknown second arg rejected" 1 -- \
  bash "$FIX/scripts/new-project.sh" other --frog

# === 6. Invalid names fail closed: path separators and dot-dirs would scaffold
# outside projects/ on one platform or the other.
assert_exit "np: slash name rejected" 1 -- bash "$FIX/scripts/new-project.sh" "a/b"
assert_exit "np: backslash name rejected" 1 -- bash "$FIX/scripts/new-project.sh" 'a\b'
assert_exit "np: dot-dot name rejected" 1 -- bash "$FIX/scripts/new-project.sh" ".."

# === 7. --git initializes a repo inside the new project.
assert_exit "np: --git scaffold exits 0" 0 -- \
  bash "$FIX/scripts/new-project.sh" gitproj --git
assert_exit "np: --git created a .git dir" 0 -- test -d "$FIX/projects/gitproj/.git"

# === 7b. --git failure path: exit 1 + the same message as the PS twin (a stub
# git that always fails, prepended to PATH — the twins' error contract).
STUB=$(mktemp -d 2>/dev/null) || STUB="/tmp/np-stub-$$"
printf '#!/bin/sh\nexit 3\n' > "$STUB/git"
chmod +x "$STUB/git"
OUT7B=$(PATH="$STUB:$PATH" bash "$FIX/scripts/new-project.sh" gitfail --git 2>&1); RC7B=$?
assert_eq "np: --git failure exits 1 (not git's raw status)" "1" "$RC7B"
assert_contains "np: --git failure names git init" "$OUT7B" "git init failed"

# === 8. Missing templates fail closed BEFORE creating anything.
FIX2=$(mktemp -d 2>/dev/null) || FIX2="/tmp/np-fix2-$$"
mkdir -p "$FIX2/scripts"
cp "$CMD_SCRIPT" "$FIX2/scripts/"
OUT8=$(bash "$FIX2/scripts/new-project.sh" demo 2>&1); RC8=$?
assert_eq "np: missing templates exits 1" "1" "$RC8"
assert_contains "np: missing templates error names the template" "$OUT8" "missing template"
assert_exit "np: missing templates creates no projects dir" 1 -- test -e "$FIX2/projects"

# === 9. The tracked .gitignore covers projects/ — hermetic check in a throwaway
# git repo (the operator's .git/info/exclude cannot mask a regression here).
TR=$(mktemp -d 2>/dev/null) || TR="/tmp/np-tr-$$"
git -C "$TR" init -q
cp "$REPO_ROOT/.gitignore" "$TR/.gitignore"
mkdir -p "$TR/projects/x"
printf 'scaffolded\n' > "$TR/projects/x/CLAUDE.md"
assert_exit "np: projects/ path is gitignored by the tracked .gitignore" 0 -- \
  git -C "$TR" check-ignore -q projects/x/CLAUDE.md
STATUS9=$(git -C "$TR" status --porcelain -- projects 2>&1)
assert_eq "np: scaffolded workspace invisible to git status" "" "$STATUS9"

rm -rf "$FIX" "$FIX2" "$TR" "$STUB"
