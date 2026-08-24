#!/usr/bin/env node
// generate-session-index.js — the generated 90-Indexes/Session Index view.
//
// Same contract as generate-harness-index.js: the index is DERIVED from
// 30-Archive/Sessions/*.md and never hand-edited — regeneration is the only
// write path, and the vault audit fails on drift.
//
// WHY THIS EXISTS. The session archive is the only durable record of what was
// actually DONE, but as an undifferentiated pile of closeout logs it answers
// nothing: "which sessions touched this issue?" or "what did the other machine
// do?" means grepping every log and hoping the frontmatter spelled things the
// same way. It does not — see NORMALIZATION. This view turns the archive into a
// filterable surface over five dimensions: machine, harness, issue, date, and
// recall-failure class.
//
// EMPTY STATE IS A REAL STATE, NOT AN ERROR. A vault that has not run a closeout
// yet has zero session logs, and that is correct, not broken. The view is still
// written — it says plainly that the corpus is empty and that it will populate
// as closeouts land. What it must NEVER do is claim coverage of content it did
// not read: a header-only view that silently reads as "the archive is indexed"
// is the false clean this index exists to prevent. So the empty view states the
// zero explicitly, omits the sessions table entirely rather than printing an
// empty one, and stays byte-stable so `--check` is deterministic from day one.
//
// NORMALIZATION — the load-bearing part, not cosmetics.
// Hand-written frontmatter accumulates several spellings of the same value: a
// harness recorded as both `claude` and `claude-code`, a host recorded both bare
// and with its `.local` mDNS suffix. A filter over the raw values silently
// splits one machine across several names and drops part of a harness's
// sessions — a false clean of exactly the kind this index exists to kill. So the
// generator folds each value to a canonical token, and the canonical value IS
// the queryable one. Folding is deliberately CONSERVATIVE: only spellings
// positively identified as the same thing are folded (`claude-code` → `claude`;
// a trailing `.local` is dropped), and an unrecognized value passes through
// lowercased rather than being guessed into a bucket — so a new machine or
// harness shows up as itself instead of being absorbed into an existing one.
// Machine fold pairs are LOCAL DATA, not code — see LOCAL CONFIG below. Add a
// pair only for spellings you have CONFIRMED are the same thing.
//
// LOCAL CONFIG — operator-local behavior lives in data, not in code edits.
// An optional `bin/session-index.local.json` (next to this script, never
// committed to a shared template) carries per-vault settings, so a live vault
// can keep operator-specific behavior while running this file byte-identical
// to its template twin — that is what lets a code-level drift check between the
// two stay meaningful. Recognized keys, all optional:
//   machineFolds     object mapping an already-lowercased, `.local`-stripped
//                    machine spelling to its canonical token,
//                    e.g. {"old-hostname": "current-hostname"}
//   failOnEmptyCorpus  boolean; true = a missing OR empty 30-Archive/Sessions
//                    is a corpus-integrity failure (exit 2) instead of a valid
//                    fresh-vault state. Set it once the vault HAS an archive:
//                    from then on "no logs found" means the archive is gone
//                    (unmounted drive, bad root), not that history vanished.
//   viewTag          string; extra tag written into the view's frontmatter
//                    (default "memory-vault/retrieval") so a vault keeps its
//                    own tag taxonomy.
// A present-but-unreadable or malformed config file is a loud exit-2 failure —
// silently ignoring it would silently change what the index claims.
//
// ROOT OVERRIDE — $VAULT_AUDIT_ROOT resolves the vault root instead of this
// script's parent directory. A test-injection seam (fixture vaults in tmp
// dirs), same pattern as RETRIEVAL_EVALS_NATIVE_ROOT in retrieval-evals.sh;
// the audit forwards its own resolved root to this generator so parent and
// child can never disagree about which tree they are checking.
//
// RECALL-FAILURE CLASS — consumes an existing contract, does not re-invent one.
// The markers below are kept byte-identical (modulo the POSIX-ERE-to-JavaScript
// translation of `[[:space:]]` → `[ \t]`) to the ones in `scripts/recall-report.sh`
// in the framework repo, which defines MEANINGFUL_RE and RECORD_RE for the same
// closeout-log corpus. If those markers ever change, change them here in the
// SAME commit — two readers of one log format that disagree will each report a
// confident, different number. The class tokens are the same two that report
// knows, plus the same `unclassified` escape hatch for a record whose class
// token is neither: a typo or a newly-invented class stays VISIBLE rather than
// being binned into a class it does not belong to.
//
// Usage:
//   node bin/generate-session-index.js            # (re)write the view
//   node bin/generate-session-index.js --check    # exit 1 if view drifted
//
// Exit codes:
//   0  view written, or (with --check) the shipped view matches regeneration
//   1  (--check only) the view has drifted from regeneration
//   2  corpus integrity failure — distinct from drift so a human and the audit
//      can tell "the index is stale" from "the archive is unreadable"
//
// Determinism: logs sort by filename via plain UTF-16 comparison (no locale).
// Filenames are `YYYY-MM-DD-HHMMSS-...`, so that sort IS chronological — the
// same property scripts/recall-report.sh relies on for its window. The output
// carries no timestamps and no counts that depend on the clock: same tree in,
// same bytes out.

const fs = require("fs");
const path = require("path");

const root = process.env.VAULT_AUDIT_ROOT
  ? path.resolve(process.env.VAULT_AUDIT_ROOT)
  : path.resolve(__dirname, "..");

const SESSIONS_DIR = "30-Archive/Sessions";
const VIEW_PATH = "90-Indexes/Session Index.md";
const CONFIG_PATH = path.join(__dirname, "session-index.local.json");

// Loaded once in main(), inside the exit-2 error boundary — see LOCAL CONFIG
// in the header for the recognized keys and why a broken config fails loud.
let LOCAL = {};

function loadLocalConfig() {
  if (!fs.existsSync(CONFIG_PATH)) return {};
  let raw;
  try {
    raw = fs.readFileSync(CONFIG_PATH, "utf8");
  } catch (err) {
    throw new Error(
      `local config unreadable: bin/session-index.local.json — ${err.message}`,
    );
  }
  let cfg;
  try {
    cfg = JSON.parse(raw);
  } catch (err) {
    throw new Error(
      `local config malformed: bin/session-index.local.json — ${err.message}`,
    );
  }
  if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) {
    throw new Error(
      "local config malformed: bin/session-index.local.json — expected a JSON object",
    );
  }
  if (cfg.machineFolds !== undefined) {
    if (
      cfg.machineFolds === null ||
      typeof cfg.machineFolds !== "object" ||
      Array.isArray(cfg.machineFolds)
    ) {
      throw new Error(
        "local config malformed: bin/session-index.local.json — machineFolds must be an object",
      );
    }
    for (const [from, to] of Object.entries(cfg.machineFolds)) {
      if (
        from.trim() === "" ||
        typeof to !== "string" ||
        to.trim() === "" ||
        /[\r\n]/.test(to)
      ) {
        throw new Error(
          "local config malformed: bin/session-index.local.json — machineFolds entries must map non-empty single-line strings",
        );
      }
    }
  }
  if (
    cfg.failOnEmptyCorpus !== undefined &&
    typeof cfg.failOnEmptyCorpus !== "boolean"
  ) {
    throw new Error(
      "local config malformed: bin/session-index.local.json — failOnEmptyCorpus must be a boolean",
    );
  }
  if (
    cfg.viewTag !== undefined &&
    (typeof cfg.viewTag !== "string" ||
      cfg.viewTag.trim() === "" ||
      /[\r\n]/.test(cfg.viewTag))
  ) {
    throw new Error(
      "local config malformed: bin/session-index.local.json — viewTag must be a non-empty single-line string",
    );
  }
  return cfg;
}

// Kept in lockstep with scripts/recall-report.sh — see header.
const MEANINGFUL_RE = /^## Issues this session[ \t]*$/m;
const RECORD_RE = /^\*\*Recall failure[^\n]*/gm;
const KNOWN_CLASSES = ["not-loaded", "loaded-but-ignored"];

// Minimal frontmatter reads — no YAML dependency. Kept in sync with
// generate-harness-index.js.
function frontmatter(text) {
  const m = text.match(/^﻿?---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);
  return m ? m[1] : null;
}

function fmScalar(fm, key) {
  if (!fm) return null;
  const line = fm.split(/\r?\n/).find((l) => l.startsWith(`${key}:`));
  if (!line) return null;
  const value = line.slice(key.length + 1).trim().replace(/^['"]|['"]$/g, "");
  return value || null;
}

// Fold a harness spelling to its canonical token. Unrecognized values pass
// through lowercased — never guessed into an existing bucket.
function canonHarness(raw) {
  if (!raw) return "—";
  let v = raw.toLowerCase().replace(/\s*\(.*\)\s*$/, "").trim();
  if (v === "claude-code" || v === "claude code") v = "claude";
  return v || "—";
}

// Same conservative fold for machines: drop the mDNS `.local` suffix, then map
// only the spellings positively identified as the same host. Host-specific
// pairs are LOCAL DATA (`machineFolds` in bin/session-index.local.json — see
// LOCAL CONFIG in the header); the shared code ships with none.
function canonMachine(raw) {
  if (!raw) return "—";
  const v = raw.toLowerCase().replace(/\.local$/, "").trim();
  if (!v) return "—";
  // Own-property lookup only: a plain-object fold table inherits
  // Object.prototype, so a machine legitimately named `constructor` or
  // `toString` would otherwise resolve to a native function, not a fold.
  const folds = LOCAL.machineFolds || {};
  return Object.hasOwn(folds, v) ? folds[v] : v;
}

// Read a frontmatter value that may be a same-line scalar OR a YAML block
// sequence. Closeout logs use BOTH forms for `linear:` — `linear: [ABC-482]` on
// one line, and the block form:
//
//     linear:
//       - ABC-514
//
// A same-line-only reader returns null for every block-form log and silently
// drops their issue IDs, which is precisely the kind of quiet under-report this
// index exists to prevent. Returns the raw scalar text plus any block items.
function fmValueWithBlockList(fm, key) {
  if (!fm) return "";
  const lines = fm.split(/\r?\n/);
  const i = lines.findIndex((l) => l.startsWith(`${key}:`));
  if (i === -1) return "";
  let out = lines[i].slice(key.length + 1).trim().replace(/^['"]|['"]$/g, "");
  // Consume following indented `- item` lines; stop at the next top-level key.
  for (let j = i + 1; j < lines.length; j++) {
    const l = lines[j];
    if (/^\s+-\s+/.test(l)) out += ` ${l.replace(/^\s+-\s+/, "").trim()}`;
    else if (/^\s*$/.test(l)) continue;
    else break;
  }
  return out;
}

// Issues come from two places and are unioned: the frontmatter `linear:` list
// (authoritative when present) and tracker tokens in the `## Issues this
// session` H3 headings — the only place a closeout log names issues
// consistently. Scanning the whole body would sweep in every issue merely
// MENTIONED in prose, which is why this is heading-scoped.
function collectIssues(fm, text) {
  const found = new Set();
  const linearRaw = fmValueWithBlockList(fm, "linear");
  if (linearRaw && linearRaw !== "none" && linearRaw !== "[]") {
    for (const m of linearRaw.matchAll(/[A-Z][A-Z0-9]*-\d+/g)) found.add(m[0]);
  }
  const secStart = text.search(MEANINGFUL_RE);
  if (secStart !== -1) {
    const after = text.slice(secStart);
    // Stop at the next H2 so we only read this section's headings.
    const secEnd = after.slice(1).search(/^## /m);
    const section = secEnd === -1 ? after : after.slice(0, secEnd + 1);
    for (const line of section.split(/\r?\n/)) {
      if (!line.startsWith("### ")) continue;
      for (const m of line.matchAll(/[A-Z][A-Z0-9]*-\d+/g)) found.add(m[0]);
    }
  }
  return [...found].sort();
}

// Classify this log's recall-failure records. A log with no record is "—";
// a log with records reports the distinct classes it recorded.
function recallClasses(text) {
  const classes = new Set();
  for (const m of text.matchAll(RECORD_RE)) {
    const line = m[0];
    const hit = KNOWN_CLASSES.find((c) =>
      new RegExp(`class\\s+${c.replace(/-/g, "\\-")}\\b`).test(line),
    );
    classes.add(hit || "unclassified");
  }
  return [...classes].sort();
}

const cell = (s) => (s && s.length ? String(s).replace(/\|/g, "\\|") : "—");

// A wikilink alias keeps its pipe RAW — `[[target\|alias]]` makes the vault's
// link checker read the backslash as part of the target, turning every row into
// a broken link. Same convention as generate-harness-index.js. A pipe inside a
// title would still break the table row, so titles are sanitized to a slash
// rather than escaped.
const alias = (s) => String(s).replace(/\|/g, "/");

// An UNREADABLE corpus is fatal; an EMPTY one is not — by default. A missing
// directory could mean either (a fresh vault that has not created it, or an
// archive that went missing), and the two postures are irreconcilable in one
// default: a fresh vault must treat absence as benign, a vault with months of
// archive must treat it as the archive being GONE. The `failOnEmptyCorpus`
// local-config key picks the posture (see LOCAL CONFIG in the header); without
// it, absence is benign and reported truthfully in the view. What is never
// acceptable is writing a view whose prose implies coverage of logs that were
// never read — see EMPTY STATE in the header. Genuine read errors (a permission
// failure, an unreadable file) throw and exit 2 in both postures.
function collectLogs() {
  const dirAbs = path.join(root, SESSIONS_DIR);
  if (!fs.existsSync(dirAbs)) {
    if (LOCAL.failOnEmptyCorpus) {
      throw new Error(
        `session corpus missing: ${SESSIONS_DIR} — refusing to write an empty index`,
      );
    }
    return [];
  }
  let names;
  try {
    names = fs.readdirSync(dirAbs);
  } catch (err) {
    throw new Error(`session corpus unreadable: ${SESSIONS_DIR} — ${err.message}`);
  }
  const logs = [];
  for (const name of names) {
    if (!name.endsWith(".md")) continue;
    // README is the folder's prose hub, not a session log.
    if (name === "README.md") continue;
    const abs = path.join(dirAbs, name);
    let text;
    try {
      text = fs.readFileSync(abs, "utf8");
    } catch (err) {
      throw new Error(`session log unreadable: ${SESSIONS_DIR}/${name} — ${err.message}`);
    }
    if (text.trim() === "") continue;
    const fm = frontmatter(text);
    // Filenames are YYYY-MM-DD-HHMMSS-<host>-<closeout>.md; the prefix is the
    // fallback when a log predates the `date:` frontmatter convention.
    const fromName = name.match(/^(\d{4}-\d{2}-\d{2})/);
    logs.push({
      file: name,
      rel: `${SESSIONS_DIR}/${name.replace(/\.md$/, "")}`,
      title: fmScalar(fm, "title") || name.replace(/\.md$/, ""),
      date: fmScalar(fm, "date") || (fromName ? fromName[1] : null),
      harness: canonHarness(fmScalar(fm, "harness")),
      machine: canonMachine(fmScalar(fm, "machine")),
      issues: collectIssues(fm, text),
      recall: recallClasses(text),
      meaningful: MEANINGFUL_RE.test(text),
    });
  }
  logs.sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : 0));
  // A present-but-empty corpus is the same call as a missing one under the
  // fail-loud posture: the directory exists, so the check above passes, yet
  // the view would still claim complete coverage of nothing.
  if (logs.length === 0 && LOCAL.failOnEmptyCorpus) {
    throw new Error(
      `session corpus empty: ${SESSIONS_DIR} contains no session logs — refusing to write an empty index`,
    );
  }
  return logs;
}

function tally(logs, pick) {
  const counts = new Map();
  for (const l of logs) {
    for (const v of [].concat(pick(l))) {
      if (!v || v === "—") continue;
      counts.set(v, (counts.get(v) || 0) + 1);
    }
  }
  return [...counts.entries()].sort((a, b) =>
    b[1] - a[1] || (a[0] < b[0] ? -1 : 1),
  );
}

// A function, not a const: the tag line reads the local config, which is only
// loaded inside main()'s error boundary.
const HEADER = () => [
  "---",
  "title: Session Index",
  "tags:",
  "  - generated-index",
  `  - ${LOCAL.viewTag || "memory-vault/retrieval"}`,
  "---",
  "",
  "# Session Index",
  "",
  "GENERATED — do not hand-edit. Regenerate with",
  "`node bin/generate-session-index.js`; the vault audit fails on drift.",
  "Derived from `30-Archive/Sessions/*.md` frontmatter (`title`, `date`,",
  "`harness`, `machine`, `linear`) plus the `## Issues this",
  "session` headings and the `**Recall failure, class …**` records.",
  "",
];

function renderEmpty() {
  return [
    ...HEADER(),
    "This is the archive's **query surface** — once closeout logs exist, filter",
    "it by machine, harness, issue, date, or recall-failure class instead of",
    "grepping the logs.",
    "",
    "## Coverage",
    "",
    "- Session logs: **0**",
    "",
    "No session logs exist yet: `30-Archive/Sessions/` holds no closeout logs, so",
    "there is nothing to index and this view asserts coverage of nothing. It will",
    "populate on its own as closeouts land — regenerate after each one. An empty",
    "index here is the truthful state of a fresh vault, not a failure.",
    "",
  ].join("\n");
}

function renderView(logs) {
  if (logs.length === 0) return renderEmpty();

  const meaningful = logs.filter((l) => l.meaningful);
  const withRecall = logs.filter((l) => l.recall.length);
  const dates = logs.map((l) => l.date).filter(Boolean).sort();
  const span = dates.length ? `${dates[0]} → ${dates[dates.length - 1]}` : "—";

  const lines = [
    ...HEADER(),
    "This is the archive's **query surface** — filter it by machine, harness,",
    "issue, date, or recall-failure class instead of grepping the logs. Harness",
    "and machine values are normalized (for example `claude-code` → `claude`,",
    "and a trailing `.local` is dropped), so a filter over this view does not",
    "silently miss the alternate spellings the raw frontmatter carries. Read the",
    "linked log for detail — the rows are pointers, not the record.",
    "",
    "## Coverage",
    "",
    `- Session logs: **${logs.length}** (${span})`,
    `- Meaningful logs (carry \`## Issues this session\`): **${meaningful.length}**`,
    `- Logs recording a recall failure: **${withRecall.length}**`,
    "",
    "| Dimension | Values |",
    "|---|---|",
    `| Harness | ${tally(logs, (l) => l.harness).map(([k, n]) => `${k} (${n})`).join(", ") || "—"} |`,
    `| Machine | ${tally(logs, (l) => l.machine).map(([k, n]) => `${k} (${n})`).join(", ") || "—"} |`,
    `| Recall class | ${tally(logs, (l) => l.recall).map(([k, n]) => `${k} (${n})`).join(", ") || "none recorded"} |`,
    "",
    "## Sessions",
    "",
    "| Date | Harness | Machine | Issues | Recall | Session |",
    "|---|---|---|---|---|---|",
  ];

  for (const l of logs) {
    lines.push(
      `| ${cell(l.date)} | ${cell(l.harness)} | ${cell(l.machine)} | ${cell(l.issues.join(" "))} | ${cell(l.recall.join(" "))} | [[${l.rel}|${alias(l.title)}]] |`,
    );
  }
  lines.push("");
  return lines.join("\n");
}

function main() {
  const checkMode = process.argv.includes("--check");
  const viewAbs = path.join(root, VIEW_PATH);
  let want;
  try {
    LOCAL = loadLocalConfig();
    want = renderView(collectLogs());
  } catch (err) {
    // Corpus-integrity failures exit 2 — distinct from drift (1) so the audit
    // and a human can tell "the index is stale" from "the archive is gone".
    console.error(`SESSION INDEX: ${err.message}`);
    process.exit(2);
  }
  const have = fs.existsSync(viewAbs) ? fs.readFileSync(viewAbs, "utf8") : null;
  if (have === want) {
    if (checkMode) console.log("session index matches regeneration");
    return;
  }
  if (checkMode) {
    console.error(
      `DRIFT ${VIEW_PATH} — regenerate with node bin/generate-session-index.js`,
    );
    process.exit(1);
  }
  fs.writeFileSync(viewAbs, want);
  console.log(`WROTE ${VIEW_PATH}`);
}

main();
