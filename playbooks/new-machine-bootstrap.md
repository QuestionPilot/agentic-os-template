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

## Closeout

State which harness was configured, which active-work and knowledge systems were chosen, which skills were installed, and whether any setup gap remains.
