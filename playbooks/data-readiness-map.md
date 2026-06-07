# Data Readiness Map

Use this playbook before building agents, automations, dashboards, recurring briefs, or long-running analysis over messy business data.

## Principle

Most agent leverage comes from preparing the data before asking the model to reason.

Agents should analyze concise, source-derived prep artifacts instead of repeatedly loading raw exports, PDFs, transcripts, screenshots, JSON, or large folders.

## Pantry, Prep, Plate

| Layer | Meaning | Example |
| --- | --- | --- |
| Pantry | Raw data sources and systems | SaaS tools, Drive folders, PDFs, exports, transcripts, APIs |
| Prep | Deterministic summaries and source-derived briefs | weekly tables, converted markdown, source indexes, data maps |
| Plate | Human-facing outputs and decisions | briefs, recommendations, reports, Linear issues, approved actions |

## Steps

1. Audit the current folder or system before asking broad questions.
2. Identify pantry sources: tools, files, APIs, exports, transcripts, and source folders.
3. Identify access: manual export, CLI, API, connector, browser, or local file.
4. Identify prep artifacts: summary table, source index, weekly brief, converted markdown, or data map.
5. Identify plate outputs: brief, decision, report, task, automation, or human approval route.
6. Name the consumer for every prep artifact.
7. Add boundaries for sensitive data, client data, matter data, patient data, account data, or tenant data.
8. Create opportunities for gaps that block repeated value.

## Silver Platter Rule

A silver platter is a concise source-derived summary that gives an agent the useful cuts before it reasons.

Create one when:

- raw data is too large for repeated reading
- the source is messy or non-text
- the same question recurs
- the source is sensitive or needs namespacing
- the agent would spend most of the session retrieving instead of analyzing

## Tool-Agnostic Implementation

- Use a connector or MCP-style tool when it safely exposes structured app data.
- Use a CLI when it gives repeatable data with less overhead.
- Use a small script when deterministic aggregation is needed.
- Use direct API work when no connector or CLI exists.
- Use hooks only after explicit review because they create hidden behavior and are harness-specific.
- Use a skill only when the workflow is repeated, bounded, and not better represented as a script or playbook.

## Output

Produce a small map with:

- pantry sources
- prep artifacts
- plate outputs
- approval gates
- boundary risks
- opportunities
- next action destination

Active follow-ups belong in Linear. Durable knowledge belongs in Obsidian. Shared operating changes belong in this repository.

