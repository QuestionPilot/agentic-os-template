# Code Change Verification

Use for source-code changes, scripts, tests, or behavior changes.

## Proof

- Run the smallest targeted tests for the changed behavior.
- Run type, lint, format, or shell syntax checks when relevant.
- Run a smoke test if the code has runtime behavior.
- Inspect failures directly before claiming completion.
- When the change is a fix, follow `../playbooks/root-cause-debugging.md`: demonstrate the root cause before editing and ship a regression test that would have caught the bug.
- Decide whether independent review is warranted by risk.

## Review cuts

Two cheap, mechanical passes to run on the diff before opening a PR:

- **Git hygiene.** Every runtime-artifact path the change writes — open-for-write, `>`/`>>`, `mkdir`, `touch`, logs, caches, lockfiles, generated output — must be matched by a `.gitignore` rule. An unignored artifact path lets an auto-committer or a tree-walking scanner pick up runtime files and self-pollute (the failure class behind the framework's own scanner-vs-gitignore fixes).
- **Delete more than you add.** When a change is net +500 lines with fewer than ~50 deletions, stop and name pruning candidates before shipping. Additive-only growth is how a codebase bloats; a large net-positive diff is the prompt to ask what the change makes redundant — consistent with a boring-is-beautiful posture.

## Pre-PR

For changes inside this repository, run `make verify` from the repo root — runs the acceptance suite (`tests/run.sh`) when present, then `scripts/validate.sh` and `scripts/check-drift.sh --manifest "$CLAUDE_CONFIG_DIR"` in sequence, failing fast on first non-zero exit.

## Closeout

State changed-surface proof, skipped checks, independent review decision, and residual risk.
