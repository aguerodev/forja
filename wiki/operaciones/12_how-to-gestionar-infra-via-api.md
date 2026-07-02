---
id: ops.gestion-infra
titulo: Gestionar la infraestructura vía la API de Hetzner
tipo: how-to
tier: 3
audience: both
resumen: Cómo un agente de IA opera el ciclo de vida del nodo vía la API de Hetzner (hcloud) con guardarraíles ejecutables, no en prosa.
provides:
  - "confirmar-o-crear idempotente por label"
  - "identidad de recursos por label managed-by=agent"
  - "wrapper hcloud-agent.sh como choke-point"
  - "matriz autonomo/human-confirmed/prohibido de operaciones de infra"
  - "enable-protection delete/rebuild como candado a nivel API"
  - "dos tokens hcloud segregados (read default / write break-glass)"
  - "IP derivada de la API (nunca cacheada)"
  - "firewall declarativo replace-rules desde archivo versionado"
  - "infra-verify.sh gate de post-condiciones"
  - "snapshot pre-cambio como precondicion"
  - "diff-gate firewall (describe vivo vs archivo) como plan de los pobres"
  - "secuencia describe -> diff -> confirmar -> apply -> verify del wrapper"
  - "auditoria off-host del agente (Hetzner no da audit per-recurso rico)"
  - "el dial hcloud scripts vs IaC para un nodo unico"
reads-before: [ops.modelo-operacion]
related: []
---

# Gestionar la infraestructura vía la API de Hetzner

Cómo un **agente de IA** gestiona el ciclo de vida del servidor de producción a través de la API de Hetzner (`hcloud`): confirmar-o-crear el nodo idempotentemente, recuperar su IP desde la API, aplicar el Cloud Firewall declarativamente y operar el plano de snapshots del proveedor. Este documento es el **hogar de esa capacidad**; otros docs la referencian pero la doctrina vive acá.

Asume el modelo de un solo nodo descrito en [modelo de operación](./01_explicacion-modelo-operacion.md) y se apoya en artefactos ejecutables que viven en dos lugares: el wrapper `hcloud-agent.sh`, el validador `validate-firewall-rules.sh` y el gate `infra-verify.sh` viven en el `bin/` del plugin forja (quedan en el PATH de la sesión); el ruleset `firewall-rules.json` vive en `ops/` del repo del proyecto — su historial de git es la bitácora de auditoría.

---

## Norma

Darle a un LLM la API de Hetzner es darle una motosierra. El token de Hetzner es de **granularidad gruesa**: solo existe `Read` o `Read&Write` por proyecto — Hetzner **no** ofrece scope por recurso, ni IAM fino, ni tokens efímeros/STS. Por lo tanto el control **no puede apoyarse en el scope del token**. Se apoya en cuatro palancas reales, en orden de fuerza: (1) protección ejecutable a nivel API, (2) un wrapper como único choke-point, (3) dos tokens segregados, (4) un proyecto Hetzner dedicado a prod como única frontera de blast radius.

La filosofía aplicada: para **un** nodo, `hcloud` + scripts bash idempotentes + archivos declarativos versionados **alcanzan**. Robusto no es máximo. Terraform/Pulumi quedan en el dial — para un nodo único *aumentan* el riesgo, porque el state file permite que un `apply` destruya para converger.

### Identidad por LABEL, no por nombre ni IP

Todo recurso que el agente toca nace etiquetado, y el **selector de label es la fuente de verdad**. El agente nunca identifica un server por nombre escrito a mano ni por una IP recordada: pregunta por `managed-by=agent` y sus labels de `app`/`env`. El nombre es decorativo; el label es contractual.

- Toda lectura que el agente parsea usa `-o json`. Nunca se scrapea la tabla humana de la CLI.
- El invariante de cardinalidad es **`>1 match = hard stop`**: si el selector devuelve más de un recurso, el agente se detiene y escala. Jamás elige uno por su cuenta.

### Estado recuperable: la API es la verdad, la IP se DERIVA

La IP del nodo es un **dato derivado, no estado primario**. Persistirla crea una segunda fuente de verdad que driftea tras cada rebuild o resize. El `docker context` y el target SSH se regeneran **siempre desde la API**, nunca al revés.

Si existe un cache local (por ejemplo `.infra-state.json`, gitignored), no es autoridad: cada corrida lo **reconcilia** contra la API y **gana la API**. El agente debe poder reconstruir su mundo entero — IP, id, estado del firewall — preguntándole a Hetzner, sin depender de nada que haya guardado localmente.

### Reconciliar vs recrear: converger, JAMÁS delete + recreate

El default absoluto ante una divergencia es **converger atributos**, no recrear el recurso. Si el nodo existe pero algún atributo mutable difiere de lo deseado (labels, backup habilitado, firewall aplicado), el agente ajusta ese atributo en su lugar. Nunca resuelve un drift borrando y volviendo a crear: ese patrón — natural en herramientas de IaC con state — es precisamente el modo de fallo que esta doctrina prohíbe en un nodo con datos.

Recrear es destruir. Destruir está fuera del toolset del agente (ver matriz). Por eso "reconciliar vs recrear" no es una preferencia de estilo: es la frontera entre una operación autónoma segura y una catástrofe irreversible.

### Firewall declarativo por API: replace-rules + diff-gate

El ruleset del Cloud Firewall vive versionado en `ops/firewall-rules.json` del repo del proyecto: **deny-all inbound** salvo `22/tcp`, con la regla declarada por separado para **IPv4 y IPv6** (son reglas distintas), y egress permitido. El borde real de la app lo sigue cubriendo Cloudflare delante del túnel — este firewall es la defensa de plano de red del nodo, no el WAF (ver [seguridad operativa](./10_referencia-seguridad-operativa.md)).

El agente converge el firewall con **una sola operación atómica**, `replace-rules` desde el archivo, **nunca** con `add-rule` incremental. La razón es dura: `add-rule` acumula drift y abre puertos sin cerrar los viejos; `replace-rules` impone el archivo entero como verdad. Antes de aplicar, el agente lee el estado vivo (`firewall describe -o json`) y muestra el **diff vivo-vs-archivo** — el `terraform plan` de los pobres. Ese diff es el **diff-gate**: ningún cambio de firewall se aplica sin que el plan sea visible y revisado.

El historial de git de `firewall-rules.json` **es** el log de auditoría del firewall: cada apply legítimo es un commit con autor y diff.

### La matriz de tres clases

La clase de una operación la fija el **daño irreversible que puede causar**, no la intención del agente. Si una operación puede **destruir datos** o **abrir un puerto al mundo**, no es autónoma — abrir el firewall es tan peligroso como borrar.

| Clase | Token | Operaciones |
|---|---|---|
| **Autónomo — lectura** (blast radius cero) | READ | `server list/describe/ip`, `server metrics`, `firewall describe` + diff, `image list`, detección de drift, auditoría, lecturas de frescura off-site (`sftp ls` al Storage Box, o `restic snapshots` si el dial está activo) |
| **Autónomo — additivo** (no destruye, da rollback) | R&W just-in-time | `create-image --type snapshot` pre-cambio, `enable-backup`, `add-label`, `server reboot` graceful (**no** `reset`) |
| **Human-confirmed** (gate previo + token inyectado) | R&W break-glass | `server create` (aun con el guard idempotente), `firewall replace-rules` que **agregue** inbound, `change-type`/resize, restore desde snapshot |
| **PROHIBIDO al agente** (fuera del toolset + protección a nivel API) | — | `server delete`, `server rebuild`, `firewall delete`, `remove-from-resource`, `disable-protection`, `volume delete`, `image delete`, `disable-backup` |

Esta matriz es la misma frontera que el plano de [backups](./09_how-to-backups.md) aplica a snapshots y restic; acá vive su forma completa para toda la infra.

### Guardarraíles del token

**Protección ejecutable a nivel API — el candado más fuerte.** Se enciende en el aprovisionamiento (junto a `--enable-backup`, ver [aprovisionar servidor](./03_how-to-aprovisionar-servidor.md)) con `enable-protection delete rebuild`. Con esto, **ni el token Read&Write puede borrar o reconstruir** el server: la API rechaza la operación hasta que un humano quita la protección en consola. Convierte "no borres el server" de prosa en un exit code.

**Dos tokens segregados** — la granularidad gruesa de Hetzner obliga a esto:

- **Token READ** = default del loop autónomo. Lista, describe, deriva IP, lee métricas y describe firewall. No puede crear, destruir ni abrir puertos. Es el token que el agente tiene a mano por defecto.
- **Token READ&WRITE** = **break-glass**. Vive en el gestor de secretos del equipo (su ciclo de vida y rotación se dan de alta en [secretos](./07_referencia-secretos.md)), **nunca** en el nodo. Se inyecta vía la variable de entorno `HCLOUD_TOKEN` solo durante una operación confirmada y se descarta al terminar.

Como Hetzner no da tokens efímeros, la "mínima exposición temporal" se logra **inyectando el R&W por ventana y rotándolo**, no con un token de 15 minutos. La única defensa contra un duplicate-create en un retry es el `list-by-label` previo, no el token.

### El dial: `hcloud` scripts vs IaC declarativa

Para un nodo único, la herramienta correcta es lo que está acá: `hcloud` + bash idempotente + JSON versionado. Subir a IaC es una **escalación con disparador explícito**, no un default:

| Escalación | Disparador concreto | Por qué no antes |
|---|---|---|
| **Terraform / OpenTofu / Pulumi** | Aparece una flota o un grafo de recursos interdependientes que exige `plan` revisable + drift detection | El state file permite que `apply` destruya para converger → *aumenta* el riesgo del LLM en un nodo único. Si se sube: state remoto cifrado y locked desde el día uno, `plan` autónomo pero `apply` human-confirmed, jamás `-auto-approve`, `prevent_destroy` en prod |
| **Floating IP** | Un consumidor externo allowlistea la IP de egress, o se publica un A record fuera del túnel | Con el túnel saliente la IP del server no es punto de estabilidad de la app |
| **Load Balancer** | Multi-nodo con distribución L4 más abandono del modelo de túnel | Cloudflare ya hace TLS/WAF/rate-limit al borde |
| **Private Network** | Salto multi-nodo (puertos de Swarm hacia la IP privada del peer) | Un nodo único no la necesita |

---

## Camino verificado

El procedimiento ejecutable. El agente **nunca** llama `hcloud` crudo: llama al wrapper `hcloud-agent.sh`, que es el único choke-point. Los placeholders (`<app>`, `<env>`, `<type>`, `<loc>`, `<fw>`) se parametrizan por proyecto.

### Confirmar-o-crear por label (idempotente)

Crear **solo si** el selector de label vuelve vacío; reusar si hay exactamente uno; detenerse si hay más de uno.

```bash
MATCHES=$(hcloud server list -l managed-by=agent,app=<app>,env=<env> -o json | jq length)
case "$MATCHES" in
  0) hcloud server create \
       --name <app>-<env> --type <type> --location <loc> \
       --label managed-by=agent,app=<app>,env=<env> ;; # crear SOLO si vacío
  1) : ;;                                                # reusar, no recrear
  *) echo "AMBIGUO: >1 match — STOP" >&2; exit 1 ;;      # el agente jamás elige
esac
```

### Derivar la IP desde la API (nunca cachearla)

```bash
# La IP es derivada: se re-pregunta cada corrida, nunca se persiste como verdad.
hcloud server list -l managed-by=agent,app=<app>,env=<env> -o json \
  | jq -r '.[0].public_net.ipv4.ip'   # contemplar null si la plantilla eligió IPv6-only
```

El `docker context` / target SSH se regenera siempre a partir de este valor.

### Snapshot pre-cambio como precondición

Toda mutación riesgosa se precede de un snapshot additivo (no destruye, da rollback):

```bash
hcloud server create-image --type snapshot --id <id> \
  --label managed-by=agent,reason=pre-change \
  --description "pre-change-$(date +%s)"
```

### Encender el candado a nivel API

```bash
# Tras el aprovisionamiento: ni el token R&W puede borrar/reconstruir el nodo.
hcloud server enable-protection <id> delete rebuild
```

### Converger el firewall: diff-gate antes de replace-rules

```bash
# 1. Validar el archivo ANTES de tocar la API (bloquea 0.0.0.0/0 fuera de allowlist,
#    exige el par v4+v6 y la regla SSH). El validador está en el PATH (bin/ del plugin).
validate-firewall-rules.sh ops/firewall-rules.json

# 2. Leer el estado vivo y mostrar el diff (el "plan" de los pobres).
hcloud firewall describe <fw> -o json > /tmp/fw-live.json
diff <(jq -S '.rules' /tmp/fw-live.json) \
     <(jq -S '.' ops/firewall-rules.json) || true   # diff-gate: revisable

# 3. Converger con UNA operación atómica desde el archivo versionado.
hcloud firewall replace-rules <fw> --rules-file ops/firewall-rules.json
hcloud firewall apply-to-resource <fw> --type server --server <id>
```

`firewall-rules.json` declara `deny-all` inbound salvo `22/tcp` en v4 y v6 (reglas separadas) y egress abierto. Su historial de git es el log de auditoría.

### Dry-run como disciplina del wrapper

`hcloud` **no** tiene un `--dry-run` universal. El wrapper lo suple forzando, para toda mutación, la secuencia:

```
describe-actual  ->  diff/plan  ->  confirmación humana  ->  apply  ->  verify-postcondición
```

El agente puede creer que solo previsualiza, pero el wrapper es quien garantiza que no mute sin pasar por el gate.

### El wrapper como único choke-point

`hcloud-agent.sh` —en el `bin/` del plugin forja, en el PATH de la sesión— es la única superficie por la que el agente toca Hetzner. Responsabilidades:

- **Allowlist de verbos**: solo deja pasar lo autónomo; niega lo destructivo aunque venga el token R&W.
- **Token por env var, nunca como argumento**: inyecta `HCLOUD_TOKEN` en el entorno y jamás lo pasa en la línea de comando (aparecería en `ps`/history).
- **Selector por label forzado** y salida `-o json`.
- **Manejo de la API async**: backoff ante `429` (Hetzner limita ~3600 req/h por proyecto) y poll de la acción ante `409` (recurso locked / acción en progreso), nunca reintento ciego.

### Gate de post-condiciones

Después de cualquier cambio, `infra-verify.sh` (también en el `bin/` del plugin) valida a nivel API que el mundo quedó como se esperaba: el server existe y está `running`, la protección `delete`/`rebuild` sigue encendida, el firewall aplicado coincide con `ops/firewall-rules.json`, y la IP derivada responde. Si una post-condición falla, el cambio se considera no terminado.

### Auditoría off-host

Hetzner no entrega un audit log per-recurso rico. El agente **emite su propio rastro** fuera del nodo: cada invocación del wrapper registra verbo, selector, diff y resultado en un destino de auditoría externo al server. Así el log de lo que el agente hizo sobrevive a la pérdida del nodo y no depende de la consola de Hetzner.

### Qué NO debe hacer el agente

- **No colapsar capas.** El agente que gestiona la infra **no** es el mismo plano que despliega apps ni que define el borde: opera el ciclo de vida del nodo, no el contenido. Reconciliar un atributo del server no es excusa para tocar el deploy, los secretos del nodo o el WAF.
- **No abrir el borde.** El agente nunca agrega inbound al firewall de forma autónoma: cualquier `replace-rules` que introduzca un puerto entrante es **human-confirmed**. Abrir un puerto al mundo es tan irreversible en su daño como borrar datos.
- **No delete, no rebuild, no disable-protection.** Estas operaciones están fuera de su toolset y, además, bloqueadas por la protección a nivel API. La doble defensa es deliberada: ni un prompt malicioso ni un bug pueden saltarla.
- **No recrear para converger.** Ante drift, ajustar atributos; jamás resolver borrando y volviendo a crear.
