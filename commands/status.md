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

4. **Cambios SDD activos** — si existe `openspec/changes/`, listá su contenido excluyendo `archive/`.

5. **Backlog pendiente** — si existe `software_requirements/00-handoff.md`, extraé los ítems del backlog de cambios candidatos que todavía no tienen rama ni cambio SDD.

## Qué sintetizar (en este orden)

- **Quién está en qué slice**: rama activa → autor → antigüedad del último commit.
- **PRs abiertos**: cuáles esperan review, cuáles están estancados.
- **Cambios SDD en curso**: qué carpetas de `openspec/changes/` están vivas y en qué fase.
- **Slices libres**: qué ítems del backlog no tienen a nadie encima — eso es lo que se puede agarrar sin pisar a otro.

Cerrá con una recomendación concreta: "si vas a arrancar algo, X e Y están libres; Z ya lo tiene <autor>".
