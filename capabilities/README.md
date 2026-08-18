# Capabilities — canonical agnostic capability specs

This directory is the **compiler input** for the agentic OS. Each `<name>.md` is one
capability: a small YAML header plus a harness-neutral body. A build script
(`scripts/install.sh`) compiles these specs into each
harness's native skill format, merging in the per-harness realization from
`harnesses/<harness>/capabilities/<name>.md`.

These specs carry **no harness-specific facts** — no tool names, hook event names,
skill-file schemas, or harness paths. Anything harness-specific lives in
`harnesses/<harness>/`. The body describes the *protocol*; the harness adapter
describes *how that harness runs it*.

## Two tiers

| `kind` | What it is | Body |
| --- | --- | --- |
| `native` | A capability authored for this OS (session-agent, closeout, self-audit). | Full harness-neutral protocol body. |
| `vendored` | An externally-maintained, asset-heavy skill (ships scripts/reference libraries/binaries). | Thin manifest only — provenance + how to install. The skill is **not re-authored here**; re-authoring would fork it from upstream and drop bundled logic. |

## Header schema

```yaml
---
name: <kebab-case — must equal the filename without .md>
summary: <one line — used to regenerate the harness skill catalog>
triggers: [<phrase>, <phrase>, ...]   # non-empty list
verification: <gate>                  # a gate name from verification/ (without .md), or "none"
harnesses: [<harness>, ...]           # non-empty; each must have a harnesses/<harness>/ adapter dir
kind: native | vendored
enforcement: <class>                  # OPTIONAL — a named enforcement class the harness adapter maps to a gate/hook
# vendored only — all three REQUIRED when kind: vendored
source: <where it comes from — repo URL, marketplace, or "internal">
version: <pinned version, or "unversioned">
install: <one-line install method>
---
```

- `verification` names the gate that work produced *via* this capability should be
  proven against. Pure routing/process capabilities use `none`.
- `enforcement` is a harness-neutral class name (e.g. `pre-edit-gate`). The
  harness adapter (`harnesses/<harness>/adapter.md`) maps the class to a concrete
  enforcement mechanism. A capability only *names* its class; it never describes
  the mechanism. (The `session-end-gate` and `prompt-scan` classes were removed
  and are no longer declared by any capability.)
- `harnesses` lists the harnesses that currently receive this capability. Each
  listed value must have a `harnesses/<value>/` adapter directory; the
  framework ships four adapters today (`claude`, `codex`, `hermes`, and
  `cursor`).

`scripts/validate.sh` checks every header for completeness against this schema.
