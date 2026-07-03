---
name: report-failure
description: 'Reportar a GitHub un fallo de un flujo forja para mejora continua. Usala cuando un comando del plugin (/forja:init, deploy, rollback, status, doctor) o un hook falle, se cuelgue, tire un error inesperado o termine a mitad de camino. Junta el diagnóstico real (versión de Claude Code, SO, versión del plugin), busca duplicados y abre un issue SOLO con confirmación humana. Keywords: fallo, error, flujo roto, reportar bug, issue, flow-failure.'
---

# Reportar un fallo de flujo forja

Cuando un flujo del plugin falla, ese fallo es material de mejora continua — pero
solo si queda registrado con contexto real y **sin ensuciar el repo público**.
Este es el protocolo. No lo saltees ni improvises un `gh issue create` a mano.

## Cuándo se dispara

Apenas un flujo forja termina mal: un comando (`/forja:init`, `/forja:deploy`,
`/forja:rollback`, `/forja:status`, `/forja:doctor`) que aborta, un hook que
degrada, un script de `bin/` o `scripts/` que sale con error, o cualquier paso
que no llegó a su objetivo. No lo uses para errores del código del USUARIO en su
proyecto — solo para fallos del propio plugin forja.

## Protocolo (5 pasos, en orden)

1. **Colectá el diagnóstico.** Corré el script — mide las versiones, no las
   adivines. Pasá lo que sepas del fallo por flags; lo que omitas queda como
   placeholder `_(completar)_`:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/forja-report.sh" \
     --command "/forja:deploy production" \
     --phase "backup off-site" \
     --summary "Falló X al hacer Y" \
     --expected "Esperaba Z" \
     --error "<salida del error, ya sin secretos>"
   ```

   El script redacta `$HOME → ~` y enmascara tokens conocidos, pero **vos sos
   responsable** de no pasarle secretos crudos en `--error`/`--summary`. Guardá
   la salida en un archivo temporal (scratchpad), no en el repo.

2. **Buscá duplicados.** Antes de crear nada, mirá si ya existe:

   ```bash
   gh issue list --repo aguerodev/forja --label flow-failure --state all \
     --search "<comando> <síntoma clave>"
   ```

   Si hay un issue que describe el mismo fallo → **no crees uno nuevo**. Sumá un
   comentario con el nuevo entorno (`gh issue comment <n> --body-file ...`) y
   avisale al usuario que era un duplicado.

3. **Mostrale el reporte al humano.** Pegá el body ya armado en el chat. Este
   repo es PÚBLICO: que el usuario confirme que no quedó nada sensible (rutas,
   nombres internos, tokens). Sin esta confirmación, NO seguís.

4. **Creá el issue — solo con SÍ explícito:**

   ```bash
   gh issue create --repo aguerodev/forja \
     --title "$("${CLAUDE_PLUGIN_ROOT}/scripts/forja-report.sh" --command "..." --phase "..." --title-only)" \
     --label flow-failure \
     --body-file <archivo-del-body>
   ```

   Si el label `flow-failure` no existe todavía en el repo, crealo una vez:
   `gh label create flow-failure --repo aguerodev/forja --color B60205 --description "Fallo de un flujo del plugin"`.

5. **Cerrá el loop.** Pasale al usuario la URL del issue (o del comentario) y una
   línea de qué se reportó. Si guardaste el body en un temporal, borralo.

## Reglas duras

- **Nunca** abras un issue sin confirmación humana. Repo público = consentimiento
  explícito, no defaults silenciosos.
- **Nunca** dispares esto desde un hook automático ni en un loop. Un fallo → a lo
  sumo un issue, y siempre mediado por una persona.
- **Nunca** pegues el output crudo de un error sin redactarlo. Ante la duda,
  mostráselo al usuario y que decida.
- Si `gh` no está instalado o no hay auth, no falles: guardá el body en el
  scratchpad y decile al usuario cómo subirlo a mano.
