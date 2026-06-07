# Security Policy

## Reporting a Vulnerability

For an **unpatched vulnerability**, please open a placeholder issue on this repository's issue tracker — title only, with no technical reproduction details. Ask in the placeholder for a private channel; a maintainer will follow up to coordinate disclosure. Share reproduction details only in the private channel, never in the public issue.

For an **already-disclosed issue** (e.g. a CVE that is already public) or a general hardening question, a normal issue with full detail is fine.

## Scope

This policy covers:

- Framework scripts under `scripts/` (bash and PowerShell)
- Harness hook implementations under `harnesses/<harness>/hooks/`
- Verification scripts under `scripts/`, and the acceptance test runner under `tests/` where present
- Skill definitions under `skills/` and `capabilities/`

Out of scope:

- Third-party operator-local tools — report vulnerabilities upstream to the tool's maintainer
- Operator-local configuration (`local.env`, harness state, vault contents) — these are operator-managed and never tracked in this repository

## Threat Model Summary

Framework scripts run with the operator's shell permissions. They read `local.env` (which the operator authors), modify the harness config directory, and may install third-party CLIs via `winget`, Homebrew, `apt`, or `curl | sh` patterns. Audit `scripts/bootstrap.{sh,ps1}` before running on a system you do not control.

## Supported Versions

The project ships from `main`. There are no long-term support branches. If you find an issue, please confirm it reproduces on the latest `main` before filing.
