# Secretos

- REGLA INVIOLABLE: ningún secreto llega a git/GitHub — ni en código, ni en docs, ni en ejemplos, ni en mensajes de commit, ni en ningún archivo versionado. Verificá antes de cada commit que no se cuele un valor real.
- Guardá los valores solo en `secrets/<env>.env` (fuente por entorno) y `.env` (dev local), ambos gitignored; de ahí `deploy.sh` los crea como Docker secrets montados en `/run/secrets/` — nunca horneados en la imagen.
- Respetá el contrato de nombre: nombre del secret (su `target`) = clave del campo en el schema Zod de `config`, sin tabla de mapeo.
- Si un secreto entró a git, avisá de inmediato y ROTALO: borrarlo del historial no alcanza.
- Tratá el token Hetzner read-write como break-glass: vive en el gestor de secretos del equipo, se inyecta just-in-time vía `$HCLOUD_TOKEN` solo para una operación mutadora confirmada por un humano, y se descarta al terminar — nunca lo persistas en disco plano ni en el nodo.
- PROHIBIDO anotar un secreto en engram (token, contraseña, clave privada): la memoria sincroniza a un server compartido y commitea chunks a git, así que lo filtraría al equipo y al historial. Engram guarda el saber SOBRE el secreto (que existe, dónde vive, cómo rotarlo), nunca su valor — el valor solo en el gestor del equipo.
- Pedí las API keys que te falten al usuario directamente en el chat: pasar secretos por el chat está OK.
- Tratá todo token (túnel, API key) con el mismo cuidado que cualquier otro secreto: cualquiera que lo tenga puede usarlo.

Doctrina: wiki/operaciones/07_referencia-secretos.md
