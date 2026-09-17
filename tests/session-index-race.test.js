#!/usr/bin/env node
// Copied-vault regression for the session-index writer protocol.
const assert = require("assert");
const child = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const source = process.argv[2];
if (!source || !path.isAbsolute(source)) throw new Error("expected absolute generator path");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "session-index-race-"));
const vault = path.join(root, "vault");
const sessions = path.join(vault, "30-Archive", "Sessions");
const indexes = path.join(vault, "90-Indexes");
const bin = path.join(vault, "bin");
const view = path.join(indexes, "Session Index.md");
const barrier = path.join(root, "barrier");
let owner = null;
const forceOwnerKill = process.env.SESSION_INDEX_RACE_FORCE_OWNER_KILL === "1";

function pass(label) { console.log(`PASS ${label}`); }
function same(label, want, got) { assert.strictEqual(got, want, label); pass(label); }
function receipt(dir, name) {
  fs.writeFileSync(path.join(dir, `${name}.md`), [
    "---", `title: Fixture receipt ${name.slice(-1).toUpperCase()}`, "date: 2026-01-02", "harness: codex",
    "machine: fixture", "linear: ABC-123", "---", "", "## Issues this session",
    "", "### ABC-123", "",
  ].join("\n"));
}
function run(script, args = [], rootOverride = vault) {
  return child.spawnSync(process.execPath, [script, ...args], {
    env: { ...process.env, VAULT_AUDIT_ROOT: rootOverride }, encoding: "utf8", timeout: 15000,
  });
}
function count(name) { return fs.readFileSync(view, "utf8").split(name).length - 1; }
function waitFor(file) {
  const deadline = Date.now() + 15000;
  while (!fs.existsSync(file)) {
    if (Date.now() > deadline) throw new Error(`timeout waiting for ${file}`);
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
  }
}

async function waitForOwnerClose() {
  // A signal-exited child has no numeric exitCode. Its close event may already
  // have fired before cleanup starts, but it is no longer running or holding
  // the copied-vault root open.
  if (!owner || owner.exitCode !== null || owner.signalCode !== null) return owner?.exitCode ?? null;
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(killTimer);
      resolve(owner.exitCode);
    };
    const killTimer = setTimeout(() => {
      if (owner.exitCode === null && owner.signalCode === null) owner.kill("SIGKILL");
      setTimeout(() => {
        if (!settled && (owner.exitCode !== null || owner.signalCode !== null)) finish();
        else if (!settled) reject(new Error("owner did not exit after cleanup timeout"));
      }, 1000);
    }, 15000);
    owner.once("close", finish);
    owner.once("error", finish);
  });
}

async function releaseAndReapOwner() {
  if (!owner || owner.exitCode !== null || owner.signalCode !== null) return;
  try { fs.writeFileSync(path.join(barrier, "release"), ""); } catch {}
  await waitForOwnerClose();
}

function runForcedOwnerKillProbe() {
  const probeRoot = fs.mkdtempSync(path.join(os.tmpdir(), "session-index-kill-probe-"));
  try {
    const forced = child.spawnSync(process.execPath, [__filename, source], {
      env: {
        ...process.env,
        TMPDIR: probeRoot,
        TEMP: probeRoot,
        TMP: probeRoot,
        SESSION_INDEX_RACE_FORCE_OWNER_KILL: "1",
      },
      encoding: "utf8", timeout: 30000,
    });
    same("forced owner kill reaches failure cleanup", 1, forced.status);
    same("forced owner kill leaves no fixture root", 0, fs.readdirSync(probeRoot).length);
  } finally {
    fs.rmSync(probeRoot, { recursive: true, force: true });
  }
}

async function main() {
  try {
    fs.mkdirSync(sessions, { recursive: true });
    fs.mkdirSync(indexes, { recursive: true });
    fs.mkdirSync(bin, { recursive: true });
    fs.mkdirSync(barrier, { recursive: true });
    const generator = path.join(bin, "generate-session-index.js");
    fs.copyFileSync(source, generator);
    receipt(sessions, "2026-01-02-000000-a");
    same("initial writer exits 0", 0, run(generator).status);
    if (process.platform !== "win32") fs.chmodSync(view, 0o640);

    const anchor = '  const have = fs.existsSync(viewAbs) ? fs.readFileSync(viewAbs, "utf8") : null;';
    const original = fs.readFileSync(generator, "utf8");
    same("barrier anchor is unique", 1, original.split(anchor).length - 1);
    const aScript = path.join(root, "a-generator.js");
    const pause = [
      '  if (process.env.SESSION_INDEX_RACE_PAUSE === "1") {',
      '    fs.writeFileSync(path.join(process.env.SESSION_INDEX_RACE_BARRIER, "ready"), String(process.pid));',
      '    const deadline = Date.now() + 15000;',
      '    while (!fs.existsSync(path.join(process.env.SESSION_INDEX_RACE_BARRIER, "release"))) {',
      '      if (Date.now() > deadline) throw new Error("session-index race barrier timed out");',
      '      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);',
      '    }',
      '  }', anchor,
    ].join("\n");
    fs.writeFileSync(aScript, original.replace(anchor, pause));
    owner = child.spawn(process.execPath, [aScript], {
      env: { ...process.env, VAULT_AUDIT_ROOT: vault, SESSION_INDEX_RACE_PAUSE: "1", SESSION_INDEX_RACE_BARRIER: barrier },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let ownerErr = "";
    owner.stderr.on("data", (chunk) => { ownerErr += chunk; });
    waitFor(path.join(barrier, "ready"));
    receipt(sessions, "2026-01-02-000100-b");

    const beforeCheck = fs.readFileSync(view);
    same("--check observes drift without writing", 1, run(generator, ["--check"]).status);
    same("--check leaves view bytes unchanged", true, Buffer.compare(beforeCheck, fs.readFileSync(view)) === 0);
    same("--check leaves owner lock intact", true, fs.existsSync(path.join(indexes, ".session-index.lock")));
    const contender = run(generator);
    same("concurrent writer refuses active owner", 1, contender.status);
    assert.match(contender.stderr, /another session index generator owns/);
    pass("concurrent writer names ownership contention");
    same("raw B receipt survives contention", true, fs.existsSync(path.join(sessions, "2026-01-02-000100-b.md")));

    if (forceOwnerKill) {
      owner.kill("SIGKILL");
      await waitForOwnerClose();
      throw new Error("forced owner kill cleanup probe");
    }
    fs.writeFileSync(path.join(indexes, ".session-index.lock"), "replacement owner\n");
    fs.writeFileSync(path.join(barrier, "release"), "");
    const ownerCode = await waitForOwnerClose();
    same("owner exits after release", 0, ownerCode);
    assert.match(ownerErr, /owner token changed/);
    pass("owner leaves replacement token intact");
    same("replacement lock remains", "replacement owner\n", fs.readFileSync(path.join(indexes, ".session-index.lock"), "utf8"));
    same("owner reconciles B before publishing", 1, count("000100-b"));
    fs.unlinkSync(path.join(indexes, ".session-index.lock"));
    same("later writer succeeds after release", 0, run(generator).status);
    same("final view contains B once", 1, count("000100-b"));
    const stable = fs.readFileSync(view);
    same("repeat generation is byte-stable", 0, run(generator).status);
    same("repeat keeps B once", 1, count("000100-b"));
    same("repeat bytes match", true, Buffer.compare(stable, fs.readFileSync(view)) === 0);
    if (process.platform !== "win32") same("atomic replace preserves view mode", 0o640, fs.statSync(view).mode & 0o777);

    const failureVault = path.join(root, "failure-vault");
    const failureSessions = path.join(failureVault, "30-Archive", "Sessions");
    const failureIndexes = path.join(failureVault, "90-Indexes");
    const failureBin = path.join(failureVault, "bin");
    fs.mkdirSync(failureSessions, { recursive: true });
    fs.mkdirSync(failureIndexes, { recursive: true });
    fs.mkdirSync(failureBin, { recursive: true });
    receipt(failureSessions, "2026-01-02-000200-failure");
    const prior = Buffer.from("prior bytes\n");
    const failureView = path.join(failureIndexes, "Session Index.md");
    fs.writeFileSync(failureView, prior);
    const rename = "    fs.renameSync(temp, viewAbs);";
    same("rename anchor is unique", 1, original.split(rename).length - 1);
    const failureScript = path.join(failureBin, "generate-session-index.js");
    fs.writeFileSync(failureScript, original.replace(rename, '    throw new Error("forced rename failure");'));
    same("forced rename exits 2", 2, run(failureScript, [], failureVault).status);
    same("failed rename preserves prior view", true, Buffer.compare(prior, fs.readFileSync(failureView)) === 0);
    same("failed rename releases lock", false, fs.existsSync(path.join(failureIndexes, ".session-index.lock")));
    same("failed rename leaves no temp", false, fs.readdirSync(failureIndexes).some((n) => n.includes(".session-index.")));
    runForcedOwnerKillProbe();
  } catch (err) {
    console.error(err.stack || err);
    process.exitCode = 1;
  } finally {
    await releaseAndReapOwner();
    fs.rmSync(root, { recursive: true, force: true });
  }
}

main();
