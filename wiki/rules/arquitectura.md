# Arquitectura

- El dominio puro es innegociable: los archivos de dominio y puertos solo importan su propio dominio y utilidades puras compartidas (allowlist) — nada de framework, ORM, driver de base, SDKs ni builtins con I/O.
- Organizá por vertical slices con núcleo hexagonal: una feature = una carpeta autocontenida.
- Cruzá entre features SOLO por su API pública declarada: los internos de otra feature quedan sellados.
- Pasá toda integración de tercero por un puerto + adaptador que consume el cliente HTTP central del proyecto — las primitivas de red crudas quedan prohibidas fuera de ese cliente.
- Traducí todo error de proveedor a un error de dominio en el adaptador: el SDK, la firma y los tipos del proveedor nunca salen del adaptador.
- El linter de dependencias que impone estas fronteras no se negocia: si falla, corregí el diseño, nunca el linter.

Doctrina: wiki/fundamentos/01_explicacion-principios.md
