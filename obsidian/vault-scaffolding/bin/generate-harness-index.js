#!/usr/bin/env node
// generate-harness-index.js — per-harness generated index views.
//
// Contract (core/memory-model.md § Harness-Neutral Note Schema): every vault
// note carries an optional `harness:` frontmatter key naming its audience —
// `all` (default when absent) or one harness name. Each harness orients from
// its own generated view under 90-Indexes/, which lists exactly the notes
// scoped `all` or to that harness. The views are DERIVED, deterministic, and
// never hand-edited: regeneration is the only write path, which both enforces
// the scope filter mechanically (a note scoped to another harness never
// appears in your view) and removes the shared-index write hot-spot.
//
// Usage:
//   node bin/generate-harness-index.js            # (re)write the views
//   node bin/generate-harness-index.js --check    # exit 1 if views drifted
//
// Determinism: notes sort by vault-relative path via plain UTF-16 comparison
// (no locale), and the output carries no timestamps — same tree in, same
// bytes out.

const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const rel = (p) => path.relative(root, p).split(path.sep).join("/");

// Harness views to emit. Union of this baseline and every concrete `harness:`
// value found in note frontmatter, so adding a new harness needs no edit here.
const BASELINE_HARNESSES = ["claude", "codex", "hermes"];

const VIEW_DIR = "90-Indexes";
const VIEW_PREFIX = "Harness Index - ";

// Views index the DURABLE RETRIEVAL tiers only. Evidence tiers (20-Raw,
// 30-Archive — including session logs, whose own `harness:` frontmatter key is
// drain provenance, a separate namespace from this audience scope), templates,
// and the index/view tiers are not orient targets and stay out.
const SKIP_DIRS = new Set([
  ".git", "node_modules", ".venv", "bin",
  ".claude", ".agents", ".codex", ".obsidian",
  "20-Raw", "30-Archive", "80-Templates", "90-Indexes", "95-Views",
]);

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      out.push(...walk(full));
    } else if (entry.name.endsWith(".md")) {
      out.push(full);
    }
  }
  return out;
}

function isGeneratedView(relPath) {
  return relPath.startsWith(`${VIEW_DIR}/${VIEW_PREFIX}`);
}

// Minimal frontmatter scalar read — no YAML dependency. Returns the trimmed
// value of `key:` inside the leading frontmatter block, or null.
function frontmatterScalar(text, key) {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);
  if (!m) return null;
  const line = m[1]
    .split(/\r?\n/)
    .find((l) => l.startsWith(`${key}:`));
  if (!line) return null;
  const value = line.slice(key.length + 1).trim().replace(/^['"]|['"]$/g, "");
  return value || null;
}

function collectNotes() {
  const notes = [];
  for (const f of walk(root)) {
    const r = rel(f);
    if (isGeneratedView(r)) continue;
    const text = fs.readFileSync(f, "utf8");
    const harness = (frontmatterScalar(text, "harness") || "all").toLowerCase();
    notes.push({ rel: r, harness });
  }
  notes.sort((a, b) => (a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0));
  return notes;
}

function renderView(harness, notes) {
  const visible = notes.filter(
    (n) => n.harness === "all" || n.harness === harness,
  );
  const lines = [
    "---",
    `title: Harness Index - ${harness}`,
    "tags:",
    "  - generated-index",
    "---",
    "",
    `# Harness Index - ${harness}`,
    "",
    "GENERATED — do not hand-edit. Regenerate with",
    "`node bin/generate-harness-index.js`; the vault audit fails on drift.",
    `Lists every note scoped \`harness: all\` or \`harness: ${harness}\`.`,
    "",
  ];
  for (const n of visible) {
    const scopeTag = n.harness === "all" ? "" : ` (harness: ${n.harness})`;
    lines.push(`- [[${n.rel.replace(/\.md$/, "")}]]${scopeTag}`);
  }
  lines.push("");
  return lines.join("\n");
}

function main() {
  const checkMode = process.argv.includes("--check");
  const notes = collectNotes();

  const harnesses = [...new Set([
    ...BASELINE_HARNESSES,
    ...notes.map((n) => n.harness).filter((h) => h !== "all"),
  ])].sort();

  const viewDirAbs = path.join(root, VIEW_DIR);
  fs.mkdirSync(viewDirAbs, { recursive: true });

  let drifted = 0;
  for (const h of harnesses) {
    const viewPath = path.join(viewDirAbs, `${VIEW_PREFIX}${h}.md`);
    const want = renderView(h, notes);
    const have = fs.existsSync(viewPath)
      ? fs.readFileSync(viewPath, "utf8")
      : null;
    if (have === want) continue;
    if (checkMode) {
      drifted += 1;
      console.error(
        `DRIFT ${rel(viewPath)} — regenerate with node bin/generate-harness-index.js`,
      );
    } else {
      fs.writeFileSync(viewPath, want);
      console.log(`WROTE ${rel(viewPath)}`);
    }
  }

  // A stray view for a harness that no longer exists is also drift.
  for (const f of fs.readdirSync(viewDirAbs)) {
    if (!f.startsWith(VIEW_PREFIX) || !f.endsWith(".md")) continue;
    const h = f.slice(VIEW_PREFIX.length, -3);
    if (harnesses.includes(h)) continue;
    if (checkMode) {
      drifted += 1;
      console.error(`DRIFT stray view for unknown harness: ${VIEW_DIR}/${f}`);
    } else {
      fs.rmSync(path.join(viewDirAbs, f));
      console.log(`REMOVED ${VIEW_DIR}/${f}`);
    }
  }

  if (checkMode) {
    if (drifted) process.exit(1);
    console.log("harness index views match regeneration");
  }
}

main();
