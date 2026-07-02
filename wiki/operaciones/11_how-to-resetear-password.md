---
id: ops.resetear-password
titulo: Resetear la contraseña de un usuario
tipo: how-to
tier: 3
audience: both
resumen: Procedimiento break-glass para resetear la contraseña de un usuario ejecutando un ES module inline dentro del contenedor.
provides:
  - "procedimiento break-glass de reseteo de contraseña"
  - "ejecución de un ES module inline en el contenedor"
  - "reutilización del hasher Argon2id en el break-glass"
  - "pg.Client (conexión directa ad-hoc)"
  - "UPDATE de hash de contraseña por email con chequeo de rowCount"
  - "verificación end-to-end vía endpoint de sign-in"
  - "canal seguro para comunicar la contraseña temporal"
reads-before: [arq.auth, ops.secretos, ops.desplegar-swarm]
related: [arq.auth]
---

# Resetear la contraseña de un usuario (break-glass)

Establece una nueva contraseña cuando el reset por email no está disponible. **Procedimiento de emergencia**: si el reset por email funciona, preferilo siempre.

El hash se genera y verifica **dentro del contenedor `app`**, reutilizando el mismo hasher Argon2id que expone el módulo de auth (ver [Autenticación y sesión](../arquitectura/05_referencia-auth-y-sesion.md)). Garantiza compatibilidad con la verificación de credenciales en el login sin herramientas externas.

---

## Norma

Regla portable, independiente del esquema de cada proyecto:

1. **Reseteo desde adentro del contenedor.** El hash debe producirse con el mismo hasher Argon2id que usan el alta y el login normales. Generarlo fuera del contenedor o con otra librería puede producir un formato que la verificación de la app no reconozca. Por eso el procedimiento ejecuta un ES module **inline** dentro del contenedor `app` (`node --input-type=module -`), importando el hasher desde el módulo de auth.

2. **Conexión directa ad-hoc, no el pool de la app.** Para una operación puntual de emergencia se abre una conexión `pg.Client` directa contra la base, leyendo la cadena de conexión desde el secret montado en `/run/secrets/<clave-secret>` (ver [Secretos](07_referencia-secretos.md)). No se reutiliza el pool de la aplicación: es una intervención fuera del flujo normal.

3. **UPDATE por email, con chequeo de `rowCount`.** El reseteo es un `UPDATE` sobre la columna de hash de la tabla de usuarios filtrando por email. **Siempre** se verifica `rowCount`: `0` significa que el email no coincide con ningún registro (no que el reseteo "funcionó silenciosamente"). Evita comunicar una contraseña que no se asignó a nadie.

4. **Verificación end-to-end obligatoria.** Tras el `UPDATE` se valida la compatibilidad del hash de dos maneras: dentro del contenedor (`verify` del propio hasher) y, sobre todo, contra el endpoint de sign-in real. No se cierra el reseteo hasta que un login efectivo devuelve `200`.

5. **Comunicación por canal seguro.** La contraseña temporal se entrega por canal seguro y se indica al usuario que la cambie al ingresar. Nunca se imprime ni se deja en logs persistentes.

> **Por qué importa la compatibilidad del hasher:** al importar el hasher Argon2id de la app dentro del contenedor, el hash se genera con los mismos parámetros que el flujo de registro y la verificación en el login usa la misma función. Un hash con parámetros distintos pasaría el `UPDATE` pero fallaría silenciosamente en el siguiente login.

---

## Camino verificado

Sustituí los placeholders por los valores de tu entorno:

- `<ctx>` — contexto Docker del entorno objetivo (por convención `${APP}-prod`; ver [Desplegar el stack en Swarm](06_how-to-desplegar-swarm.md)).
- `<stack>` — nombre del stack desplegado.
- `<clave-secret>` — nombre `target` del secret con la cadena de conexión a la base, montado en `/run/secrets/`.
- `<tabla-usuarios>` — tabla de usuarios de tu esquema.
- `<columna-hash>` — columna que almacena el hash de la contrasena.
- `<endpoint-signin>` — endpoint de autenticación por email/password de tu app.
- `<host>` — hostname público del entorno.

### Antes de empezar

- Tenés acceso al contexto Docker del entorno (`<ctx>`).
- Tenés el email del usuario afectado.
- Tenés una contraseña temporal para asignarle.
- Tenés el ID del contenedor `app` corriendo (`<app_ctr>`). Para obtenerlo:

```bash
docker -c <ctx> ps -q \
  --filter "label=com.docker.swarm.service.name=<stack>_app" \
  --filter "status=running" | head -1
```

### 1. Ejecutar el reseteo dentro del contenedor

```bash
docker -c <ctx> exec -i <app_ctr> node --input-type=module - <<'EOF'
import { readFileSync } from "node:fs";
import pg from "pg";
// El hasher Argon2id que expone el modulo de auth de la app:
// mismos parametros que usa el alta y el login normales.
import { passwordHasher } from "@/core/auth";

// Leer la cadena de conexion desde el secret montado.
const databaseUrl = readFileSync("/run/secrets/<clave-secret>", "utf8").trim();

const EMAIL = "<email-del-usuario>";
const NEW_PASSWORD = "<contrasena-temporal>";

const newHash = await passwordHasher.hash(NEW_PASSWORD);

const client = new pg.Client({ connectionString: databaseUrl });
await client.connect();
try {
  const result = await client.query(
    "UPDATE <tabla-usuarios> SET <columna-hash> = $1 WHERE email = $2",
    [newHash, EMAIL],
  );
  console.log(`Filas actualizadas: ${result.rowCount}`);
} finally {
  await client.end();
}

// Verificar compatibilidad del hash con la verificacion Argon2id de la app.
console.log("Verificacion:", await passwordHasher.verify(newHash, NEW_PASSWORD));
EOF
```

Salida esperada:

```
Filas actualizadas: 1
Verificacion: true
```

Si `Filas actualizadas` es `0`, el email no coincide con ningún registro en `<tabla-usuarios>`. Revisa el email antes de volver a intentar.

### 2. Verificar el login end-to-end

```bash
curl -s -X POST https://<host>/<endpoint-signin> \
  -H 'Content-Type: application/json' \
  -d '{"email": "<email-del-usuario>", "password": "<contrasena-temporal>"}' \
  -o /dev/null -w '%{http_code}\n'
```

Una respuesta `200` confirma que el hash quedó almacenado correctamente y que la autenticación funciona end-to-end.

### 3. Comunicar la contrasena temporal al usuario

Envía la contraseña temporal por canal seguro e indícale que la cambie al ingresar.
