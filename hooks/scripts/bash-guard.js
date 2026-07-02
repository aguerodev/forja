// bash-guard.js - PreToolUse(Bash) guard logic for the forja plugin.
//
// Reads the hook payload JSON on stdin and enforces, ONLY inside forja
// projects (repo root contains .forja.json):
//   1. No raw `hcloud` CLI for the agent (the hcloud-agent.sh wrapper is the
//      single choke-point). Detected per COMMAND SEGMENT and only when hcloud
//      is the executed program - `command -v hcloud` or mentions in strings
//      never trigger it, and a chained `wrapper || hcloud ...` is still caught.
//   2. No `git push` that lands on main/develop (explicit refspec, ref
//      deletion, HEAD, or a bare push from a protected branch). Exception:
//      first publication - the remote is known but has no such branch yet
//      (bootstrap `git push -u origin develop|main` from /forja:init).
//   3. No `git commit` while standing on main/develop (empty repo exempted).
//   4. No AI attribution in commit commands.
//
// Contract: deny -> single-line permissionDecision JSON on stdout, exit 0.
// Allow -> no output, exit 0. Fail-open by design: any internal error must
// never block work.
"use strict";

const { execFileSync } = require("node:child_process");
const { existsSync } = require("node:fs");
const { join } = require("node:path");

const PROTECTED = new Set(["main", "develop"]);
const ATTRIBUTION = /Co-[Aa]uthored-[Bb]y|Generated with|🤖/;
// git push flags whose value is a SEPARATE argument (never a refspec).
const PUSH_VALUE_FLAGS = new Set(["-o", "--push-option", "--repo", "--receive-pack", "--exec"]);
// git global flags whose value is a separate argument.
const GIT_VALUE_FLAGS = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"]);
// Prefix programs that execute their argument as a command.
const EXEC_PREFIXES = new Set(["sudo", "doas", "env", "exec", "nohup", "time"]);
const SUDO_VALUE_FLAGS = new Set(["-u", "-g", "-p", "-h", "--user", "--group"]);

function git(root, args) {
  try {
    return execFileSync("git", ["-C", root, ...args], {
      stdio: ["ignore", "pipe", "ignore"],
      encoding: "utf8",
      timeout: 3000,
    }).trim();
  } catch {
    return null;
  }
}

// Split a shell command into top-level segments at ; & | ( ) and newlines,
// respecting single/double quotes and backslash escapes.
function splitSegments(cmd) {
  const segments = [];
  let cur = "";
  let quote = null;
  for (let i = 0; i < cmd.length; i++) {
    const ch = cmd[i];
    if (quote) {
      cur += ch;
      if (ch === quote && cmd[i - 1] !== "\\") quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      cur += ch;
      continue;
    }
    if (ch === "\\") {
      cur += ch + (cmd[i + 1] ?? "");
      i++;
      continue;
    }
    if (ch === ";" || ch === "&" || ch === "|" || ch === "\n" || ch === "(" || ch === ")") {
      if (cur.trim()) segments.push(cur.trim());
      cur = "";
      continue;
    }
    cur += ch;
  }
  if (cur.trim()) segments.push(cur.trim());
  return segments;
}

// Tokenize one segment (whitespace-separated, quotes respected and stripped).
function tokenize(segment) {
  const tokens = [];
  let cur = "";
  let quote = null;
  let started = false;
  for (let i = 0; i < segment.length; i++) {
    const ch = segment[i];
    if (quote) {
      if (ch === quote) quote = null;
      else cur += ch;
      started = true;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      started = true;
      continue;
    }
    if (ch === "\\") {
      cur += segment[i + 1] ?? "";
      i++;
      started = true;
      continue;
    }
    if (ch === " " || ch === "\t") {
      if (started) tokens.push(cur);
      cur = "";
      started = false;
      continue;
    }
    cur += ch;
    started = true;
  }
  if (started) tokens.push(cur);
  return tokens;
}

// Drop leading VAR=VAL assignments and executor prefixes (sudo/env/exec/...).
function effectiveCommand(tokens) {
  let i = 0;
  for (;;) {
    while (i < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) i++;
    if (i >= tokens.length) return [];
    const base = tokens[i].replace(/^.*\//, "");
    if (!EXEC_PREFIXES.has(base)) return tokens.slice(i);
    i++; // skip the prefix program
    // skip the prefix's own flags (and detached values for sudo-style flags)
    while (i < tokens.length && tokens[i].startsWith("-")) {
      if (SUDO_VALUE_FLAGS.has(tokens[i])) i++;
      i++;
    }
  }
}

function deny(reason) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason,
      },
    }) + "\n"
  );
  process.exit(0);
}

function wrapperPath() {
  const root = process.env.CLAUDE_PLUGIN_ROOT;
  return root ? join(root, "bin", "hcloud-agent.sh") : "bin/hcloud-agent.sh (dentro del plugin forja; /forja:doctor muestra la ruta exacta)";
}

// Resolve the destination branch names a `git push` segment would touch.
function pushTargets(args, currentBranch) {
  const positionals = [];
  let sawDashDash = false;
  for (let i = 0; i < args.length; i++) {
    const t = args[i];
    if (!sawDashDash && t === "--") {
      sawDashDash = true;
      continue;
    }
    if (!sawDashDash && t.startsWith("-")) {
      if (PUSH_VALUE_FLAGS.has(t)) i++; // detached flag value, never a refspec
      continue;
    }
    positionals.push(t);
  }
  const remote = positionals.length > 0 ? positionals[0] : "origin";
  const refspecs = positionals.slice(1);
  const targets = [];
  if (refspecs.length === 0) {
    // bare push publishes the current branch
    if (currentBranch) targets.push(currentBranch);
  } else {
    for (const spec of refspecs) {
      let dst = spec.replace(/^\+/, "");
      if (dst.includes(":")) dst = dst.split(":").pop();
      if (dst === "HEAD" || dst === "@") dst = currentBranch ?? dst;
      const short = dst.replace(/^refs\/heads\//, "");
      targets.push(short);
    }
  }
  return { remote, targets };
}

function main() {
  let payload = "";
  try {
    payload = require("node:fs").readFileSync(0, "utf8");
  } catch {
    return;
  }
  if (!payload.trim()) return;

  let cmd = "";
  let cwd = process.cwd();
  try {
    const data = JSON.parse(payload);
    cmd = typeof data?.tool_input?.command === "string" ? data.tool_input.command : "";
    if (typeof data?.cwd === "string" && data.cwd) cwd = data.cwd;
  } catch {
    return;
  }
  if (!cmd) return;

  const root = git(cwd, ["rev-parse", "--show-toplevel"]) ?? cwd;

  // Scope gate: every rule applies only inside forja projects.
  if (!existsSync(join(root, ".forja.json"))) return;

  const branch = git(root, ["symbolic-ref", "--short", "HEAD"]);
  const emptyRepo = git(root, ["rev-parse", "--verify", "--quiet", "HEAD"]) === null;
  let remoteList = null; // lazy

  for (const segment of splitSegments(cmd)) {
    const tokens = effectiveCommand(tokenize(segment));
    if (tokens.length === 0) continue;
    const cmd0 = tokens[0].replace(/^.*\//, "");

    // ── Rule 1: raw hcloud is forbidden (wrapper only) ──────────────────────
    if (cmd0 === "hcloud") {
      deny(
        `Doctrina forja: la CLI cruda de Hetzner está prohibida para el agente — usá el wrapper con allowlist y auditoría: ${wrapperPath()}. Doctrina: receta operar-servidor.`
      );
    }

    if (cmd0 !== "git") continue;

    // Skip git global flags to find the subcommand.
    let i = 1;
    while (i < tokens.length) {
      const t = tokens[i];
      if (!t.startsWith("-")) break;
      if (GIT_VALUE_FLAGS.has(t)) i++;
      i++;
    }
    const sub = tokens[i];
    const args = tokens.slice(i + 1);

    // ── Rule 4: no AI attribution in commit commands ────────────────────────
    if (sub === "commit" && ATTRIBUTION.test(segment)) {
      deny(
        "Regla de commits forja: sin atribución de IA en los mensajes (Conventional Commits en inglés, un commit = una unidad de trabajo). Reintentá sin el trailer."
      );
    }

    // ── Rule 3: no commit while standing on main/develop ────────────────────
    if (sub === "commit" && branch && PROTECTED.has(branch) && !emptyRepo) {
      deny(
        "Gitflow forja: no se commitea directo en main/develop — cortá feature/<nombre> desde develop."
      );
    }

    // ── Rule 2: no push that lands on main/develop ──────────────────────────
    if (sub === "push") {
      const { remote, targets } = pushTargets(args, branch);
      const hit = targets.find((t) => PROTECTED.has(t));
      if (hit) {
        // Bootstrap exception: pushing a protected branch that does not exist
        // yet on a KNOWN remote is the first publication (/forja:init).
        if (remoteList === null) {
          const out = git(root, ["remote"]);
          remoteList = out ? out.split("\n").filter(Boolean) : [];
        }
        const knownRemote = remoteList.includes(remote);
        const remoteRefExists =
          knownRemote &&
          git(root, ["rev-parse", "--verify", "--quiet", `refs/remotes/${remote}/${hit}`]) !== null;
        if (!knownRemote || remoteRefExists) {
          deny(
            "Gitflow forja: main y develop solo reciben cambios por Pull Request (regla flujo-git). Cortá una feature/<nombre> desde develop."
          );
        }
        // else: first publication of main/develop -> allow (bootstrap).
      }
    }
  }
}

try {
  main();
} catch {
  // Fail open: a guard bug must never block work.
}
