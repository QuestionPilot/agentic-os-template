#!/usr/bin/env bash
# new-project.sh — scaffold a framework-aware project workspace under projects/.
#
# The framework ships two project entrypoint templates —
# templates/project-CLAUDE.md (Claude Code) and templates/project-AGENTS.md
# (Codex) — and this script is their tracked consumer: it copies both into a
# fresh projects/<name>/ folder so a session opened there reads a thin,
# project-local entrypoint while the OS spine (session-agent, closeout,
# self-audit, the operating rules) stays shared from the compiled harness
# config. Nothing else is copied — the framework is referenced, not vendored,
# so a `git pull` of framework updates reaches every project at once.
#
# projects/ is the operator's LOCAL workspace: the tracked .gitignore covers it
# (see the projects/ entry there), so real project work never pollutes the
# framework's tracked tree and never conflicts with framework updates. Each
# scaffolded project can be its own git repo (--git) or a plain working folder.
#
# Usage: scripts/new-project.sh <name> [--git]
#   <name>   project folder name; created at <repo-root>/projects/<name>
#   --git    also `git init` the new project folder
set -euo pipefail

name="${1:-}"
case "$name" in
  ''|-*)
    echo "usage: $0 <project-name> [--git]" >&2
    exit 1
    ;;
  */*|*\\*|.|..)
    # One plain folder name only — separators and dot-dirs would scaffold
    # outside projects/ (or into nothing nameable) on one platform or the other.
    echo "error: project name must be a plain folder name (got: $name)" >&2
    exit 1
    ;;
esac

do_git=0
if [ "$#" -ge 2 ]; then
  if [ "$#" -eq 2 ] && [ "$2" = "--git" ]; then
    do_git=1
  else
    echo "usage: $0 <project-name> [--git]" >&2
    exit 1
  fi
fi

# `CDPATH=` neutralizes a hostile CDPATH (same guard as install.sh): without
# it, `cd` on a relative path could resolve via a CDPATH entry and echo the
# resolved path into the command substitution, corrupting both variables.
here="$(CDPATH= cd "$(dirname "$0")" && pwd)"
repo_root="$(CDPATH= cd "$here/.." && pwd)"
dest="$repo_root/projects/$name"

# Fail before creating anything if the checkout is missing either template —
# a half-scaffolded project (one entrypoint) orients only one harness.
for tpl in project-CLAUDE.md project-AGENTS.md; do
  if [ ! -f "$repo_root/templates/$tpl" ]; then
    echo "error: missing template $repo_root/templates/$tpl (run from a framework checkout)" >&2
    exit 1
  fi
done

if [ -e "$dest" ]; then
  echo "error: $dest already exists" >&2
  exit 1
fi

mkdir -p "$repo_root/projects"
mkdir "$dest"
cp "$repo_root/templates/project-CLAUDE.md" "$dest/CLAUDE.md"
cp "$repo_root/templates/project-AGENTS.md" "$dest/AGENTS.md"

if [ "$do_git" -eq 1 ]; then
  # Explicit failure branch so both twins exit 1 with the same message —
  # under bare `set -e` this would exit with git's own status instead.
  if ! git -C "$dest" init -q; then
    echo "error: git init failed in $dest" >&2
    exit 1
  fi
  echo "initialized git repo in $dest"
fi

echo "created project: $dest"
echo "  - CLAUDE.md (Claude Code entrypoint)"
echo "  - AGENTS.md (Codex entrypoint)"
echo
echo "next:"
echo "  cd \"$dest\""
echo "  # edit the '## Project context' section, then run: claude   (or: codex)"
