---
id: arq.testing
titulo: Testing aplicado del stack
tipo: explicacion
tier: 2
audience: both
resumen: La pirámide de cinco capas, los tests negativos de autorización, el antipatrón de mocks felices y por qué la cobertura y el mutation score son métricas (el mutation corre nightly, no es gate de merge).
provides:
  - "pirámide de tests (cinco capas dominio -> property-based -> integración -> contrato de API -> E2E)"
  - "tests negativos de autorización (actorWithout(permission) + it.each)"
  - "mocks felices mienten (antipatrón)"
  - "doble de test (vocabulario de fakes/mocks)"
  - "enumeration leak (antipatrón de seguridad)"
  - "dogfooding / verificar antes que confiar"
  - "garantía de privacidad (una operación con garantía no se rompe por un fallo de adaptador)"
  - "métrica vs gate (coverage-v8 y mutation score son métricas informativas; el gate de merge lo dan tsc/biome/dependency-cruiser/vitest/audit)"
  - "mutation score como métrica de calidad (job nightly)"
  - "Stryker --since (mutation incremental acotada al diff; corre como job nightly)"
  - "contract test del puerto (it.each sobre [fake, adaptador], misma batería en éxito y fallo traducido; helper portThatFails)"
  - "puente de tipos compile-time dominio<->schema (aserción z.input en schemas.ts que no compila si el schema deja de cubrir la entidad)"
  - "mutation extendido al adaptador de egreso (métrica, no gate)"
  - "contrato del proveedor consumido (sexta capa del dial: cassettes MSW/nock versionadas + job nightly, mock-from-spec con Prism, Pact)"
reads-before: [proc.tdd, arq.hexagonal]
related: [fund.stack]
---

# Cómo se prueba el proyecto: la pirámide de tests aplicada

Qué capa cubre qué duda, por qué la autorización exige tests negativos, por qué la cobertura y el mutation score son métricas (el mutation corre como job nightly, no como gate de merge). Hilo conductor: el **bucle de feedback**, lo que hace fiables al TDD y al desarrollo asistido por IA. Que el test rojo vaya primero es uno de los [principios del proyecto](../fundamentos/01_explicacion-principios.md#el-test-antes-que-la-implementación); aquí ese principio se reparte en capas.

## La pirámide

De más rápida y abundante a más lenta y escasa, cada capa resuelve un tipo de duda distinto:

- **Dominio y casos de uso (la mayoría).** Vitest puro, sin I/O, milisegundos, con fakes en memoria de los puertos. El bucle apretado donde la IA y el TDD rinden mejor: **intocable, rápido y puro.** Si se enreda con la infraestructura y se vuelve lento, la autocorrección muere.
- **Property-based (fast-check).** Para invariantes del dominio. Bajo esfuerzo, encuentra los casos límite que los ejemplos escritos a mano no cubren. **Estado real (honesto):** la dependencia está instalada pero aún no hay tests property-based — es entrada del dial; disparador: el primer invariante de dominio cuyo espacio de entradas los ejemplos manuales no cubren.
- **Integración.** Repositorios contra una PostgreSQL real y efímera vía `testcontainers-node` — **un contenedor por suite** (en `beforeAll`), con datos propios por test. **La escalación** (contenedor único a nivel de sesión + cada test dentro de una transacción que se revierte) es dial; disparador: la primera flakiness cruzada entre tests o una suite que supere el minuto.
- **Contrato de API (Schemathesis).** Fuzzea la API contra su propio esquema OpenAPI 3.1 —el que genera `zod-to-openapi`—; captura incompatibilidades semánticas que un snapshot no ve.
- **E2E (Playwright).** Login y el flujo de negocio principal en un navegador real. **Estado real (honesto):** instalado, sin tests aún — dial; disparador: el primer flujo crítico cuyo breakage ninguna capa inferior atrape.

## Tests negativos de autorización

Convención: un helper estándar `actorWithout(permission)` construye un actor al que le falta un permiso concreto. Por cada permiso, un caso parametrizado con `it.each` verifica que ese actor es rechazado **antes** de cualquier cambio de estado. Sin tests negativos, la autorización se pudre en silencio: un permiso que dejó de comprobarse no rompe ningún test que solo mire el camino feliz. El test negativo afirma lo que de verdad importa de una guarda —que **rechaza**— y conecta con la [convención de autorización](./03_referencia-convenciones-codigo.md#6-autorización).

## Los mocks felices mienten

Un doble de test que solo modela el camino feliz da una falsa sensación de seguridad. Caso típico: una operación depende de un puerto externo (notificaciones, pagos, correo) y sus dobles **siempre devuelven éxito**. La suite queda en verde, pero ninguna prueba ejercita el **camino de fallo** de esa dependencia.

El bug que tapa es real. Una operación con **garantía de privacidad** —un "olvidé mi contraseña" que debe responder idéntico exista o no la cuenta, para no revelar quién está registrado—. Si el adaptador del proveedor falla y la operación deja subir esa excepción **sin capturar** hasta el borde HTTP, se traduce en un HTTP 500. El patrón de respuestas entonces filtra información: una cuenta inexistente responde con el código de éxito y una registrada responde 500. El **status code** distingue qué identificadores tienen cuenta: un **enumeration leak** de seguridad. La suite no lo caza —todos sus dobles enviaban con éxito—; lo caza el **dogfooding**, alguien que usa el sistema de verdad y dispara el camino que las pruebas nunca ejercieron. Es el *verificar > confiar* en acción.

La regla hexagonal: el **puerto** define la operación, así que el test debe cubrir el éxito y la **falla del adaptador**. Inyectar dobles que **fallan** —que lanzan la excepción del puerto— y afirmar que el sistema se comporta bien. Como el puerto es una `interface` de TypeScript, el fake que falla es otra implementación de esa misma interfaz: el service no nota la diferencia. Los fallos de infraestructura (proveedor caído, timeout) son parte del **contrato**, no un caso exótico. Un doble que nunca falla prueba la mitad del puerto y esconde la otra mitad.

## Una garantía no puede romperse por un fallo de adaptador

Del bug anterior sale un patrón. Una operación con **garantía de privacidad** —que debe responder idéntico exista o no el dato, para no filtrar quién tiene cuenta— no puede dejar que un fallo del adaptador rompa esa garantía. La solución hexagonal reparte la responsabilidad:

- El **adaptador** traduce la excepción específica del proveedor a una excepción del **dominio** (por ejemplo, un `DeliveryError` dentro de la jerarquía `DomainError`). El dominio y el servicio nunca importan la librería del proveedor; ven solo el error del puerto.
- El **servicio** captura la excepción del dominio, la **loguea** server-side con `pino` (sin exponer nada al cliente) y devuelve la misma respuesta genérica de siempre.

Resultado: el fallo del adaptador queda en los logs como WARNING, el usuario ve la respuesta normal, y no hay fuga por status code. El patrón normativo de traducción de errores está en la [convención de manejo de errores](./03_referencia-convenciones-codigo.md#7-manejo-de-errores).

## Contract test del puerto: una sola batería para el fake y el adaptador

El fake en memoria y el adaptador real son **dos implementaciones de la misma `interface`**. Si solo se prueba el fake, el camino feliz queda verde pero la lógica más frágil de la integración —parseo de la respuesta, traducción de la excepción del proveedor a `DomainError`, manejo de timeout— vive en el adaptador y nadie la ejercita. La defensa: un **contract test del puerto**, una batería de aserciones parametrizada con `it.each` sobre `[fake, adaptador]` que corre **idéntica** contra cada implementación y exige el mismo comportamiento observable en éxito **y** en el fallo traducido a `DomainError`.

```ts
// el contrato que TODA implementación del puerto debe cumplir
function notifierContract(make: () => Notifier) {
  it('entrega el mensaje en el camino feliz', async () => {
    await expect(make().send(message)).resolves.toBeUndefined();
  });

  it('traduce el fallo del proveedor a DeliveryError del dominio', async () => {
    // cada implementación arma su fallo: el fake lo simula,
    // el adaptador real corre contra un HttpClient que rechaza
    await expect(make().send(poison)).rejects.toBeInstanceOf(DeliveryError);
  });
}

it.each([
  ['fake en memoria', () => new InMemoryNotifier()],
  ['adaptador real', () => new HttpNotifierAdapter(failingHttpClient)],
])('%s cumple el contrato del puerto', (_name, make) => notifierContract(make));
```

El fake corre en microsegundos en la capa unit; el adaptador real corre en la capa de integración contra un mock-server determinista (doctrina de la pirámide). Misma batería, dos velocidades: vuelve **barato y verificable** el swap de proveedor.

Para el lado **consumidor** del puerto —el service que orquesta la degradación— hay un helper estándar análogo a `actorWithout(permission)`: `portThatFails`. Construye un doble del puerto cuya operación **siempre lanza** la excepción del dominio, sin escribir una clase de fake nueva por cada caso de fallo.

```ts
// helper estándar: un doble del puerto cuya operación rechaza con un DomainError
function portThatFails<P>(method: keyof P, error: DomainError): P {
  return { [method]: () => Promise.reject(error) } as P;
}

// uso: inyectar el fallo y afirmar que el service NO filtra ni rompe la garantía
const service = new Service({ notifier: portThatFails<Notifier>('send', new DeliveryError()) });
await expect(service.requestReset(email)).resolves.toEqual(genericResponse);
```

Así, igual que cada permiso exige su test negativo, **cada puerto externo exige su caso `it.each` de "adaptador que lanza"**: es la mitad del puerto que un agente tiende a no escribir.

### Puente de tipos compile-time entre dominio y schema

El contract test cubre el comportamiento en runtime; el **drift de forma** entre la entidad de dominio y el schema de salida lo ataja `tsc` antes de correr un test. La dirección de import permitida es `schemas.ts -> domain.ts` (el schema conoce al dominio, nunca al revés), así que el puente vive en `schemas.ts`: una aserción de tipo que **no compila** si el schema deja de cubrir la entidad.

```ts
// schemas.ts — puede importar domain.ts (dirección permitida)
import type { Counter } from './domain';
import { z } from 'zod';

export const CounterView = z.object({ id: z.string(), value: z.number().int() });

// puente compile-time: si CounterView deja de cubrir Counter, esto deja de compilar
type _Bridge = Counter extends z.input<typeof CounterView> ? true : never;
```

No es un test que se ejecuta: es un gate de tipos. Cambiás `domain.ts`, el schema queda desfasado, y la compilación falla en el PR sin necesidad de recordar actualizar el contrato.

## Métrica vs gate

Es la defensa más barata contra los tests verosímiles pero huecos que tiende a generar la IA. La **cobertura de líneas es gameable**: un porcentaje alto no prueba calidad, y un agente la infla con tests que ejecutan código sin afirmar nada. Por eso `coverage-v8` es **métrica informativa, no gate**: sirve para ver, no para bloquear.

El **mutation score (Stryker)** es la otra cara de esa misma moneda: mide si los tests de verdad afirman algo —si detectan una mutación, valen; si la mutación sobrevive, el test no afirmaba nada real—. Pero **también es una métrica, no un gate de merge**. Corre como **job nightly** sobre los `domain.ts`/`service.ts`, incremental (`--since`) para quedar rápido y apuntando a lo crítico, y **reporta** el score sin romper PRs. La razón es de calibración: un mutante equivalente indecidible no debería poder bloquear un merge, y un `break:100` en cada PR es ceremonia que un proyecto típico de agencia no necesita —**robusto no es máximo**—.

El **gate de PR** —lo que bloquea el merge— vive en otro lado y es determinista y verificable: `tsc --noEmit` (strict), Biome, dependency-cruiser (los seis contratos), Vitest (los proyectos unit **e** integración pasan) y `pnpm audit`. La calidad-de-test la **informa** el mutation nightly; el bloqueo lo dan los contratos que no dependen de un juicio sobre mutantes equivalentes.

Subir el mutation testing de vuelta a **gate de merge bloqueante (`break:100`)** es una **escalación consciente del dial**, no el default. Su disparador es un **dominio crítico** o un **equipo maduro** que justifique pagar esa ceremonia en cada PR; fuera de ese caso, queda como métrica nightly.

Dónde **mirar** la calidad-de-test tampoco arranca y termina en `domain.ts`/`service.ts`. El **adaptador de egreso** (`<proveedor>.adapter.ts`) es el código de **mayor riesgo de la integración** —parseo del DTO del proveedor, traducción `excepción del proveedor -> DomainError`, manejo del `timeout`— y es justo lo que un agente escribe a ciegas. El contract test del puerto le da **comportamiento** verificado, pero por defecto Stryker solo muta `domain.ts`/`service.ts`, así que el adaptador no recibe **señal de mutation** en el nightly: el agujero que el contract test cierra en comportamiento queda abierto en calidad-de-test.

Por eso la **señal de mutation se extiende al adaptador** —y la **cobertura sobre el adaptador se trata como métrica informativa**, no como gate—. Dos formas, en orden de preferencia:

- **(a) Extraer el mapeo a un `mapper.ts` puro.** La traducción "DTO del proveedor -> entidad" y "excepción del proveedor -> `DomainError`" sale a un módulo **puro** adyacente al dominio. Cae bajo el `mutate` actual sin tocar la config, mantiene el adaptador delgado y le da mutation score real al núcleo frágil. Convierte el riesgo en código puro y testeable: la opción que mejor respeta el dial.
- **(b) Cuando el mapeo no puede salir del adaptador** —porque está genuinamente acoplado al transporte—, ampliar el glob de Stryker para incluir `<proveedor>.adapter.ts` en el nightly. Si mutar ahí resulta demasiado lento, el piso es una **cota de cobertura sobre el adaptador** que se **reporta** junto al resto: los caminos de parseo y traducción quedan a la vista, aunque su bloqueo no sea parte del gate de PR.

Lo que **no** conviene es dejar el adaptador sin ninguna señal de calidad-de-test, porque concentra el riesgo de integración que el resto de la pirámide no toca.

## DIAL: contrato del proveedor consumido (sexta capa)

> **Escalación consciente — NO es default.** El contract test del puerto verifica que NUESTRA creencia sobre la API del proveedor es internamente consistente; el fake del puerto **codifica esa creencia**. Cuando el tercero cambia el shape de su respuesta, el fake no cambia y la suite sigue en verde: el mismo antipatrón de "los mocks felices mienten", ahora al nivel del adaptador.

**Disparador:** una integración saliente cuyo proveedor evoluciona su API fuera de nuestro control y cuyo breakage en producción es caro (pagos, ERP, envíos). Recién ahí se justifica la **sexta capa** —el *contrato del proveedor consumido*—, barata y **no bloqueante** (estilo nightly), no parte del gate del PR:

- **Cassettes versionadas.** Respuestas reales capturadas del sandbox del proveedor (MSW/nock como interceptor determinista), versionadas en el repo y usadas para construir el fake del puerto. Un job **nightly** re-captura contra el sandbox y **falla si el shape divergió**: alarma temprana de que la realidad del proveedor se movió.
- **Mock desde el spec.** Si el proveedor publica OpenAPI, levantar un mock con Prism desde **ese** spec y correr el adaptador contra él.
- **Contract consumer-side.** Para integraciones bidireccionales con un equipo dueño del proveedor, evaluar Pact.

Documentado como dial: la herramienta del área (MSW/nock + cassettes, Prism para mock-from-spec) queda **nombrada** para que activarla sea una decisión consciente con su disparador, no una improvisación por feature ni un peso permanente en el bucle de feedback.
