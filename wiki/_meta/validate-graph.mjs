#!/usr/bin/env node
// =============================================================================
// validate-graph.mjs — Gate ejecutable del grafo de la wiki.
//
// Sin dependencias externas (solo node:fs, node:path).
//
// QUE HACE
//   Recorre wiki/ recursivamente, lee cada .md, extrae el frontmatter YAML
//   (bloque entre los dos primeros `---`) y considera SOLO los docs que tengan
//   campo `id`. Los docs viejos sin `id` se ignoran por completo.
//
//   Valida ocho invariantes del grafo (incluida la resolucion de anclas de
//   enlaces internos) y, segun el modo, regenera o verifica wiki/MANIFIESTO.md
//   (artefacto DERIVADO, cero doctrina). Ademas emite advertencias (WARN, no
//   bloquean) sobre entradas de `provides` demasiado largas.
//
// DECISION DE PARSEO (documentada a proposito)
//   Los 26 frontmatters conviven en DOS formatos de lista:
//     1) inline   -> provides: [a, b (con, comas, internas), c]
//     2) multilinea-> provides:\n  - a\n  - b
//   En vez de NORMALIZAR los 26 docs a un solo formato (que implicaria editar
//   archivos de contenido y arriesgar el texto), este script implementa un
//   parser ROBUSTO que entiende ambos formatos:
//     - El split de listas inline respeta parentesis (), corchetes [] y
//       comillas '' "" anidados, de modo que un item como
//       `convencion (vive en X, no en prosa)` NO se parte por sus comas internas.
//     - Las listas multilinea se leen item por item de las lineas `  - ...`.
//   Asi el gate no toca el contenido: solo lo lee. Es la opcion mas segura.
//
// MODOS
//   --check  (default) : valida invariantes; si MANIFIESTO.md no existe o
//                        difiere del regenerado, falla.
//   --write            : valida invariantes y (re)genera wiki/MANIFIESTO.md.
//
// Sale con codigo 1 ante CUALQUIER violacion de invariante o desincronizacion
// del manifiesto. Imprime un resumen claro PASS/FAIL por invariante.
// =============================================================================

import {
  existsSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, ".."); // wiki/
const MANIFEST_PATH = join(ROOT, "MANIFIESTO.md");

const LIST_KEYS = new Set(["provides", "reads-before", "related"]);

// Tareas -> doc(s) de entrada. La receta es la clausura de reads-before.
const RECIPES = {
  "nueva-feature": ["arq.crear-feature"],
  "tocar-auth": ["arq.auth"],
  desplegar: ["ops.pipeline-cicd"],
  rollback: ["ops.pipeline-cicd"],
  "arrancar-proyecto": ["proc.arrancar", "proc.requerimientos"],
  "operar-servidor": [
    "ops.seguridad-operativa",
    "ops.backups",
    "ops.gestion-infra",
  ],
};

const TIER_NAMES = {
  0: "Fundamentos",
  1: "Proceso",
  2: "Arquitectura",
  3: "Operaciones",
};

// -----------------------------------------------------------------------------
// Lectura de archivos
// -----------------------------------------------------------------------------
function walk(dir, acc = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;
    if (entry.name === "node_modules" || entry.name === "_meta") continue;
    const full = join(dir, entry.name);
    if (entry.isDirectory()) walk(full, acc);
    else if (entry.isFile() && entry.name.endsWith(".md")) acc.push(full);
  }
  return acc;
}

// -----------------------------------------------------------------------------
// Parser de frontmatter (robusto, ambos formatos de lista)
// -----------------------------------------------------------------------------
function stripQuotes(s) {
  s = s.trim();
  if (s.length >= 2) {
    const a = s[0],
      b = s[s.length - 1];
    if ((a === '"' && b === '"') || (a === "'" && b === "'"))
      return s.slice(1, -1);
  }
  return s;
}

// Split por comas de nivel 0, respetando (), [] y comillas.
function splitTopLevel(inner) {
  const items = [];
  let depth = 0,
    quote = null,
    cur = "";
  for (const ch of inner) {
    if (quote) {
      cur += ch;
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      cur += ch;
      continue;
    }
    if (ch === "(" || ch === "[") {
      depth++;
      cur += ch;
      continue;
    }
    if (ch === ")" || ch === "]") {
      depth--;
      cur += ch;
      continue;
    }
    if (ch === "," && depth === 0) {
      items.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  if (cur.trim() !== "") items.push(cur);
  return items.map((x) => stripQuotes(x)).filter((x) => x.length > 0);
}

function parseInlineList(rest) {
  const open = rest.indexOf("[");
  const close = rest.lastIndexOf("]");
  if (open === -1 || close === -1 || close < open) return [];
  return splitTopLevel(rest.slice(open + 1, close));
}

// Extrae el frontmatter (entre los dos primeros `---`) y lo parsea.
// Devuelve null si el archivo no abre con frontmatter o no tiene `id`.
function parseFrontmatter(text) {
  const lines = text.split("\n");
  if (lines[0].trim() !== "---") return null;
  let end = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i].trim() === "---") {
      end = i;
      break;
    }
  }
  if (end === -1) return null;

  const fm = {};
  let i = 1;
  while (i < end) {
    const line = lines[i];
    const m = line.match(/^([A-Za-z_][\w-]*):(.*)$/);
    if (!m) {
      i++;
      continue;
    }
    const key = m[1];
    const rest = m[2].trim();

    if (LIST_KEYS.has(key)) {
      if (rest.startsWith("[")) {
        fm[key] = parseInlineList(rest);
        i++;
      } else if (rest === "") {
        const items = [];
        i++;
        while (i < end) {
          const lm = lines[i].match(/^\s+-\s+(.*)$/);
          if (!lm) {
            if (lines[i].trim() === "") {
              i++;
              continue;
            } // tolerar lineas en blanco
            break;
          }
          items.push(stripQuotes(lm[1].trim()));
          i++;
        }
        fm[key] = items;
      } else {
        fm[key] = [stripQuotes(rest)];
        i++;
      }
    } else {
      fm[key] = stripQuotes(rest);
      i++;
    }
  }

  if (!("id" in fm)) return null;
  return fm;
}

// -----------------------------------------------------------------------------
// Carga del grafo
// -----------------------------------------------------------------------------
function loadDocs() {
  const files = walk(ROOT).sort();
  const docs = [];
  const dupes = []; // { id, paths: [] }
  const byId = new Map();
  const pages = []; // TODOS los .md de la wiki (con o sin `id`), para anclas.

  for (const file of files) {
    const text = readFileSync(file, "utf8");
    pages.push({ abs: file, rel: relative(ROOT, file), text });
    const fm = parseFrontmatter(text);
    // Solo los .md con `id` son docs del grafo; el resto (p. ej. las copias
    // portables de comandos bajo operaciones/comandos/) son páginas: sus
    // anclas se validan igual, pero no participan de tiers/recetas.
    if (!fm || !fm.id) continue;
    const rel = relative(ROOT, file);
    const doc = {
      id: fm.id,
      path: rel,
      titulo: fm.titulo || "",
      tipo: fm.tipo || "",
      tier: Number.isNaN(Number(fm.tier)) ? null : Number(fm.tier),
      audience: fm.audience || "",
      resumen: fm.resumen || "",
      provides: fm.provides || [],
      readsBefore: fm["reads-before"] || [],
      related: fm.related || [],
    };
    if (byId.has(doc.id)) {
      const existing = dupes.find((d) => d.id === doc.id);
      if (existing) existing.paths.push(rel);
      else dupes.push({ id: doc.id, paths: [byId.get(doc.id).path, rel] });
    } else {
      byId.set(doc.id, doc);
    }
    docs.push(doc);
  }
  return { docs, byId, dupes, pages };
}

// -----------------------------------------------------------------------------
// Anclas de enlaces internos (slug estilo GitHub)
// -----------------------------------------------------------------------------
// Slug estilo GitHub: minusculas, se CONSERVAN las letras acentuadas (GitHub
// no quita diacriticos), se elimina la puntuacion (todo lo que no sea letra,
// numero, marca, guion bajo, espacio o guion) y los espacios pasan a guiones.
// Los prefijos numericos se conservan, como hace GitHub.
function githubSlug(heading) {
  return heading
    .toLowerCase()
    .replace(/[^\p{L}\p{M}\p{N}\p{Pc} -]/gu, "")
    .replace(/ /g, "-");
}

// Extrae las anclas de un doc: headings fuera de bloques de codigo, con el
// sufijo -1, -2, ... que GitHub agrega a los headings repetidos.
function extractAnchors(text) {
  const anchors = new Set();
  const counts = new Map();
  let fence = false;
  for (const line of text.split("\n")) {
    if (/^\s*(```|~~~)/.test(line)) {
      fence = !fence;
      continue;
    }
    if (fence) continue;
    const m = line.match(/^#{1,6}\s+(.*)$/);
    if (!m) continue;
    const base = githubSlug(m[1].trim());
    const n = counts.get(base) || 0;
    counts.set(base, n + 1);
    anchors.add(n === 0 ? base : `${base}-${n}`);
  }
  return anchors;
}

// Distancia de Levenshtein, para sugerir el ancla mas parecida.
function levenshtein(a, b) {
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) {
      cur[j] = Math.min(
        prev[j] + 1,
        cur[j - 1] + 1,
        prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1),
      );
    }
    prev = cur;
  }
  return prev[b.length];
}

function closestAnchor(frag, anchors) {
  let best = null;
  let bestD = Infinity;
  for (const a of anchors) {
    const d = levenshtein(frag, a);
    if (d < bestD) {
      bestD = d;
      best = a;
    }
  }
  return best;
}

// Recorre todos los enlaces markdown con `#fragmento` (a otro .md o al propio
// doc) y verifica que el fragmento resuelva a un heading real del destino.
function validateAnchors(pages) {
  const anchorCache = new Map(pages.map((p) => [p.abs, extractAnchors(p.text)]));
  const anchorsFor = (abs) => {
    if (!anchorCache.has(abs)) {
      anchorCache.set(
        abs,
        existsSync(abs) ? extractAnchors(readFileSync(abs, "utf8")) : null,
      );
    }
    return anchorCache.get(abs);
  };

  const violations = [];
  for (const page of pages) {
    let fence = false;
    const lines = page.text.split("\n");
    for (let i = 0; i < lines.length; i++) {
      if (/^\s*(```|~~~)/.test(lines[i])) {
        fence = !fence;
        continue;
      }
      if (fence) continue;
      const line = lines[i].replace(/`[^`]*`/g, ""); // ignorar code spans
      for (const m of line.matchAll(/\]\(([^)]+)\)/g)) {
        const target = m[1].trim().split(/\s+/)[0];
        if (/^[a-z][a-z0-9+.-]*:/i.test(target)) continue; // http:, mailto:, ...
        const hashAt = target.indexOf("#");
        if (hashAt === -1) continue;
        const pathPart = target.slice(0, hashAt);
        let frag = target.slice(hashAt + 1);
        try {
          frag = decodeURIComponent(frag);
        } catch {
          // se valida tal cual esta escrito
        }
        if (frag === "") continue;
        if (pathPart !== "" && !pathPart.endsWith(".md")) continue;
        const destAbs =
          pathPart === "" ? page.abs : join(dirname(page.abs), pathPart);
        const anchors = anchorsFor(destAbs);
        if (anchors === null) {
          violations.push(
            `${page.rel}:${i + 1}: destino inexistente "${pathPart}" (enlace "#${frag}")`,
          );
          continue;
        }
        if (!anchors.has(frag)) {
          const hint = closestAnchor(frag, anchors);
          violations.push(
            `${page.rel}:${i + 1}: "#${frag}" no existe en ${relative(ROOT, destAbs)}` +
              (hint ? ` (¿quisiste decir "#${hint}"?)` : ""),
          );
        }
      }
    }
  }
  return violations;
}

// -----------------------------------------------------------------------------
// Validacion de invariantes
// -----------------------------------------------------------------------------
function validate({ byId, dupes, pages }) {
  const results = []; // { key, label, pass, violations: [] }
  const add = (key, label, violations) =>
    results.push({ key, label, pass: violations.length === 0, violations });

  // a. id unico
  add(
    "a",
    "id unico (sin duplicados)",
    dupes.map((d) => `id duplicado "${d.id}" en: ${d.paths.join(", ")}`),
  );

  // Lista de docs unicos (primer doc por id) para el resto de chequeos.
  const uniq = [...byId.values()];

  // b. todo id en reads-before y related existe
  const refViolations = [];
  for (const d of uniq) {
    for (const r of d.readsBefore)
      if (!byId.has(r))
        refViolations.push(`${d.id}: reads-before -> id inexistente "${r}"`);
    for (const r of d.related)
      if (!byId.has(r))
        refViolations.push(`${d.id}: related -> id inexistente "${r}"`);
  }
  add("b", "referencias (reads-before/related) existen", refViolations);

  // c. related simetrico
  const symViolations = [];
  for (const d of uniq) {
    for (const r of d.related) {
      const other = byId.get(r);
      if (!other) continue; // ya reportado en (b)
      if (!other.related.includes(d.id))
        symViolations.push(
          `${d.id} lista related "${r}" pero "${r}" NO lista a "${d.id}"`,
        );
    }
  }
  add("c", "related simetrico", symViolations);

  // d. provides global sin solapamiento
  const provideOwners = new Map(); // term -> [docId]
  for (const d of uniq) {
    for (const term of d.provides) {
      const k = term.trim();
      if (!provideOwners.has(k)) provideOwners.set(k, []);
      provideOwners.get(k).push(d.id);
    }
  }
  const overlapViolations = [];
  for (const [term, owners] of provideOwners) {
    if (owners.length > 1)
      overlapViolations.push(
        `termino "${term}" provisto por ${owners.length} docs: ${owners.join(", ")}`,
      );
  }
  add("d", "provides global sin solapamiento", overlapViolations);

  // e. reads-before es un DAG (sin ciclos)
  const cycleViolations = [];
  const WHITE = 0,
    GRAY = 1,
    BLACK = 2;
  const color = new Map(uniq.map((d) => [d.id, WHITE]));
  const stack = [];
  function dfs(id) {
    color.set(id, GRAY);
    stack.push(id);
    for (const next of byId.get(id).readsBefore) {
      if (!byId.has(next)) continue;
      if (color.get(next) === GRAY) {
        const from = stack.indexOf(next);
        cycleViolations.push(
          `ciclo en reads-before: ${[...stack.slice(from), next].join(" -> ")}`,
        );
      } else if (color.get(next) === WHITE) {
        dfs(next);
      }
    }
    stack.pop();
    color.set(id, BLACK);
  }
  for (const d of uniq) if (color.get(d.id) === WHITE) dfs(d.id);
  add("e", "reads-before es un DAG (sin ciclos)", cycleViolations);

  // f. coherencia de tier: reads-before no apunta a un tier MAYOR
  const tierViolations = [];
  for (const d of uniq) {
    for (const r of d.readsBefore) {
      const other = byId.get(r);
      if (!other) continue;
      if (other.tier > d.tier)
        tierViolations.push(
          `${d.id} (tier ${d.tier}) reads-before "${r}" (tier ${other.tier}, MAYOR)`,
        );
    }
  }
  add("f", "coherencia de tier (no depende de tier mayor)", tierViolations);

  // g. sin huerfanos: todo doc de tier>0 debe tener al menos una arista
  //    ENTRANTE (alguien lo lista en reads-before o related) o ser raiz de
  //    alguna receta. Las aristas salientes NO cuentan: un doc al que nadie
  //    apunta es inalcanzable aunque el referencie a medio grafo.
  const inbound = new Map(uniq.map((d) => [d.id, 0]));
  const bump = (id, n = 1) => {
    if (inbound.has(id)) inbound.set(id, inbound.get(id) + n);
  };
  for (const d of uniq) {
    for (const r of d.readsBefore) bump(r);
    for (const r of d.related) bump(r);
  }
  for (const roots of Object.values(RECIPES)) for (const r of roots) bump(r);
  const orphanViolations = [];
  for (const d of uniq) {
    if (d.tier > 0 && inbound.get(d.id) === 0)
      orphanViolations.push(
        `${d.id} (tier ${d.tier}) es huérfano (nadie lo referencia: sin aristas entrantes ni receta que lo use)`,
      );
  }
  add("g", "sin huerfanos (tier>0 alcanzable)", orphanViolations);

  // h. anclas de enlaces internos: todo `(#fragmento)` o `(./doc.md#fragmento)`
  //    dentro de la wiki debe resolver a un heading real del doc destino.
  add(
    "h",
    "anclas de enlaces internos resuelven a un heading real",
    validateAnchors(pages),
  );

  return results;
}

// -----------------------------------------------------------------------------
// Cierre de reads-before + orden topologico (para recetas)
// -----------------------------------------------------------------------------
function depth(id, byId, memo = new Map()) {
  if (memo.has(id)) return memo.get(id);
  memo.set(id, 0); // proteccion ante ciclos (no deberia haber)
  const doc = byId.get(id);
  let d = 0;
  for (const r of doc.readsBefore) {
    if (byId.has(r)) d = Math.max(d, depth(r, byId, memo) + 1);
  }
  memo.set(id, d);
  return d;
}

function recipeClosure(entries, byId) {
  const seen = new Set();
  const queue = [...entries];
  while (queue.length) {
    const id = queue.shift();
    if (seen.has(id) || !byId.has(id)) continue;
    seen.add(id);
    for (const r of byId.get(id).readsBefore) queue.push(r);
  }
  const memo = new Map();
  return [...seen].sort((a, b) => {
    const da = depth(a, byId, memo),
      db = depth(b, byId, memo);
    if (da !== db) return da - db;
    if (byId.get(a).tier !== byId.get(b).tier)
      return byId.get(a).tier - byId.get(b).tier;
    return a.localeCompare(b);
  });
}

function nodeId(id) {
  return id.replace(/[^A-Za-z0-9]/g, "_");
}

// -----------------------------------------------------------------------------
// Generacion del MANIFIESTO (derivado)
// -----------------------------------------------------------------------------
function buildManifest({ byId }) {
  const uniq = [...byId.values()].sort(
    (a, b) => a.tier - b.tier || a.id.localeCompare(b.id),
  );

  const tiers = [...new Set(uniq.map((d) => d.tier))].sort((a, b) => a - b);
  const L = [];

  // (a) Encabezado: protocolo para un agente en sesion fresca.
  L.push("# MANIFIESTO");
  L.push("");
  L.push("> ARTEFACTO DERIVADO. No lo edites a mano: lo regenera");
  L.push(
    "> `node wiki/_meta/validate-graph.mjs --write` desde el frontmatter de cada doc.",
  );
  L.push("> El gate (`--check`) falla si este archivo queda desincronizado.");
  L.push("");
  L.push("## Protocolo para un agente en sesión fresca");
  L.push("");
  L.push(
    "1. Leé PRIMERO el **Tier 0 (Fundamentos)** completo: es el piso conceptual del que cuelga todo lo demás.",
  );
  L.push(
    "2. Descendé por tiers **bajo demanda**, no de corrido. Cada tier asume el anterior; no bajes a Operaciones si tu tarea es de Arquitectura.",
  );
  L.push(
    "3. Para una tarea concreta, cargá su **receta** (más abajo): es el cierre exacto de `reads-before` que necesitás, en orden de lectura. No leas la wiki entera.",
  );
  L.push(
    "4. Usá el **índice tema -> doc dueño** para saltar a la fuente canónica de un término sin adivinar el archivo.",
  );
  L.push(
    "5. Las flechas del DAG van de **prerequisito -> doc que lo requiere**: seguilas en el sentido de la flecha para leer en orden.",
  );
  L.push("");
  L.push(
    "**Precedencia:** cuando la tarea coincide con una receta, el cierre de la receta reemplaza la lectura de tiers completos; el Tier 0 sigue siendo el único bloque que se lee entero.",
  );
  L.push("");

  // (b) Tabla de tiers con conteo.
  L.push("## Tiers");
  L.push("");
  L.push("| Tier | Nombre | Docs |");
  L.push("| ---: | --- | ---: |");
  for (const t of tiers) {
    const count = uniq.filter((d) => d.tier === t).length;
    L.push(`| ${t} | ${TIER_NAMES[t] || "(sin nombre)"} | ${count} |`);
  }
  L.push(`| | **Total** | **${uniq.length}** |`);
  L.push("");

  // Indice de docs por tier (apoyo de navegacion).
  L.push("## Docs por tier");
  L.push("");
  for (const t of tiers) {
    L.push(`### Tier ${t} — ${TIER_NAMES[t] || ""}`);
    L.push("");
    L.push("| id | titulo | tipo | audiencia | path |");
    L.push("| --- | --- | --- | --- | --- |");
    for (const d of uniq.filter((x) => x.tier === t)) {
      L.push(
        `| \`${d.id}\` | ${d.titulo} | ${d.tipo} | ${d.audience} | \`${d.path}\` |`,
      );
    }
    L.push("");
  }

  // (c) DAG mermaid derivado de reads-before.
  L.push("## DAG de lectura (reads-before)");
  L.push("");
  L.push(
    "Flecha = `prerequisito --> doc que lo requiere`. Leé siguiendo las flechas.",
  );
  L.push("");
  L.push("```mermaid");
  L.push("graph TD");
  for (const t of tiers) {
    L.push(`  subgraph T${t}["Tier ${t} · ${TIER_NAMES[t] || ""}"]`);
    for (const d of uniq.filter((x) => x.tier === t)) {
      L.push(`    ${nodeId(d.id)}["${d.id}"]`);
    }
    L.push("  end");
  }
  // Edges: prereq --> doc
  const edges = [];
  for (const d of uniq) {
    for (const r of d.readsBefore) {
      if (byId.has(r)) edges.push(`  ${nodeId(r)} --> ${nodeId(d.id)}`);
    }
  }
  edges.sort();
  L.push(...edges);
  L.push("```");
  L.push("");

  // (d) Indice tema -> doc dueño derivado de provides.
  L.push("## Índice tema -> doc dueño");
  L.push("");
  L.push(
    "Cada término tiene UN solo doc dueño (provides global sin solapamiento).",
  );
  L.push("");
  L.push("| Tema | Doc dueño |");
  L.push("| --- | --- |");
  const terms = [];
  for (const d of uniq) for (const term of d.provides) terms.push([term, d.id]);
  terms.sort((a, b) => a[0].localeCompare(b[0], "es"));
  for (const [term, id] of terms) {
    L.push(`| ${term.replace(/\|/g, "\\|")} | \`${id}\` |`);
  }
  L.push("");

  // (e) Recetas por tarea (cierre de reads-before, en orden de lectura).
  L.push("## Recetas por tarea");
  L.push("");
  L.push(
    "Cada receta es el cierre de `reads-before` de su doc de entrada, en orden de lectura (prerequisitos primero).",
  );
  L.push("");
  for (const [task, entries] of Object.entries(RECIPES)) {
    const closure = recipeClosure(entries, byId);
    L.push(`### \`${task}\``);
    L.push("");
    L.push(
      `Entrada: ${entries.map((e) => `\`${e}\``).join(", ")} — ${closure.length} docs.`,
    );
    L.push("");
    let n = 1;
    for (const id of closure) {
      const d = byId.get(id);
      L.push(`${n}. \`${id}\` — ${d.titulo} _(tier ${d.tier})_`);
      n++;
    }
    L.push("");
  }

  return L.join("\n").replace(/\n+$/, "") + "\n";
}

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------
function main() {
  const mode = process.argv.includes("--write") ? "write" : "check";
  const graph = loadDocs();

  console.log(
    `Docs con frontmatter \`id\`: ${graph.docs.length} (unicos: ${graph.byId.size})\n`,
  );

  const results = validate(graph);

  console.log("Invariantes:");
  let anyFail = false;
  for (const r of results) {
    const status = r.pass ? "PASS" : "FAIL";
    if (!r.pass) anyFail = true;
    console.log(`  [${status}] (${r.key}) ${r.label}`);
    for (const v of r.violations) console.log(`         - ${v}`);
  }
  console.log("");

  // Advertencia (WARN, no bloquea): el indice guarda TERMINOS, no resumenes
  // de doctrina. Toda entrada de `provides` de mas de 80 caracteres se lista
  // (mas larga primero) para que el recorte sea mecanico.
  const longProvides = [];
  for (const d of graph.byId.values()) {
    for (const term of d.provides) {
      const t = term.trim();
      if (t.length > 80) longProvides.push({ id: d.id, term: t, len: t.length });
    }
  }
  if (longProvides.length > 0) {
    longProvides.sort((a, b) => b.len - a.len);
    console.log(
      `Advertencias (no bloquean el gate):\n  [WARN] ${longProvides.length} entradas de provides superan los 80 caracteres (el índice guarda TÉRMINOS, no resúmenes de doctrina):`,
    );
    for (const w of longProvides)
      console.log(`         - ${w.id}: "${w.term}" (${w.len})`);
    console.log("");
  }

  if (anyFail) {
    console.error(
      "FAIL: hay violaciones de invariantes. No se toca el MANIFIESTO.",
    );
    process.exit(1);
  }

  const manifest = buildManifest(graph);

  if (mode === "write") {
    writeFileSync(MANIFEST_PATH, manifest);
    console.log(
      `[PASS] MANIFIESTO.md regenerado (${relative(ROOT, MANIFEST_PATH)}).`,
    );
    console.log("\nRESULTADO: PASS");
    process.exit(0);
  }

  // mode === 'check'
  if (!existsSync(MANIFEST_PATH)) {
    console.error(
      "[FAIL] MANIFIESTO.md no existe. Corré: node wiki/_meta/validate-graph.mjs --write",
    );
    process.exit(1);
  }
  const current = readFileSync(MANIFEST_PATH, "utf8");
  if (current !== manifest) {
    console.error("[FAIL] MANIFIESTO.md esta desincronizado con el grafo.");
    console.error(
      "       Regeneralo: node wiki/_meta/validate-graph.mjs --write",
    );
    process.exit(1);
  }
  console.log("[PASS] MANIFIESTO.md sincronizado con el grafo.");
  console.log("\nRESULTADO: PASS");
  process.exit(0);
}

main();
