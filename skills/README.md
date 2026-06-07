# Skills

This folder holds the framework's **spine-only** skill surface plus the guidance
for authoring skills well. The framework ships only the three OS-spine
capabilities (see `registry.md`); concrete tool and app skills are operator-local
and are not kept in this repository.

| File | What it is |
| --- | --- |
| `registry.md` | The shipped spine capabilities + the baseline rule (stay spine-only). |
| `skill-authoring.md` | How to design a skill well — script-first architecture, body-size economics, load-bearing rules inline, structural testing, the agent-CLI rubric, promotion trust contract. |
| `skill-template.md` | The entry format for a new skill note. |

## Why spine-only

Tool and app skills — docs lookups, browser automation, design front doors,
database/CLI helpers, web research — are **operator-local**. They live in the
operator's own harness config, chosen and installed per machine, the same way the
active-work tracker (`../linear/linear-setup.md`) and durable-knowledge vault
(`../obsidian/`) are documented as contracts but never auto-installed. Keeping the
shipped surface spine-only means a fresh clone enables zero plugins and carries
zero tool opinions; everyone gets the self-improving spine and brings their own
tools.

## Authoring a new skill

1. Read `skill-authoring.md` for the design principles.
2. Use `skill-template.md` for the entry shape: purpose, when to use, when not to
   use, install or source, how it is used, verification, related playbooks.
3. Keep each note short — do not copy full upstream docs into this repository.
4. Prefer the clearer primitive: a rule, playbook, script, verification recipe, or
   harness note often beats a new skill.
5. Verify any installed or recreated skill with a harmless smoke test before
   relying on it.

For the general CLI-over-MCP preference when a tool offers both surfaces, see
`../core/tool-use.md`.
