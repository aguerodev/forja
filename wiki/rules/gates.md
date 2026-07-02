# Gates

- Corré `pnpm run check` y dejalo verde antes de abrir o mergear un PR: local = CI — mismos gates, mismas versiones, mismo veredicto.
- Escribí el test rojo ANTES de la implementación (TDD estricto, ciclo rojo-verde-refactor): el test rojo define qué es "hecho".
- Tras tocar cualquier doc de la wiki o su frontmatter (en el repo de la doctrina forja), corré `node wiki/_meta/validate-graph.mjs --check` (y `--write` para regenerar el MANIFIESTO).
- JAMÁS edites `wiki/MANIFIESTO.md` a mano: es un artefacto derivado del frontmatter; lo regenera `validate-graph.mjs --write`.
- Tratá el mutation testing (Stryker) como métrica nightly, no como gate de merge: subirlo a gate es un punto del dial, no el default.
- Si un gate falla, corregí el código o el diseño, nunca el gate: los guardarraíles que importan son ejecutables.

Doctrina: wiki/arquitectura/07_referencia-gates-tooling.md, wiki/proceso/02_explicacion-tdd.md
