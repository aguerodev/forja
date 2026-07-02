// .dependency-cruiser.cjs
// The six executable architecture contracts (doctrine: wiki arquitectura/07).
// Any violation breaks the build: `depcruise src` runs inside `pnpm run check`.
/** @type {import('dependency-cruiser').IConfiguration} */
module.exports = {
  forbidden: [
    {
      name: "domain-stays-pure",
      severity: "error",
      comment:
        "El núcleo del hexágono (domain.ts, ports.ts) solo puede importar su propio dominio, los errores de core y el código puro de shared. Todo lo demás —frameworks, ORM, driver, Zod, builtins de node y los adaptadores del slice, service.ts incluido— queda fuera por construcción.",
      from: { path: "(^|/)(domain|ports)\\.ts$" },
      to: {
        pathNot: [
          "(^|/)(domain|ports)\\.ts$",
          "^src/core/errors",
          "^src/shared/",
        ],
      },
    },
    {
      name: "inward-layering",
      severity: "error",
      comment:
        "Las dependencias apuntan siempre hacia adentro. El borde (route.ts, actions.ts) entra por el service y los schemas, nunca salta directo al repositorio, la tabla, el dominio ni a un adaptador de egreso. El repositorio es el adaptador de persistencia; cualquier integración con un tercero vive en un <provider>.adapter.ts del slice y queda igual de prohibida como destino directo del borde.",
      from: { path: "(^|/)(route|actions)\\.ts$" },
      to: { path: "(^|/)(repository|table|domain)\\.ts$|\\.adapter\\.ts$" },
    },
    {
      name: "features-are-independent",
      severity: "error",
      comment:
        "Una feature no puede alcanzar los internos de otra; el cruce va exclusivamente por su superficie pública public.ts.",
      from: { path: "^src/features/([^/]+)/.+" },
      to: {
        path: "^src/features/([^/]+)/.+",
        pathNot: "^src/features/$1/.+|^src/features/[^/]+/public\\.ts$",
      },
    },
    {
      name: "server-only-boundary",
      severity: "error",
      comment:
        "La capa de presentación (componentes cliente en src/components) no puede alcanzar el config de secretos (/run/secrets), el pool de la base ni un service. Adelanta —en el loop local, antes del bundler— el guardarraíl duro del paquete 'server-only'.",
      // NOTE: `(config|db)[./]` (not the wiki's `(config|db)/`): on this tree
      // config is a FILE (src/core/config.ts), so the rule must match both
      // `config.ts` and a future `config/` directory to actually fire.
      from: { path: "^src/components/" },
      to: { path: "^src/core/(config|db)[./]|(^|/)service\\.ts$" },
    },
    {
      name: "no-circular",
      severity: "error",
      comment:
        "El grafo de dependencias entre slices es acíclico. Aunque cada cruce cross-feature pase por public.ts (features-are-independent), eso no impide que A->public(B) y B->public(A) cierren un ciclo: a escala, los ciclos son el modo típico de podredumbre del monolito modular. Esta regla nativa de dependency-cruiser convierte 'el grafo no se enreda' de promesa en guardarraíl.",
      from: {},
      to: { circular: true },
    },
    {
      name: "egress-through-httpclient",
      severity: "error",
      comment:
        "Todo egreso de red sale por el cliente HTTP central de src/core/http (el puerto HttpClient y su único adaptador). Importar primitivas crudas de red —fetch global, undici, axios, node:http/node:https— desde cualquier otro lugar queda prohibido: ahí es donde viven el timeout requerido, el hook anti-SSRF y la redacción de secretos en telemetría. El seam de egreso deja de ser prosa y pasa a ser GATE.",
      // NOTE: `(node:)?https?` (not the wiki's `node:https?`): dependency-
      // cruiser normalizes core-module names by stripping the `node:` prefix
      // (an `import "node:https"` resolves as `https`), so both spellings
      // must match or the contract never fires.
      from: { pathNot: "^src/core/http/" },
      to: {
        path: "^(undici|axios)$|^(node:)?https?$",
      },
    },
  ],
  options: {
    tsPreCompilationDeps: true,
    tsConfig: { fileName: "tsconfig.json" },
    doNotFollow: { path: "node_modules" },
    enhancedResolveOptions: {
      exportsFields: ["exports"],
      conditionNames: ["import", "require", "node", "default"],
    },
  },
};
