---
description: Estado del proyecto - quién está en qué, cambios SDD en curso, ramas activas y PRs abiertos. Team status, who is working on what, active branches, open work.
---

# /forja:status

Foto de solo-lectura del estado del equipo para elegir trabajo **sin colisionar**. Doctrina: una feature = una carpeta = un agente (regla `multi-agente`). NO modifiques nada: ni fetch con merge, ni checkout, ni escrituras.

## Qué mirar

1. **Sincronizar referencias** (solo lectura de la remota):

```bash
git fetch --prune --quiet
```

2. **Ramas de trabajo activas** (feature/release/hotfix, más recientes primero):

```bash
git for-each-ref --sort=-committerdate refs/remotes --format='%(refname:short) %(committerdate:relative) %(authorname)' | grep -E '/(feature|release|hotfix)/'
```

3. **PRs abiertos** — si `gh` está disponible y hay remota GitHub; si no, salteá este paso sin ruido:

```bash
gh pr list --state open 2>/dev/null || echo "sin gh o sin remota GitHub - paso salteado"
```

4. **Cambios SDD activos** — si existe `openspec/changes/`, listá su contenido excluyendo `archive/`. Si NO existe `openspec/` pero SÍ hay `software_requirements/`, marcá un WARN: puede que un `sdd-init` haya dejado el artifact store en `engram` — la doctrina del equipo es `openspec` (los artefactos del cambio viajan en el PR; en engram quedan invisibles para el resto).

5. **Backlog pendiente** — si existe `software_requirements/00-handoff.md`, extraé los ítems del backlog de cambios candidatos que todavía no tienen rama ni cambio SDD.

6. **Memoria de equipo** — SOLO si existe `.engram/manifest.json` (sin ese archivo el comando igual sale 0 y muestra números del store personal del dev, no del equipo):

```bash
[ -f .engram/manifest.json ] && command -v engram >/dev/null && engram sync --status || echo "sin memoria de equipo en este repo - paso salteado"
```

## Qué sintetizar (en este orden)

- **Quién está en qué slice**: rama activa → autor → antigüedad del último commit.
- **PRs abiertos**: cuáles esperan review, cuáles están estancados.
- **Cambios SDD en curso**: qué carpetas de `openspec/changes/` están vivas y en qué fase.
- **Slices libres**: qué ítems del backlog no tienen a nadie encima — eso es lo que se puede agarrar sin pisar a otro.
- **Memoria de equipo**: `Pending import > 0` → hay conocimiento del equipo sin importar (el hook lo hace al abrir sesión). OJO: el status cuenta chunks, NO observaciones — las memorias guardadas y nunca exportadas son invisibles acá; el único momento que garantiza el export es el cierre de la unidad de trabajo (`engram sync` + commit de `.engram/`).

Cerrá con una recomendación concreta: "si vas a arrancar algo, X e Y están libres; Z ya lo tiene <autor>".
