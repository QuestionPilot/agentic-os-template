#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const root = path.resolve(__dirname, "..");
const rel = (p) => path.relative(root, p).split(path.sep).join("/");
const exists = (p) => fs.existsSync(path.join(root, p));

const errors = [];
const warnings = [];
const passes = [];

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    const r = rel(full);
    if (entry.isDirectory()) {
      if ([".git", "node_modules", ".venv"].includes(entry.name)) continue;
      out.push(...walk(full));
    } else {
      out.push(full);
    }
  }
  return out;
}

function pass(msg) { passes.push(msg); }
function warn(msg) { warnings.push(msg); }
function fail(msg) { errors.push(msg); }

const files = walk(root);
const mdFiles = files.filter((f) => f.endsWith(".md"));
const baseFiles = files.filter((f) => f.endsWith(".base"));

function checkRequired() {
  [
    "START.md",
    "README.md",
    "00-System/Memory Core.md",
    "00-System/Source of Truth.md",
    "00-System/Fresh Start Policy.md",
    "00-System/Data Readiness.md",
    "00-System/Goal Run Standard.md",
    "00-System/Dream Review.md",
    "00-System/Linear Handshake.md",
    "00-System/Health Check.md",
    "10-Wiki/index.md",
    "10-Wiki/log.md",
    "20-Raw/sources.md",
    "40-Observability/dream-reviews.md",
    "40-Observability/data-readiness.md",
    "50-Outputs/Data Maps/README.md",
    "50-Outputs/Prepared Outputs/README.md",
    "80-Templates/data-readiness-map.md",
    "80-Templates/goal-run.md",
    "90-Indexes/Vault Map.md",
  ].forEach((f) => exists(f) ? pass(`file exists: ${f}`) : fail(`missing required file: ${f}`));
}

function checkNoiseAndSecrets() {
  // .DS_Store is regenerated continuously by macOS / Finder / Google Drive, so
  // gating on it makes the audit nondeterministic. Surface it as a WARN —
  // flagged for cleanup, never a blocker — keeping the audit read-only. A
  // scaffold copied onto a cloud-synced drive would otherwise fail this audit
  // unpredictably as the OS sprays .DS_Store files back in.
  files
    .filter((f) => path.basename(f) === ".DS_Store")
    .forEach((f) => warn(`OS noise — delete when convenient, not gated: ${rel(f)}`));

  // Genuine disposable cruft below stays a hard FAIL.
  const noisy = files.filter((f) => {
    const name = path.basename(f);
    return name === "trace.zip" || name.endsWith(".har") || name.endsWith(".tmp") || name.endsWith(".log");
  });
  noisy.length ? noisy.forEach((f) => fail(`noisy artifact: ${rel(f)}`)) : pass("no noisy artifacts");

  // Vault-content secret scan. The vault is durable, cloud-synced, and read
  // by every harness, so a leaked credential here outlives any one machine.
  // Covers key-prefix shapes (OpenAI/Anthropic sk-, GitHub ghp_/github_pat_,
  // GitLab glpat-, npm npm_, AWS AKIA, Slack xox*), PEM private-key blocks,
  // and assignments to well-known secret env names.
  const secretPattern = /(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(?:PINECONE_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|SUPABASE_SERVICE_ROLE_KEY|STRIPE_SECRET_KEY|OPENROUTER_API_KEY|NOUS_API_KEY|LINEAR_API_TOKEN)\s*[:=]\s*\S+)/;
  let hits = 0;
  for (const f of mdFiles) {
    const text = fs.readFileSync(f, "utf8");
    if (secretPattern.test(text)) {
      hits += 1;
      fail(`likely secret pattern in ${rel(f)}`);
    }
  }
  if (!hits) pass("secret pattern scan clean");
}

function checkAgnostic() {
  // Vault knowledge must stay machine/user-agnostic. Mirrors the framework's
  // check-drift machine-path guard: machine-specific absolute paths do not
  // belong in durable, cloud-synced notes that every harness reads.
  const machinePath = /\/Users\/|\/home\/|[A-Za-z]:\\/;
  const offenders = [];
  for (const f of [...mdFiles, ...baseFiles]) {
    const lines = fs.readFileSync(f, "utf8").split(/\r?\n/);
    lines.forEach((line, i) => {
      if (machinePath.test(line)) offenders.push(`${rel(f)}:${i + 1}`);
    });
  }
  offenders.length
    ? offenders.forEach((o) => fail(`machine-specific absolute path (keep vault agnostic): ${o}`))
    : pass("no machine-specific absolute paths");
}

function checkWikilinks() {
  const targets = new Set();
  for (const f of [...mdFiles, ...baseFiles]) {
    const r = rel(f);
    targets.add(r);
    targets.add(r.replace(/\.(md|base)$/, ""));
  }
  const broken = [];
  const re = /!?\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]/g;
  for (const f of mdFiles) {
    const text = fs.readFileSync(f, "utf8");
    let m;
    while ((m = re.exec(text))) {
      const t = m[1].trim();
      if (!targets.has(t) && !targets.has(`${t}.md`) && !targets.has(`${t}.base`)) {
        broken.push(`${rel(f)} -> ${t}`);
      }
    }
  }
  broken.length ? broken.forEach((b) => fail(`broken wikilink: ${b}`)) : pass("wikilinks resolve");
}

function checkOrphans() {
  // Orphan = a note with ZERO inbound wikilinks (nothing points to it), which
  // makes it effectively unreachable. Detection is the inverse of checkWikilinks:
  // build the set of every wikilink TARGET used across the vault, then flag any
  // note none of whose names (full path, path-sans-ext, or basename) is targeted
  // by some OTHER note. WARN-only — some pages are legitimately unlinked entry
  // points (indexes, templates, roots like START/README), so an allowlist skips
  // those and orphans never FAIL the audit.
  const re = /!?\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]/g;
  const refSources = new Map(); // wikilink target -> set of files that reference it
  for (const f of mdFiles) {
    const src = rel(f);
    // Generated harness index views mechanically link every indexed note, which
    // would mask genuine orphans — only human-woven links count.
    if (src.startsWith("90-Indexes/Harness Index - ")) continue;
    const text = fs.readFileSync(f, "utf8");
    let m;
    while ((m = re.exec(text))) {
      const t = m[1].trim();
      if (!refSources.has(t)) refSources.set(t, new Set());
      refSources.get(t).add(src);
    }
  }
  // Hub / root / scaffold pages that are legitimately unlinked: indexes,
  // templates, and entry points (START/README + the harness AGENTS/CLAUDE roots).
  const hubBasename = /^(_index|_template|index|README|START|AGENTS|CLAUDE|log|hot|sources)$/i;
  // Deliverable / scaffold trees filed by path, not woven into the wiki graph —
  // templates, indexes, the Outputs tree (dated briefings, run-logs), and the
  // Sessions archive (append-only per-session closeout logs are leaf nodes by
  // design — nothing links TO them) — which would otherwise emit unbounded
  // orphan noise, one WARN per artifact.
  const hubPrefix = /^(80-Templates\/|90-Indexes\/|50-Outputs\/|30-Archive\/Sessions\/)/;
  const orphans = [];
  for (const f of mdFiles) {
    const r = rel(f);
    const base = path.basename(f).replace(/\.md$/, "");
    if (hubBasename.test(base) || hubPrefix.test(r)) continue;
    const keys = [r, r.replace(/\.md$/, ""), base];
    const linkedByOther = keys.some((k) => {
      const s = refSources.get(k);
      return s && [...s].some((src) => src !== r);
    });
    if (!linkedByOther) orphans.push(r);
  }
  orphans.length
    ? orphans.forEach((o) => warn(`orphan page — no inbound wikilinks (link it from a hub or index): ${o}`))
    : pass("no orphan pages");
}

function checkYamlWithRuby() {
  const script = `
require 'yaml'
require 'date'
root = ARGV[0]
Dir.glob(File.join(root, '**/*.md')).each do |f|
  text = File.read(f, encoding: 'utf-8')
  if text.start_with?("---\\n")
    match = text.match(/\\A---\\s*\\n(.*?)\\n---\\s*\\n/m)
    raise "frontmatter closing delimiter missing in #{f}" unless match
    YAML.safe_load(match[1], permitted_classes: [Date, Time, Symbol], aliases: true)
  end
end
Dir.glob(File.join(root, '95-Views/*.base')).each { |f| YAML.load_file(f) }
`;
  const res = spawnSync("ruby", ["-e", script, root], { encoding: "utf8" });
  if (res.status === 0) pass("frontmatter and .base YAML parse");
  else fail(`YAML parse failed: ${(res.stderr || res.stdout).trim()}`);
}

function checkRawManifest() {
  const manifestPath = path.join(root, "20-Raw/sources.md");
  const manifest = fs.existsSync(manifestPath) ? fs.readFileSync(manifestPath, "utf8") : "";
  const inbox = path.join(root, "20-Raw/Inbox");
  if (!fs.existsSync(inbox)) return;
  const inboxFiles = walk(inbox).filter((f) => fs.statSync(f).isFile() && path.basename(f) !== ".gitkeep");
  const missing = inboxFiles.filter((f) => !manifest.includes(path.basename(f)));
  missing.length ? missing.forEach((f) => warn(`raw inbox file missing manifest row: ${rel(f)}`)) : pass("raw inbox manifest coverage ok");
}

function checkWikiSourceRefs() {
  const wikiRoot = path.join(root, "10-Wiki");
  const skip = new Set(["README.md", "index.md", "log.md", "hot.md"]);
  const noteFiles = mdFiles.filter((f) => f.startsWith(wikiRoot) && !skip.has(path.basename(f)));
  const missing = [];
  for (const f of noteFiles) {
    if (path.basename(f) === "README.md") continue;
    const text = fs.readFileSync(f, "utf8");
    if (!/(## Source|## Sources|Source Evidence|Raw source|20-Raw\/sources|\[\[20-Raw\/sources\]\])/i.test(text)) {
      missing.push(rel(f));
    }
  }
  missing.length ? missing.forEach((f) => warn(`wiki note may lack source reference: ${f}`)) : pass("wiki source references ok");
}

function checkIndexes() {
  const decisionIndex = exists("03-Decisions/_index.md") ? fs.readFileSync(path.join(root, "03-Decisions/_index.md"), "utf8") : "";
  const lessonIndex = exists("04-Lessons/_index.md") ? fs.readFileSync(path.join(root, "04-Lessons/_index.md"), "utf8") : "";
  for (const f of mdFiles.filter((f) => rel(f).startsWith("03-Decisions/"))) {
    const b = path.basename(f, ".md");
    if (!["_index", "_template"].includes(b) && !decisionIndex.includes(b)) warn(`decision not indexed: ${rel(f)}`);
  }
  for (const f of mdFiles.filter((f) => rel(f).startsWith("04-Lessons/"))) {
    const b = path.basename(f, ".md");
    if (!["_index", "_template"].includes(b) && !lessonIndex.includes(b)) warn(`lesson not indexed: ${rel(f)}`);
  }
  pass("decision and lesson index check complete");
}

function checkActiveTaskMarkers() {
  const allowed = /^(80-Templates\/|00-System\/|90-Indexes\/|START\.md|README\.md)/;
  for (const f of mdFiles) {
    const r = rel(f);
    if (allowed.test(r)) continue;
    const text = fs.readFileSync(f, "utf8");
    if (/- \[ \]|TODO\b|TBD\b/i.test(text)) warn(`active-task marker outside Linear boundary: ${r}`);
  }
  pass("active-task marker scan complete");
}

function checkHarnessIndexViews() {
  // The per-harness index views under 90-Indexes/ are GENERATED from note
  // frontmatter (core/memory-model.md § Harness-Neutral Note Schema). They are
  // the mechanical scope-filter surface, so hand edits or staleness silently
  // break the filter. Re-derive and fail on drift.
  const generator = path.join(__dirname, "generate-harness-index.js");
  if (!fs.existsSync(generator)) {
    fail("harness index generator missing: bin/generate-harness-index.js");
    return;
  }
  const res = spawnSync("node", [generator, "--check"], { encoding: "utf8" });
  if (res.status === 0) {
    pass("harness index views match regeneration");
  } else {
    (res.stderr || res.stdout)
      .trim()
      .split("\n")
      .filter(Boolean)
      .forEach((line) => fail(`harness index drift: ${line}`));
  }
}

checkRequired();
checkNoiseAndSecrets();
checkAgnostic();
checkWikilinks();
checkOrphans();
checkYamlWithRuby();
checkRawManifest();
checkWikiSourceRefs();
checkIndexes();
checkActiveTaskMarkers();
checkHarnessIndexViews();

for (const p of passes) console.log(`PASS ${p}`);
for (const w of warnings) console.log(`WARN ${w}`);
for (const e of errors) console.log(`FAIL ${e}`);
console.log(`\nSummary: ${passes.length} pass, ${warnings.length} warn, ${errors.length} fail`);
process.exit(errors.length ? 1 : 0);
