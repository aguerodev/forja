---
id: fund.glosario
titulo: Glosario de términos
tipo: referencia
tier: 0
audience: both
resumen: Índice alfabético curado de términos transversales, cada uno con definición de una frase y enlace a su fuente canónica; el índice exhaustivo máquina-legible es el MANIFIESTO.
provides:
  - "glosario maestro (índice alfabético de términos con enlace a la fuente canónica)"
  - "convención de glosario (definición en una frase + puntero al doc que lo desarrolla)"
reads-before: []
related: [arq.hexagonal]
---

# Glosario de términos

Índice alfabético **curado** de los términos transversales del proyecto, pensado para humanos — no es exhaustivo: el índice exhaustivo máquina-legible (tema → doc dueño) es el [MANIFIESTO](../MANIFIESTO.md). Es **solo un índice**: no desarrolla la doctrina, redirige a la fuente canónica donde cada término se explica en detalle.

## Convención de glosario

Cada entrada respeta el mismo formato:

- **Definición en una frase**: una sola oración que captura el término, sin desarrollarlo.
- **Puntero a la fuente canónica**: un enlace al documento donde el término se define y se desarrolla.

Si un término necesita más de una frase, la frase extra vive en su fuente canónica, no acá: el glosario nunca es la fuente de verdad, siempre apunta al documento que lo desarrolla.

## Adaptador

Pieza del borde que implementa un puerto sobre una tecnología concreta (p. ej. el repositorio que cumple el puerto definido por el dominio). [Arquitectura por dentro](../arquitectura/01_explicacion-arquitectura-hexagonal.md#qué-hace-cada-archivo)

## Arquitectura hexagonal

Regla de puertos y adaptadores: el dominio en el centro no conoce el exterior, y el exterior se conecta a él por puertos, con las dependencias apuntando siempre hacia adentro. [Arquitectura por dentro](../arquitectura/01_explicacion-arquitectura-hexagonal.md#tercera-decisión-dentro-de-cada-feature-un-núcleo-hexagonal)

## Cloudflare Tunnel

Conexión saliente que `cloudflared` abre hacia Cloudflare para servir la app sin abrir puertos entrantes; es *remotely-managed* (su configuración vive en Cloudflare y el conector solo necesita un token). [Exponer con Cloudflare Tunnel](../operaciones/05_how-to-exponer-cloudflare-tunnel.md)

## Punto de composición

Único lugar de la feature donde las piezas concretas se conocen: en el slice base es `service.ts` (pre-cablea el adaptador en los use cases); un `composition.ts` con factories y `withTransaction` se extrae solo por el dial. [Arquitectura por dentro](../arquitectura/01_explicacion-arquitectura-hexagonal.md#qué-hace-cada-archivo)

## Deny-by-default (scopes)

Modelo de autorización en que todo está denegado salvo lo que un scope concede explícitamente. [Convenciones de código](../arquitectura/03_referencia-convenciones-codigo.md#6-autorización)

## Dial (el)

Complejidad que se añade solo cuando aparece el síntoma que la justifica; cada decisión postergada queda anotada como sofisticación futura. [Principios del proyecto](01_explicacion-principios.md#robusto-no-es-máximo)

## Docker secret

Valor sensible cifrado en el swarm (en reposo y tránsito) y montado como archivo en `/run/secrets/` dentro del contenedor, nunca como variable de entorno ni horneado en la imagen. [Secretos](../operaciones/07_referencia-secretos.md)

## Docker Swarm

Orquestador de contenedores de Docker que despliega y reconcilia el stack sobre el nodo. [Modelo de operación](../operaciones/01_explicacion-modelo-operacion.md)

## Dominio puro

Lógica de negocio que no toca framework ni I/O, donde la suite corre en milisegundos y que no se rompe cuando cambia el borde. [Principios del proyecto](01_explicacion-principios.md#el-dominio-puro-es-innegociable)

## Expand/contract

Disciplina de migración destructiva en dos deploys: se agrega lo nuevo en uno, se migra el código, y se borra lo viejo en un deploy posterior, para que las dos versiones convivan sin romperse durante el rolling. [Pipeline de CI/CD](../operaciones/08_how-to-pipeline-cicd.md#disciplina-de-migración-expandcontract)

## GHCR

GitHub Container Registry; hoy no se usa —la imagen se construye en el propio nodo— y queda como entrada del dial para cuando el build deje de ocurrir en la máquina que despliega. [Modelo de operación](../operaciones/01_explicacion-modelo-operacion.md#ghcr-entrada-del-dial-no-default)

## Healthcheck

Chequeo de `/health` que el compose ejecuta y del que depende el rollback automático del deploy. [Modelo de operación](../operaciones/01_explicacion-modelo-operacion.md)

## Ingress

Regla de enrutamiento del túnel que mapea un hostname a un servicio (`http://app:3000`) y que debe terminar con un catch-all `404` obligatorio. [Exponer con Cloudflare Tunnel](../operaciones/05_how-to-exponer-cloudflare-tunnel.md)

## Monolito modular

Un único desplegable con fronteras internas fuertes entre módulos: por fuera es uno, por dentro está cortado en módulos que no se entrometen entre sí. [Arquitectura por dentro](../arquitectura/01_explicacion-arquitectura-hexagonal.md#primera-decisión-un-monolito-no-microservicios)

## Puerto

Interfaz TypeScript (`interface`) que el dominio define para lo que necesita del exterior, sin conocer su implementación. [Arquitectura por dentro](../arquitectura/01_explicacion-arquitectura-hexagonal.md#qué-hace-cada-archivo)

## Red overlay

Red interna del swarm que conecta los servicios del stack y los resuelve entre sí por su nombre de servicio. [Modelo de operación](../operaciones/01_explicacion-modelo-operacion.md)

## Rolling update

Actualización del servicio que reemplaza réplicas de forma progresiva en lugar de todas a la vez. [Pipeline de CI/CD](../operaciones/08_how-to-pipeline-cicd.md)

## Servicio

Pieza del stack que el swarm corre con un número de réplicas; su nombre es además su nombre de red en la overlay. [Modelo de operación](../operaciones/01_explicacion-modelo-operacion.md)

## Stack

Conjunto declarado en `stack.yml` que reúne servicios, red y secrets como una unidad y se materializa con un comando. [Modelo de operación](../operaciones/01_explicacion-modelo-operacion.md)

## Start-first

Orden de actualización en que el swarm arranca la réplica nueva antes de bajar la vieja, sin caída del servicio. [Modelo de operación](../operaciones/01_explicacion-modelo-operacion.md)

## Vertical slice

Feature organizada como módulo autocontenido por contexto de negocio (no por capa técnica), con todo su código en una carpeta. [Arquitectura por dentro](../arquitectura/01_explicacion-arquitectura-hexagonal.md#segunda-decisión-organizar-por-feature-no-por-capa)
