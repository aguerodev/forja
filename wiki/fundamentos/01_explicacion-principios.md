---
id: fund.principios
titulo: Principios del proyecto
tipo: explicacion
tier: 0
audience: both
resumen: Las tres reglas rectoras, los principios de desempate y el dial como mecanismo de complejidad diferida.
provides:
  - "las tres reglas rectoras"
  - "alcance por proyecto (regla del síntoma inverso; piso: dominio puro + check + slice)"
  - "convención sobre configuración (la convención vive en una herramienta, no en prosa)"
  - "robusto no es máximo (principio)"
  - "ceremonia proporcional al riesgo (principio)"
  - "el dominio puro es innegociable (principio)"
  - "el test antes que la implementacion (principio)"
  - "guardarraíles ejecutables (principio)"
  - "reproducibilidad de punta a punta (principio)"
  - "localidad + fronteras (palancas de contexto y radio de daño)"
  - "el dial (complejidad diferida / escalación consciente)"
  - "disparador (síntoma que justifica el salto, nunca una fecha)"
  - "catálogo del dial (pares disparador -> salto)"
  - "monitoreo base de recursos del host como precondición del dial (no es dial)"
  - "patrón outbox transaccional (entrada del catálogo del dial: garantía at-least-once; obligatorio si un handler con inbox produce un efecto externo)"
  - "SSE como feature deliberada (entrada del dial: Route Handler con ReadableStream; push unidireccional servidor->cliente)"
  - "WebSockets (salto mayor del dial: canal bidireccional persistente; rompe output standalone y exige servidor aparte)"
  - "read-model / CQRS (entrada del dial: proyección de lectura separada del modelo de escritura)"
  - "caching escalado por niveles (entrada del dial: Next Data Cache entre requests -> Redis como puerto compartido entre instancias)"
  - "Row-Level Security de PostgreSQL (entrada del dial: aislar filas por tenant cuando aparece multi-tenancy real)"
  - "motor distribuido de rate limiting (entrada del dial: cuota fina con store compartido; el límite básico por endpoint no es dial)"
reads-before: []
related: [ops.modelo-operacion]
---

# Los principios del proyecto y por qué existen

Las reglas que resuelven los empates cuando algo no está escrito, cada una con su razón. Esta es la fuente de verdad de la filosofía: si el código contradice una regla, se corrige el código o se actualiza la regla. Las herramientas que las imponen están en la [referencia del stack](./03_referencia-stack-desarrollo.md); cómo se vuelven estructura, en [la arquitectura por dentro](../arquitectura/01_explicacion-arquitectura-hexagonal.md).

## Las tres reglas rectoras

1. **Convención sobre configuración.** Cada decisión recurrente tiene un único default; no hay "elige tú". Cada bifurcación es divergencia, y dos features que resuelven lo mismo de dos maneras obligan a entender ambas.
2. **Monolito modular con vertical slices y núcleo hexagonal, optimizado para el bucle de un agente de IA.** Premisa de diseño: buena parte del código lo escribe y modifica un agente que no carga el proyecto entero ni recuerda conversaciones pasadas; trabaja con el contexto que se le pone delante y se autocorrige con las señales que recibe. Cada decisión estructural minimiza ese contexto y maximiza esas señales —tipos, tests, linters—. El cómo está en [la arquitectura por dentro](../arquitectura/01_explicacion-arquitectura-hexagonal.md).
3. **Lo que se despliega es una imagen inmutable; el entorno se inyecta.** La unidad de despliegue es una imagen Docker tageada por el SHA del commit, nunca `latest`. Configuración y secretos entran en runtime (Docker secrets en `/run/secrets`), nunca horneados en la imagen: la misma imagen corre en cualquier entorno, solo cambia lo inyectado. Detalle en [el modelo de operación](../operaciones/01_explicacion-modelo-operacion.md).

Las dos primeras gobiernan el desarrollo; la tercera, el despliegue. Las tres comparten una intención: que lo correcto sea lo más fácil, y que una máquina —no la memoria— haga que se cumpla.

## Convención sobre configuración

Un camino correcto, que es el de menor resistencia: un comando, un template, un default. Corolario que importa tanto como la regla: **la convención no vive en la prosa, sino en una herramienta que la impone** (Biome, tsc, dependency-cruiser, un template, `pnpm run check`). Lo que vive en un párrafo se ignora porque nada lo hace cumplir; lo que vive en un gate de CI, contrato de tipos o paso de pipeline se cumple solo.

## La arquitectura optimiza el bucle de la IA

Toda decisión minimiza a la vez el contexto que un agente sostiene para un cambio y el radio de daño de un error. Dos palancas: **localidad** (una feature es una carpeta; lo que cambia junto vive junto → carga poco) y **fronteras** (núcleo de dominio puro tras puertos → un error no pasa de su borde). El cómo, en [la arquitectura por dentro](../arquitectura/01_explicacion-arquitectura-hexagonal.md).

## Robusto no es máximo

Cada herramienta de más es deuda: algo que instalar, entender, mantener y depurar. La robustez viene de tener pocas piezas y entenderlas, no de acumularlas. Se extiende a infraestructura: un desplegable, un servidor, un orquestador. De ahí la regla hermana: **la complejidad se añade solo cuando aparece el dolor que la justifica.** El proyecto lo llama "el dial": la sofisticación se sube cuando el sistema lo pide, y cada decisión que hoy se posterga queda anotada en [su catálogo](#el-dial-complejidad-diferida), con el síntoma que la justificaría.

## Ceremonia proporcional al riesgo

Un cambio trivial (texto, estilo, campo) no pasa por el spec ni el ritual de sub-agentes; una feature de producción sí. La ceremonia es cara: gastarla donde no hay riesgo no compra seguridad. Tratar todo igual es el antipatrón más común del desarrollo asistido por IA. Misma economía en **calidad por unidad de esfuerzo**: se recorta la ceremonia cara que TypeScript tiende a encarecer y ese presupuesto se gasta en las pocas salvaguardas baratas que el desarrollo con IA sí necesita.

## El dominio puro es innegociable

La lógica de negocio no toca framework ni I/O; todo lo demás (Next.js, Drizzle, el cliente HTTP) es un detalle reemplazable del borde. Doble razón: (1) el dominio puro es donde la suite corre en milisegundos sin levantar BD —el bucle apretado donde el agente prueba, ve y corrige—; (2) un dominio que no depende de nada externo no se rompe cuando el borde cambia (otro ORM o framework lo deja intacto).

## El test antes que la implementación

El test rojo se escribe primero y define qué es "hecho": obliga a decidir qué se espera antes de poder racionalizar lo que el código ya hace. Con un agente, es además una especificación ejecutable de la intención que la máquina verifica sola.

## Los guardarraíles que importan son ejecutables

La conducta que no puede fallar se codifica como algo que se ejecuta: gate de CI, regla de linter, contrato de tipos, paso de pipeline. La frontera entre "lo deseable" y "lo obligatorio" es la frontera entre lo escrito en prosa y lo codificado en una herramienta. La pureza del dominio no es un consejo: es un gate de dependency-cruiser que rompe el build.

## Reproducibilidad de punta a punta

`pnpm-lock.yaml` fija las versiones exactas de cada dependencia; la imagen se tagea por SHA, nunca `latest`. Resultado: `pnpm run check` corre idéntico en tu máquina y en CI —mismos gates, mismas versiones, mismo veredicto—, cero deriva entre "me funciona a mí" y "funciona en el pipeline". Sin esa ausencia de deriva, las señales en que se apoya el agente no significarían nada.

## Alcance del proyecto

El proyecto cubre desarrollo **y** despliegue de punta a punta: servidor, contenedores, gates de CI, secretos, backups, **y también** la autenticación (Better Auth con email/password como piso — [Auth y sesión](../arquitectura/05_referencia-auth-y-sesion.md)) y el frontend (React Server Components + Tailwind — [Estilos de frontend](../arquitectura/06_explicacion-estilos-frontend.md)). Fuera del alcance base queda solo la observabilidad de producción profunda más allá de las librerías ya elegidas.

**El alcance se recorta por proyecto, no se infla.** La doctrina describe el slice y el stack COMPLETOS; un proyecto concreto **descarta** lo que su síntoma no pide — la regla es por síntoma inverso:

- **Sin usuarios ni sesiones** → sin `src/core/auth` (ni tablas de auth, ni derivadores de Actor).
- **Sin consumidores externos de API** → sin `route.ts`, sin registro OpenAPI, sin gate de Schemathesis.
- **Sin terceros a los que llamar** → sin `<provider>.adapter.ts` ni política de egreso activa (el contrato de dependency-cruiser queda, gratis).
- **Sin persistencia** → sin `table.ts` ni migraciones; el repositorio es un `Map` en memoria detrás del mismo puerto.
- **Sin UI** (una API pura, un worker) → sin `actions.ts`, sin doctrina de estilos.

Lo que NUNCA se descarta: el dominio puro tras puertos, `pnpm run check`, y la estructura de slice — son el piso, no opciones. Mantener este perímetro acotado es la primera aplicación del dial, no una omisión.

## El dial: complejidad diferida

El "dial" es la complejidad que el proyecto añade **solo cuando aparece el síntoma**, no antes. Es el corolario operativo de [robusto no es máximo](#robusto-no-es-máximo): cada herramienta de más es deuda, así que la sofisticación se sube cuando el sistema lo pide, y cada decisión que hoy se posterga queda anotada aquí con su disparador.

El dial no es una lista de tareas pendientes: ninguno de estos saltos es un retraso. Subirlo antes de tiempo sería el error. Cada entrada nombra el síntoma que justifica el salto, no una fecha.

### Desarrollo y arquitectura

| Disparador (el síntoma) | El salto |
|---|---|
| Una feature necesita empujar datos al cliente a medida que ocurren (progreso, notificaciones, actualizaciones en vivo) | SSE como feature deliberada: un Route Handler que devuelve un `ReadableStream` (giro barato; el I/O async ya es nativo, esto es la feature, no el I/O). |
| El push unidireccional del servidor ya no basta y hace falta un canal bidireccional persistente cliente↔servidor | WebSockets (salto mayor, no barato): rompe `output: standalone` y obliga a un servidor aparte. Por eso vive separado del giro barato de SSE. |
| El equipo crece y necesita fronteras duras que el tipo y `dependency-cruiser` no alcanzan a imponer dentro de un solo paquete | Workspace multi-paquete de pnpm. |
| Un módulo necesita escalar o desplegarse por separado de forma sostenida | Extraerlo del monolito modular a un servicio propio (no antes). |
| Un handler entrante (webhook) con inbox `processed_events` debe **además** producir un efecto externo —ese es el disparador **obligatorio**—, u otras partes del sistema reaccionan a eventos de una feature y necesitan entrega confiable | Patrón outbox transaccional: el efecto externo se encola en la **misma transacción** que el dedupe, no se dispara post-commit (donde un crash entre el commit y el efecto lo perdería). |
| Trabajo diferido o fan-out masivo que revienta el timeout del request (procesar lotes, abrir miles de efectos, tareas largas) | Outbox + colas/background jobs: un worker drena el trabajo fuera del ciclo del request. |
| El reporting cruza varias features y castiga las tablas transaccionales con queries pesadas | Read-model/CQRS: una proyección de lectura separada del modelo de escritura. |
| Una lectura cara se repite y su coste se vuelve visible | Caching escalado por niveles: `React cache()` (por request) → Next Data Cache (entre requests) → Redis como puerto (compartido entre instancias). |
| Aparece multi-tenancy real: varios tenants comparten base y hay que aislar sus filas a nivel de motor | Row-Level Security de PostgreSQL. Hasta que ese síntoma exista no se adelanta ni el `tenantId` en las primitivas: el seam queda nombrado, no engrosado. |
| RPC fuertemente tipado entre servicios, o un cliente que necesita modelar su propio grafo de datos | gRPC o GraphQL. |
| El dominio es crítico (pagos, salud, dinero) o el equipo maduró y quiere subir la barra; por defecto el mutation corre nightly como métrica | Mutation testing como GATE DE MERGE bloqueante (Stryker `break:100`). Por defecto Stryker es un job **nightly** y una **métrica** informativa de calidad de test que **no** rompe el merge; subirlo a gate de cada PR es ceremonia que un proyecto típico de agencia no necesita ([robusto no es máximo](#robusto-no-es-máximo)) —un mutante equivalente indecidible puede bloquear un PR—, por eso solo se difiere a este escalón cuando el dominio o la madurez del equipo lo justifican. |

### Borde, autenticación y observabilidad

| Disparador (el síntoma) | El salto |
|---|---|
| La autenticación necesita tokens portadores para clientes máquina, u organizaciones/equipos como entidad de primera clase | Plugins `bearer`/`organization` de Better Auth. El seam del actor máquina ya existe; esto es el proveedor concreto, no un cambio de las reglas de autorización. |
| El throttle/lockout básico por endpoint ya no alcanza y hace falta coordinar límites entre varias instancias | Motor distribuido de rate limiting (store compartido tipo Redis como puerto). El **límite básico por endpoint no es dial**: va desde el día uno en la auth humana (login, password-reset, fallos de verificación de credencial) y en los endpoints de máquina (API key/webhook), porque Argon2id protege contra cracking *offline* pero no contra brute-force/credential-stuffing *online*, que existe desde hoy. Solo el motor distribuido se difiere aquí. |
| Una URL de destino del cliente HTTP deriva de datos de usuario/tercero (no de constantes de config) | Activar el enforcement anti-SSRF del hook del `HttpClient` — la política completa (pinning de IP, redirects, rangos privados) vive en [Convenciones de código](../arquitectura/03_referencia-convenciones-codigo.md). **No es complejidad diferida**: el hook existe desde el día uno; este disparador solo lo enciende. |
| Un cambio incompatible en la API rompería a consumidores que no controlas | Versionado de la API (`/api/v1`). |
| Los logs estructurados y el reporte de errores ya no alcanzan para responder "cuánto" y "dónde tarda" | Métricas y tracing como tercer pilar de observabilidad (logs y errores ya están desde el día uno; esto suma el tercero). Distinto del monitoreo base de recursos del host, que es precondición y no dial. |
| Un proveedor de tercero cambia su contrato sin avisar y rompe la integración en silencio | Contract testing del proveedor consumido: cassettes grabadas en la suite rápida + una corrida nightly contra el proveedor real. |

### Infraestructura y despliegue

| Disparador (el síntoma) | El salto |
|---|---|
| Prod tiene datos o usuarios que no puedes perder, o una migración te pone nervioso, o se prende auto-deploy en cada merge y quieres un escalón entre "mergeado" y "en vivo" | Staging (`test-${APP}.<dominio>`). El riel ya está en `deploy.sh`/`ci.yml`: encenderlo es provisionar el segundo túnel y correr `./deploy.sh test` una vez. |
| Prod no tolera compartir host (CPU/RAM/disco/kernel) con test | Server dedicado para staging. Mover staging a otro VPS es trivial: otro context, el mismo `deploy.sh`. |
| Hay más de un servicio que correlacionar y hace falta seguir una misma request a través de varios procesos | Tracing distribuido (OpenTelemetry + Grafana/Tempo). Es caro y multi-servicio: un salto del dial, distinto del monitoreo base de recursos del host (ver abajo), que no se difiere. |
| Forwarding de la IP real del cliente o ruteo fino por dentro del swarm | Reverse proxy interno (Traefik). Cloudflare Tunnel ya cubre el ingreso; esto es un escalón posterior. |
| Límite de conexiones de PostgreSQL bajo carga | Pooling (PgBouncer). |
| El monitoreo base de recursos del host cruza de forma sostenida su umbral de warn (RAM o disco >80 %, conexiones de PostgreSQL cerca del techo, p95 de latencia degradado) y ya no queda headroom en un solo nodo | Swarm multi-nodo (cluster). El síntoma se lee del monitoreo base, no de una impresión cualitativa de "no alcanza". |
| Crecimiento real de infraestructura | Kubernetes (k3s). |
| Aparece una flota o un grafo de recursos interdependientes que pide un `plan` revisable + detección de drift, y `hcloud` + scripts bash idempotentes ya no modelan la dependencia entre recursos | Terraform/OpenTofu/Pulumi como IaC declarativa. **NOTA: en un nodo único *aumenta* el riesgo**, porque el state file permite que `apply` destruya recursos para converger; mientras la gestión vía la API de Hetzner alcance ([gestionar infra vía API](../operaciones/12_how-to-gestionar-infra-via-api.md)), subir este escalón añade un modo de fallo destructivo en vez de quitarlo. |
| Un consumidor externo allowlistea la IP de egress, o se publica un `A` record FUERA del túnel saliente | Floating IP de Hetzner. Con Cloudflare Tunnel saliente la IP del server no es punto de estabilidad de la app; es facturable y exige ruteo en el host, así que solo entra cuando algo externo fija la IP. |
| Multi-nodo con distribución L4 **y** abandono del modelo de túnel saliente | Load Balancer gestionado de Hetzner. Cloudflare ya hace TLS/WAF/rate-limit al borde; un LB duplica el plano de ingreso y reabre inbound facturable, por eso exige las dos condiciones a la vez. |
| Ransomware, exigencia de compliance, o un RPO < 24 h que el destino restic off-site no cubre | Object Storage S3 + Object Lock (WORM). Para una operación chica, Storage Box SFTP con append-only y retención pineada alcanza ([backups](../operaciones/09_how-to-backups.md)); el WORM entra cuando la inmutabilidad es un requisito y no una práctica. |
| Salto a multi-nodo donde los peers del Swarm deben hablar por IP privada (2377/7946/4789) | Private Network de Hetzner. Un nodo único no la necesita: nace con el cluster, no antes. |

### El monitoreo base de recursos no es dial: es su precondición

Casi todos los disparadores de infraestructura se leen de una sola fuente: los recursos del host. Saber cuándo un nodo dejó de alcanzar, cuándo el disco se está llenando o cuándo PostgreSQL se acerca a su techo de conexiones exige un instrumento que mire CPU, RAM, disco y conexiones de forma continua. Sin ese instrumento, cada fila de la tabla de infraestructura se vuelve cualitativa ("parece que no alcanza") en lugar de observable, y el salto más caro del sistema —el multi-nodo— se decide a ciegas.

Por eso el monitoreo de recursos del host **no es un salto del dial: es la precondición para leer cualquier otro disparador de infra**, y va desde el día uno. El mínimo obligatorio —timer + script + webhook— y sus umbrales (warn >80 %, crit >90 %) viven en [Seguridad operativa](../operaciones/10_referencia-seguridad-operativa.md#monitoreo-mínimo-obligatorio-vs-dial).

Esto es distinto del **tracing distribuido** (OpenTelemetry, fila de arriba): el tracing es caro, multi-servicio y correlaciona una request entre procesos; el monitoreo base solo vigila la salud del nodo. El tracing es dial; el monitoreo base es el instrumento que deja leerlo.

### Lo que ya se tiene sin subir el dial

- Blue-green y rolling updates (`order: start-first`).
- Rollback automático y manual.
- Secrets cifrados.
- Logs estructurados JSON (pino).
- Reporte de errores (Sentry).
