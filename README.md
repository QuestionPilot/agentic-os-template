# agentic-os-template

Lightweight operating framework for AI agents.

This repository defines the shared AI operating system: how agents should work, learn, verify, and hand off context. Shared content stays harness-neutral — it carries no single-harness assumptions, tool names, hook names, plugin names, or harness-specific paths. Symmetric references to harness entrypoint conventions (`AGENTS.md` and `CLAUDE.md` named together) are fine, since naming both privileges neither. Single-harness details belong only in the matching root entrypoint file.

## Quickstart

**Who this is for:** operators who want to run an AI agent — Claude Code
(this quickstart), Codex (adapt `--harness codex` and use `AGENTS.md`), or Hermes Agent (`--harness hermes`, `SOUL.md` entrypoint) —
with structured memory, active-work tracking, and a self-improvement loop,
without hand-wiring each session from scratch.

**What problem it solves:** without a shared operating framework, every session
starts cold. The agent has no memory of past decisions, no standard way to
track work, and no consistent process for learning from mistakes. agentic-os-template
gives every agent session a common operating layer: orient → work → close out →
learn.

**First win in under 10 minutes:**

### 1. Prerequisites

Install the required CLIs (macOS shown; Windows: use `winget` / `npm` — see
`playbooks/new-machine-bootstrap.md` for the full platform matrix):

```bash
brew install gh jq
brew install --formula ripgrep   # provides rg
# Only if you target the Codex harness (bootstrap --harness codex):
npm install -g @openai/codex     # codex installs via npm, not brew
```

### 2. Clone and install

```bash
git clone https://github.com/<org>/agentic-os-template.git
cd agentic-os-template
bash scripts/bootstrap.sh --harness claude
```

`bootstrap.sh` seeds `local.env`, checks the required CLIs, compiles the
framework config, and prints the manual auth checklist. Pass `--dry-run` first to
preview all changes without writing anything.

The durable-knowledge vault (`OBSIDIAN_VAULT_PATH`) is **optional** — leave it
empty to start. The framework builds and runs without it; the entrypoint renders an
"unset" note and you can wire the layer later by setting the path in `local.env` and
re-running install. See `obsidian/vault-guide.md`.

By default config is **co-located**: a fresh clone renders into gitignored dirs
*inside the repo* (`<repo>/.claude`, plus `<repo>/.codex` for the codex harness)
and exports those paths to your shell, so everything runs self-contained from one
folder. Prefer your home dir (`~/.claude`, `~/.codex`)? Run with `--scattered`.
Hermes is never co-located (it's a live desktop-app home), and macOS GUI sessions
have a documented limit — see `playbooks/personal-fork.md`.

On Windows (PowerShell 7+, no bash required):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/bootstrap.ps1 -Harness claude
```

### 3. Open a session — the first capability run

Open Claude Code in any project that has a `CLAUDE.md` pointing at this
framework (see `examples/sample-project/CLAUDE.md` for the minimal pattern).

The `session-agent` capability fires automatically at session start
(Mode 1 orient). It:
- Loads your Linear tracker and vault context.
- Lists open issues and recent memory.
- Routes your first prompt to the smallest useful capability.

Type your first task. The agent is now operating with full context.

### 4. After the session

At the end of a meaningful session, run the `closeout` capability to
classify lessons and route them to the right source of truth
(`core/`, Linear, or your vault).

### More detail

- Runnable sample project: `examples/`
- Full bootstrap options: `playbooks/new-machine-bootstrap.md`
- Active-work tracker setup: `linear/linear-setup.md`
- Durable vault setup: `obsidian/vault-guide.md`
- Run it as your own OS (co-located config, personal fork): `playbooks/personal-fork.md`

---

## Governance

Do not modify shared framework content unless the user explicitly asks for it. Routine harness-specific edits are allowed only in the relevant root entrypoint file.

- Shared framework: `core/`, `capabilities/`, `playbooks/`, `verification/`, `linear/`, `obsidian/`, `skills/`, `templates/`, and `scripts/`.
- Harness entrypoints: `AGENTS.md` for Codex, `CLAUDE.md` for Claude Code, and `SOUL.md` (generated into the Hermes home) for Hermes Agent.
- Per-harness adapters: `harnesses/<h>/adapter.md` (contract) + `harnesses/<h>/capabilities/` (harness-native realizations emitted by the compiler). Edits here are scoped to a single harness and do not cross into shared content.

## Layout

| Path | Purpose |
| --- | --- |
| `AGENTS.md` | Thin Codex entrypoint into the shared framework. |
| `CLAUDE.md` | Thin Claude Code entrypoint into the shared framework. |
| `capabilities/` | Capability specs (`kind`, `triggers`, target `harnesses`, `verification` gate) — compiler input. |
| `harnesses/<h>/` | Per-harness adapter (`adapter.md` + `capabilities/`) that translates capabilities into harness-native config. |
| `core/` | Canonical harness-neutral operating rules. |
| `skills/` | Lightweight catalog of useful skills and how to install or apply them. |
| `playbooks/` | Reusable workflows for common workstreams. |
| `verification/` | Framework-level proof patterns for common work types. |
| `linear/` | Active-work system rules and issue templates. |
| `linear/linear-setup.md` | Canonical Linear setup + operating instructions + agentic-OS integration spec. |
| `obsidian/` | Long-term knowledge and wiki structure guidance. |
| `obsidian/vault-guide.md` | Canonical durable-vault setup + structure + agentic-OS integration spec. |
| `templates/` | Portable templates with placeholders, never local secrets. |
| `scripts/validate.sh` | Repository validation and safety checks. |

## Compiler Model

`scripts/install.sh` compiles per-harness configuration from two inputs:

1. **Capability specs** in `capabilities/*.md` — each spec declares its `kind` (`native` or `vendored`), `triggers`, target `harnesses`, and `verification` gate.
2. **Harness realizations** in `harnesses/<h>/capabilities/` — emit the harness-native artifacts (skills, hooks, settings) for the capabilities that target `<h>`.

The compiler enforces capability ↔ harness consistency (every listed harness has an `adapter.md`; every required capability key is present) before writing into the target dir (e.g. `$CLAUDE_CONFIG_DIR` for Claude Code, `$CODEX_HOME` for Codex, `$HERMES_HOME` for Hermes). A drift gate (`scripts/check-drift.sh --manifest`) detects hand-edits to compiled output.

## Security model

Framework scripts run with your shell's permissions. They read `local.env` (which you author), modify your harness config directory, install third-party CLIs via Homebrew / `npm` (macOS) or `winget` / `npm` (Windows), and write `CLAUDE_CONFIG_DIR` / `CODEX_HOME` into your shell rc (`~/.zshenv` on macOS) or your User-scope environment (Windows). On a system you do not control, audit the full first-run path — `scripts/bootstrap.{sh,ps1}` plus `scripts/install.sh`, `scripts/validate.sh`, the generated hooks they wire (`$TARGET/hooks/*.sh`), and every PATH-resolved CLI they call — not just the bootstrap entry points. Operator tools are advisory and operator-local — the framework does not vendor or endorse them.

**Trust boundaries:**

- `local.env` is operator-authored and sourced by `scripts/bootstrap.sh` and `scripts/install.sh`. It is gitignored (enforced by `scripts/validate.sh` `check_local_env_gitignored`) and never committed. **Override:** `scripts/install.sh` honors the `AI_CONFIG_LOCAL_ENV` environment variable — if set, install sources that path instead of the repo's `local.env`. Anyone who controls the process environment can therefore redirect the source target; the gitignore guarantee applies to the default path only.
- The framework executes by name (not absolute path): `brew`, `npm`, `winget`, `bash`, `jq`, `gh`, `git`, `codex`, `claude`. **PATH command shadowing is the simplest attack on an untrusted machine** — a malicious directory ahead of system paths in `PATH` can substitute any of these binaries. `-NoProfile` does NOT defend against this; only an audited PATH does. On Windows, also verify `$env:Path` and the User-scope environment haven't been tampered with before running bootstrap.
- Hook scripts (`harnesses/<h>/hooks/*.sh`) run as your shell user on every Claude Code / Codex session event. They never `eval` operator-supplied content. Specifically: the gate hook (`session-agent.sh`) extracts a `transcript_path` from the operator-supplied event JSON via `jq -r`, then reads that file as data through `grep` / `jq -c` / `awk` / `sed` — no command execution from event content. The surfacing hook (`framework-surface.sh`) discards stdin and runs `git -C "$AI_CONFIG_DIR" log` plus `claude mcp list`, parsing both as untrusted text. The gate hook fails closed (blocks) if `jq` is absent; the surfacing hook fails open (silent). Kill switches per-hook: `CLAUDE_SKIP_SESSION_AGENT=1`, `CLAUDE_SKIP_FRAMEWORK_SURFACE=1`, `CLAUDE_SKIP_MCP_PROBE=1`, `CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1`. (The `closeout` Stop hook and its `CLAUDE_SKIP_CLOSEOUT` switch were removed; closeout is now manual-fire.)
- `scripts/install.sh` compiles into a `mktemp -d` build dir on the target filesystem, validates, then swaps the managed subtrees into place — **staged build + best-effort rollback, NOT a single atomic rename across the whole target.** Most managed paths (e.g. `settings.json`, `hooks/`) are swapped via a single `mv` (close to atomic). `skills/` (all harnesses) and `plugins/` (hermes) are swapped per-subdir (one `mv` per `<base>` subdir, in a loop) so that operator-authored Shape C skills and operator-added plugins are preserved; a kill / power-loss mid-loop can leave the run-private root `$TARGET/.install-bak.d/<name>/<base>/` state behind (recovered conservatively on the next run). `rm -rf` operations are restricted to: the `mktemp` build dir; `.install-bak.<name>` backup paths under `$TARGET` (wholesale paths) plus the shared `$TARGET/.install-bak.d/` run-private root (per-subdir paths); manifest-tracked `$TARGET/<name>/<base>` paths the build produced or detected as stale orphans (orphan deletion is hash-gated — every file under the orphan must match the previous manifest's recorded hash). Operator-authored Shape C skills and operator-added plugins are preserved.

**Adjacent install instructions are out of band:**

- The framework's bootstrap scripts do NOT use `curl | sh`. However some adjacent setup docs (e.g. `linear/linear-setup.md` for the optional `lineark` CLI) reproduce the upstream installer's `curl -fsSL ... | sh` pattern. Audit any such instruction before running it, exactly as you would audit any third-party installer.

**Persistent machine mutation:**

- `scripts/bootstrap.sh` appends `export CLAUDE_CONFIG_DIR=<dir>` and `export CODEX_HOME=<dir>` to `~/.zshenv` (idempotent — any existing line is replaced). By default `<dir>` is co-located under the repo (`<repo>/.claude`, `<repo>/.codex`); `--scattered` uses `~/.claude` / `~/.codex`.
- `scripts/bootstrap.ps1` writes `CLAUDE_CONFIG_DIR` and `CODEX_HOME` to the User-scope Windows environment via `[System.Environment]::SetEnvironmentVariable(..., "User")`. This persists across reboots, applies to every shell, and — unlike the macOS shell export — is also read by Finder/Start-launched GUI apps.
- Hermes is never co-located: `HERMES_HOME` stays at `~/.hermes` (a live desktop-app home the app discovers on its own), and bootstrap writes no env export for it.
- Both writes are intentional, idempotent, and visible. Pass `--dry-run` (macOS) / `-DryRun` (Windows) to print the mutations without executing them.

**Windows operators:**

- Run `pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/bootstrap.ps1 -Harness claude`. `-ExecutionPolicy Bypass` is a per-invocation override (no machine-wide change). `-NoProfile` ensures your `$PROFILE` cannot shadow framework functions or aliases — but it does NOT defend against PATH command shadowing (see Trust boundaries above).
- CI workflows running framework PS scripts should default to `pwsh -NoProfile -NonInteractive`.

## Operating Model

1. Read the root entrypoint for the active harness.
2. Treat `core/` as canonical.
3. Use Linear for active work state.
4. Use Obsidian, or an approved equivalent, for long-term knowledge.
5. Apply the self-improvement loop at closeout.

For a fresh machine or harness setup, start with `playbooks/new-machine-bootstrap.md`.
For a new AI app or fresh harness instance, use `playbooks/new-harness-setup.md`.
For harness entrypoint setup, use `playbooks/harness-entrypoints.md`.
For data-heavy agentic OS work, use `playbooks/data-readiness-map.md`.
For autonomous or recurring work, use `playbooks/goal-run.md`.
For active-work planning across AI systems, use `linear/tool-agnostic-linear.md`.
For agent orientation in a new or unfamiliar project, use `playbooks/project-onboarding.md`.
For repository hygiene, privacy, and cleanup checks, use `playbooks/github-housekeeping.md`.
For changes that are published, deployed, or live-state-changing, use `playbooks/deploy-certification.md`.
For fixing a failing test, error, regression, or defect, use `playbooks/root-cause-debugging.md`.
For running the framework as your own personal OS (co-located config dirs, consumer postures, which publish-guards to drop), use `playbooks/personal-fork.md`.

## Golden Rule

Choose the most efficient path to the most effective outcome. If a method improves token use, time, cost, or operational friction without reducing correctness, coverage, or user-visible quality, prefer it.

## Self-Improvement Standard

A lesson is not learned until it changes a future behavior, check, task, script, decision, or durable note.

See `core/self-improvement.md` for the classification taxonomy. See `core/closeout.md` for the closeout block that records and routes each lesson.

## Hygiene Rules

See `core/security-and-secrets.md` for the full secrets-and-private-state policy. Day-to-day:

- Do not commit `.env`, auth files, local tool config, app caches, plugin caches, browser traces, screenshots, generated run output, or machine-specific absolute paths in agnostic framework files.
- Use `scripts/validate.sh` before commits and after syncs.
- Keep shared content concise. Link outward to Linear or Obsidian for detailed active or durable context.
