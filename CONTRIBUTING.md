# Contributing

Thanks for considering a contribution. This document covers what to expect when sending an issue or pull request.

## Before You Start

- Read `README.md` for an overview of the framework's structure and goals.
- Read the relevant capability or playbook before editing it — most are short and self-contained.
- Run `make verify` from the repo root before making changes — it runs the verification gates (the acceptance suite when present, static validation, and drift), failing fast.

## Filing Issues

Open an issue at this repository's issue tracker. Useful issues include:

- A clear summary in the title.
- The framework version (commit hash or release tag) you are running against.
- Reproduction steps when reporting a bug.
- Expected vs actual behavior.
- Relevant environment details (OS, shell, harness in use).

If you are unsure whether something is a bug or a design choice, file the issue and ask. It is better to surface confusion than to silently work around it.

## Pull Requests

1. Fork the repository and create a topic branch from `main`.
2. Make your change. Keep it focused — one logical change per PR.
3. Cover the change with a test under `tests/` where the acceptance suite is present. New behavior without a test is hard to land.
4. Run `make verify` from the repo root. The verification gates — acceptance suite (when present), static validation, and drift check — should all pass. On a fresh clone, before you have run `bootstrap`/`install`, the drift gate self-skips (there is no rendered config to diff yet), so `make verify` runs the suite plus validation.
5. Write a clear PR description: what changed, why, and how to verify.
6. Reference the issue your PR addresses (if any).

A maintainer will review when time permits. Expect requests for changes — the framework prefers small, well-explained patches over large reworks.

## Style and Conventions

- Bash scripts: target Bash 3.2 (macOS default). Avoid `declare -A`, `mapfile`, and other Bash 4+ features unless the script is explicitly platform-gated.
- PowerShell scripts: target PowerShell 7+ cross-platform.
- Markdown: use ATX headers (`#`, `##`), fenced code blocks, and prefer concise sentences over long paragraphs.
- Filenames: kebab-case for `agentic-os-template/` content (`memory-model.md`); title-case for vault notes (`Memory Core.md`).
- Do not add operator-local paths, secrets, or machine-specific configuration to tracked files.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By participating, you agree to abide by its terms.

## License

By contributing, you agree that your contributions will be licensed under the same MIT License that covers the project (see `LICENSE`).
