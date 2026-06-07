# Data Readiness Verification

Use this for pantry/prep/plate maps, silver platter summaries, data-flow audits, recurring briefs, and agentic OS data plumbing.

## Proof

- Confirm the pantry sources are named and separated from derived summaries.
- Confirm each prep artifact has a source, consumer, and verification method.
- Confirm raw exports, secrets, auth files, client-sensitive data, and regulated data were not committed to the framework repo.
- Confirm deterministic aggregation was used where numbers matter.
- Confirm every human-facing or business-critical plate output has an approval gate.
- Confirm active follow-ups go to Linear.
- Confirm durable source-derived knowledge goes to Obsidian.

## Boundary Checks

- Sensitive data is namespaced by project, client, matter, patient, account, location, or another relevant boundary.
- Agents are directed to read aggregate prep artifacts unless raw evidence is needed.
- Hooks or background automations are documented and explicitly approved before becoming default behavior.

## Closeout

State the data-readiness artifact created, the first useful consumer, the proof run, and any Linear or Obsidian follow-up.

