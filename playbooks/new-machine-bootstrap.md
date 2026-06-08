# New Machine Bootstrap

Use this playbook when setting up the AI operating framework on a new computer, workspace, or agent harness.

## Goal

Install the framework without importing stale project history, local secrets, machine-specific paths, or one-device capabilities.

## Automated Setup

### macOS

```bash
bash scripts/bootstrap.sh [--check] [--dry-run] [--harness claude]
```

### Linux (apt-based)

Linux uses the same `bootstrap.sh` bash path as macOS. Pre-install the required
CLIs via `apt` (and `npm` for `codex`) before running `bootstrap.sh` — the script
does not invoke `apt` automatically.

**Step 1 — install prerequisites:**

```bash
# git, curl, and npm (needed for codex); gh, jq, rg via apt or their own installers
sudo apt-get update
sudo apt-get install -y git curl nodejs npm jq ripgrep

# GitHub CLI (gh) — official apt repo (https://cli.github.com):
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update && sudo apt-get install -y gh
```

**Step 2 — clone and run bootstrap:**

```bash
git clone <your-fork-or-org-repo-url> ~/ai-config
cd ~/ai-config

bash scripts/bootstrap.sh --check                  # preview what is missing
bash scripts/bootstrap.sh [--harness claude]        # full run
```

`bootstrap.sh` can install `codex` via `npm`. On Linux, `gh`, `jq`, and `rg` must
be pre-installed as shown above — `bootstrap.sh`'s automated install path for
these uses `brew`, which is not present on most Linux systems. After the script
completes, open a new shell (or `source ~/.bashrc`) so the `CLAUDE_CONFIG_DIR`
export takes effect.

**Step 3 — verify the spine:**

```bash
bash scripts/validate.sh                            # must exit 0
# Confirm session-agent skill is installed:
ls "$CLAUDE_CONFIG_DIR/skills/session-agent/"
```

### Windows (native PowerShell 7+)

```powershell
pwsh scripts/bootstrap.ps1 [-Check] [-DryRun] [-Harness claude]
```

`bootstrap.ps1` is fully native — it does NOT require `bash` (Git Bash, WSL,
MSYS2). It routes `install` + smoke-test through `install.ps1` + `validate.ps1`
via `pwsh -NoProfile -File`. Required CLIs (all platforms): `codex`, `gh`, `jq`,
`rg`. Tool and app skills are operator-local — install whatever this machine
needs at operator discretion; the framework wires none of them.

The script: sets the chosen harness's config-dir env var in your shell environment
(`CLAUDE_CONFIG_DIR` for the claude harness, `CODEX_HOME` for codex), checks the
required CLIs (codex, gh, jq, rg) and installs missing ones (via
`brew` on macOS / `npm` for codex / `winget` on Windows — pre-install via `apt` on
Linux before running), seeds `local.env` from the template, runs the harness
compiler (`install.sh` on macOS/Linux, `install.ps1` on Windows), and prints the
manual auth checklist. Use `--check` (bash) / `-Check` (PowerShell) first to see
what's missing without making any changes.

## Manual Steps (if not using bootstrap.sh)

1. Clone the framework repo into a normal local workspace.
2. Run `scripts/validate.sh` before using any files.
3. Pick the active root harness entrypoint, such as `AGENTS.md` or `CLAUDE.md`.
4. Use `playbooks/harness-entrypoints.md` to copy or reference only the entrypoint needed by that harness.
5. Use `playbooks/new-harness-setup.md` to install or recreate the minimum useful router skills.
6. Configure your active-work tracker. The framework's canonical example is **Linear** — follow [`linear/linear-setup.md`](../linear/linear-setup.md) §3 (First-time setup) end-to-end. Pick a surface (`lineark` CLI or Linear MCP); the framework treats both as first-class. If you use a different tracker (Jira, GitHub Projects, etc.), adapt the runtime contract documented in `linear/linear-setup.md` §5 — capability bodies are tracker-surface-agnostic. The framework's spine continues to function with no tracker installed (a one-line warning surfaces the gap).
7. Configure your durable knowledge layer. The framework's canonical example is a local **Obsidian-format vault** — follow [`obsidian/vault-guide.md`](../obsidian/vault-guide.md) §3 (First-time setup) end-to-end. Set `OBSIDIAN_VAULT_PATH` in `local.env` per `templates/local.env.example`. Confirm `$OBSIDIAN_VAULT_PATH/START.md` exists before relying on session-agent kickoff orient. If you prefer Notion, Logseq, Bear, or another note system, map the §4 + §5 shapes onto your tool of choice; capability bodies do not lock to any one writer.
8. The framework ships only the spine capabilities (`skills/registry.md`); install any tool or app skills you need as operator-local skills.
9. Add project-local instructions from `templates/` only inside the target project.

## Do Not Import

- raw transcripts
- old project folders
- local auth state
- plugin caches
- browser traces
- generated artifacts
- machine-specific absolute paths
- device-dependent review lanes unless the machine explicitly supports them

## Smoke Test

- `scripts/validate.sh` passes.
- The selected entrypoint points back to this framework.
- The active-work tracker and the durable vault are separate.
- Router skills are installed or recreated before broad leaf-skill installation.
- A project-local instruction file points back to the framework without duplicating it.

## Resume Verification

Setup (above) proves the spine *installs*. This step verifies it *orients and resumes* — the literal definition of done for a portable brain: **a clean clone must reconstitute a working, oriented spine that resumes prior work.** Two tiers: the **live check** is the real proof (a fresh session's orient surfaces your actual in-flight work); the **sandboxed dry-run** proves the orient *machinery* is wired, without live credentials.

### Live check (operator machine — the real bar)

After the tracker and vault are connected (Manual Steps 6–7), start a session and let the spine run its kickoff orient. It passes when the orient surfaces in-flight work on its own:

- active tracker projects and their open issues (the projects-first cut),
- the durable vault's `START.md` and recent project memory,
- any contradiction between recent framework commits and memory headlines.

If you can read back the current frontier and resume the next action from a cold start, the resume invariant holds.

### Sandboxed dry-run (no live credentials)

To prove the orient *machinery* is wired — the spine renders and a fresh session auto-fires the kickoff-orient directive — without live credentials or mutating the real machine, run the first-run path in a throwaway sandbox: clean clone, fake `HOME`, scratch config and vault. The required CLIs must already be present; the sandbox stops at `--check` rather than installing any globally (Homebrew / `npm -g` are not contained by a fake `HOME`).

```bash
set -euo pipefail
SRC=<path-to-your-clone-or-repo-url>          # committed state is cloned — commit local changes first
S=$(mktemp -d); CLONE=$S/clone; H=$S/home; CFG=$S/config; VLT=$S/vault
mkdir -p "$H" "$VLT"; printf -- '---\ntitle: START\n---\n# START\n' > "$VLT/START.md"
git clone --quiet "$SRC" "$CLONE"
# Drop inherited config-dir / vault / codex env so the scratch flags drive the
# build — NOT a PATH security boundary (see README "Trust boundaries" for that).
run() { env -i PATH="$PATH" HOME="$H" TMPDIR="$S" "$@"; }

run bash "$CLONE/scripts/bootstrap.sh" --check                       # read-only; aborts here if a required CLI is missing — never installs one
run bash "$CLONE/scripts/bootstrap.sh" --dry-run --harness claude \
    --claude-config-dir "$CFG" --vault-dir "$VLT" || true            # preview; its own smoke step flags the not-yet-built entrypoint — expected
[ ! -e "$CFG" ] && echo "OK: dry-run built nothing"
run bash "$CLONE/scripts/bootstrap.sh" --harness claude \
    --claude-config-dir "$CFG" --vault-dir "$VLT"                    # real build INTO scratch (CLIs already present per --check)

ls "$CFG"/skills/session-agent >/dev/null && echo "OK: session-agent skill rendered"
grep -q framework-surface "$CFG/settings.json" && echo "OK: orient hook wired into the config"
printf '%s' '{"source":"startup"}' | run bash "$CFG/hooks/framework-surface.sh" \
  | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'Mode 1: kickoff orient' \
  && echo "OK: a fresh session auto-fires the kickoff-orient directive"
rm -rf "$S"                                                          # the sandbox is disposable
```

Each `OK:` confirms one piece of the orient *machinery* — the spine renders and a fresh session auto-fires the kickoff-orient directive. It does **not** prove the orient *ran*: no skill invocation, tracker query, or vault read happens here — that is what the live check above proves. (Windows: mirror with `pwsh scripts/bootstrap.ps1 -Check` / `-DryRun`, then assert against `$CFG/hooks/framework-surface.ps1` the same way.)

### What still needs the operator's machine

The sandbox proves the *machinery*; it cannot prove the *content*. Only a real session — with the live tracker token and the synced vault — proves the orient surfaces the actual in-flight projects and issues. That live check is the final, irreducible step, and it is the operator's to run.

## Closeout

State which harness was configured, which active-work and knowledge systems were chosen, which skills were installed, and whether any setup gap remains.
