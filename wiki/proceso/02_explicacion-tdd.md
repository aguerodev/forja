---
id: proc.tdd
titulo: TDD como método
tipo: explicacion
tier: 1
audience: both
resumen: Definición conceptual de Test-Driven Development y por qué el proyecto lo usa para desarrollo asistido por IA.
provides:
  - "Test-Driven Development (TDD) (definición conceptual)"
  - "ciclo rojo-verde-refactor"
  - "el test rojo define qué es \"hecho\""
  - "especificación ejecutable de la intención (TDD en contexto de IA)"
reads-before: [fund.principios]
related: []
---

# Qué es TDD y por qué este proyecto lo usa

Test-Driven Development (desarrollo guiado por tests): el test se escribe antes que la implementación.

## Qué es

El ciclo es rojo-verde-refactor. Primero se escribe un test que falla (rojo) porque el código que describe aún no existe; ese test rojo define qué es "hecho", al obligar a decidir qué se espera antes de escribir el código. Luego se implementa lo mínimo para que pase (verde). Por último se refactoriza con la red de seguridad del test en verde. El test no es verificación posterior: es la especificación que precede al código.

Un ciclo mínimo — **ejemplo ilustrativo en JavaScript**, no una prescripción de stack (el lenguaje y el runner concretos los define el stack de cada proyecto):

```js
// rojo: el test define el comportamiento esperado antes de que exista la funcion
test("calcularTotal suma los importes de cada item", () => {
  const items = [{ importe: 10 }, { importe: 5 }, { importe: 3 }];
  expect(calcularTotal(items)).toBe(18);
});
```

```js
// verde: lo minimo para pasar el test
function calcularTotal(items) {
  return items.reduce((acc, item) => acc + item.importe, 0);
}
```

La función existe porque el test la exige, no al revés. Lo que el test declara —nombre, firma, contrato— es la especificación.

## Por qué este proyecto lo usa

Escribir el test primero obliga a decidir el comportamiento esperado antes de poder racionalizar lo que el código ya hace. Con un agente de IA hay una razón añadida: el test es una **especificación ejecutable de la intención** que la máquina verifica sola, sin esperar a un humano. Cierra el bucle de autocorrección —el agente prueba, ve el resultado y corrige— que hace fiable el desarrollo asistido. Es uno de los [principios del proyecto](../fundamentos/01_explicacion-principios.md#el-test-antes-que-la-implementación).

El cómo concreto —la pirámide de tests, los tests negativos de autorización, y por qué la cobertura y el mutation score son métricas (el mutation corre nightly, no bloquea el merge)— es doctrina del stack de cada proyecto; el comando que lo ejecuta es `commands.test` del contrato. Este documento no lo repite.
