#!/usr/bin/env node
// Expand/contract SQL migration linter (doctrine: wiki arquitectura/07).
//
// `drizzle-kit generate` diffs by schema SHAPE: a rename is indistinguishable
// from drop+create, so destructive SQL ships silently. This linter parses the
// generated SQL and fails the build on two statement classes, each with its
// own explicit override:
//
// - DESTRUCTIVE (data loss): DROP TABLE, DROP COLUMN, TRUNCATE, RENAME,
//   DELETE FROM without WHERE
//     -> requires `-- migration:allow-destructive <reason>` on the line above.
// - NON-EXPAND (breaks old code mid-rolling-deploy or takes blocking locks):
//   SET NOT NULL, ALTER COLUMN ... TYPE, ADD COLUMN ... NOT NULL without
//   DEFAULT, CREATE UNIQUE INDEX without CONCURRENTLY
//     -> requires `-- migration:allow-non-expand <reason>` on the line above.
//
// The operation is not forbidden — sometimes it is the right contract step —
// it is BLOCKED BY DEFAULT and demands a named reason next to it, same spirit
// as a justified @ts-expect-error. Zero dependencies; Node >= 20.
//
// Honest limits: statements are split on trailing `;`, so a `;` inside a
// dollar-quoted function body may split early. drizzle-kit output never emits
// those; hand-written migrations that do should keep one statement per line.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import process from "node:process";

const OVERRIDE_RE = /^\s*--\s*migration:allow-(destructive|non-expand)\b(.*)$/;

const RULES = [
  {
    kind: "destructive",
    label: "DROP TABLE",
    test: (sql) => /\bDROP\s+TABLE\b/.test(sql),
  },
  {
    kind: "destructive",
    label: "DROP COLUMN",
    test: (sql) => /\bDROP\s+COLUMN\b/.test(sql),
  },
  {
    kind: "destructive",
    label: "TRUNCATE",
    test: (sql) => /\bTRUNCATE\b/.test(sql),
  },
  {
    kind: "destructive",
    label: "RENAME",
    test: (sql) => /\bRENAME\b/.test(sql),
  },
  {
    kind: "destructive",
    label: "DELETE FROM without WHERE",
    test: (sql) => /\bDELETE\s+FROM\b/.test(sql) && !/\bWHERE\b/.test(sql),
  },
  {
    kind: "non-expand",
    label: "SET NOT NULL",
    test: (sql) => /\bSET\s+NOT\s+NULL\b/.test(sql),
  },
  {
    kind: "non-expand",
    label: "ALTER COLUMN ... TYPE",
    test: (sql) => /\bALTER\s+COLUMN\b.*\bTYPE\b/.test(sql),
  },
  {
    kind: "non-expand",
    label: "ADD COLUMN ... NOT NULL without DEFAULT",
    test: (sql) =>
      /\bADD\s+COLUMN\b/.test(sql) &&
      /\bNOT\s+NULL\b/.test(sql) &&
      !/\bDEFAULT\b/.test(sql) &&
      !/\bGENERATED\b/.test(sql) &&
      !/\bIDENTITY\b/.test(sql) &&
      !/\bSERIAL\b/.test(sql),
  },
  {
    kind: "non-expand",
    label: "CREATE UNIQUE INDEX without CONCURRENTLY",
    test: (sql) =>
      /\bCREATE\s+UNIQUE\s+INDEX\b/.test(sql) && !/\bCONCURRENTLY\b/.test(sql),
  },
];

function collectSqlFiles(dir) {
  const files = [];
  for (const entry of readdirSync(dir, { recursive: true })) {
    const name = String(entry);
    if (!name.toLowerCase().endsWith(".sql")) continue;
    const full = join(dir, name);
    if (statSync(full).isFile()) files.push({ name, full });
  }
  return files.sort((a, b) => a.name.localeCompare(b.name));
}

// Splits a SQL file into statements, each carrying its starting line and the
// comment lines that IMMEDIATELY precede it (a blank line breaks adjacency).
function parseStatements(content) {
  const statements = [];
  let pendingComments = [];
  let buffer = [];
  let startLine = 0;

  const lines = content.split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    const lineNo = i + 1;
    const trimmed = line.trim();

    if (buffer.length === 0) {
      if (trimmed === "") {
        pendingComments = [];
        continue;
      }
      if (trimmed.startsWith("--")) {
        pendingComments.push({ line: lineNo, text: trimmed });
        continue;
      }
      startLine = lineNo;
    }

    buffer.push(line);
    // Statement ends when the line (minus a trailing inline comment) ends
    // with `;`. Good enough for generated DDL — see header for limits.
    const withoutComment = line.replace(/--.*$/, "").trimEnd();
    if (withoutComment.endsWith(";")) {
      statements.push({
        startLine,
        comments: pendingComments,
        sql: buffer
          .map((raw) => raw.replace(/--.*$/, ""))
          .join(" ")
          .replace(/\s+/g, " ")
          .trim()
          .toUpperCase(),
      });
      buffer = [];
      pendingComments = [];
    }
  }

  if (buffer.length > 0) {
    statements.push({
      startLine,
      comments: pendingComments,
      sql: buffer
        .map((raw) => raw.replace(/--.*$/, ""))
        .join(" ")
        .replace(/\s+/g, " ")
        .trim()
        .toUpperCase(),
    });
  }

  return statements;
}

function lintFile(relPath, content) {
  const violations = [];
  for (const statement of parseStatements(content)) {
    const overrides = { destructive: false, "non-expand": false };
    for (const comment of statement.comments) {
      const match = OVERRIDE_RE.exec(comment.text);
      if (!match) continue;
      const kind = match[1];
      const reason = (match[2] ?? "").trim();
      if (reason === "") {
        violations.push(
          `${relPath}:${comment.line}: override marker without a reason - ` +
            `write '-- migration:allow-${kind} <reason>'`,
        );
        continue;
      }
      overrides[kind] = true;
    }

    for (const rule of RULES) {
      if (!rule.test(statement.sql)) continue;
      if (overrides[rule.kind]) continue;
      violations.push(
        `${relPath}:${statement.startLine}: ${rule.kind}: ${rule.label} - ` +
          `add '-- migration:allow-${rule.kind} <reason>' on the previous ` +
          `line if this is intended`,
      );
    }
  }
  return violations;
}

function main() {
  const dir = process.argv[2];
  if (!dir) {
    console.error("usage: node scripts/lint-migrations.mjs <migrations-dir>");
    process.exit(2);
  }

  if (!existsSync(dir)) {
    console.log(`migrations lint: OK (no migrations directory at ${dir})`);
    process.exit(0);
  }

  const files = collectSqlFiles(dir);
  if (files.length === 0) {
    console.log("migrations lint: OK (no SQL migrations yet)");
    process.exit(0);
  }

  const violations = [];
  for (const file of files) {
    violations.push(
      ...lintFile(join(dir, file.name), readFileSync(file.full, "utf8")),
    );
  }

  if (violations.length > 0) {
    for (const violation of violations) {
      console.error(violation);
    }
    console.error(
      `migrations lint: FAILED (${violations.length} violation(s) in ` +
        `${files.length} file(s))`,
    );
    process.exit(1);
  }

  console.log(`migrations lint: OK (${files.length} file(s) clean)`);
}

main();
