# Secrets

Runtime secrets contract (doctrine: load `forja:doctrina`, ops/07). Secrets
live encrypted in the Swarm and are mounted as files under `/run/secrets/`
inside the container — never as baked env vars, never in the image, NEVER in
git.

## The name IS the contract

`secret name = Zod config field` (`src/core/config.ts`). The Swarm secret
`${STACK}_<key>` is mounted at `/run/secrets/<key>`, and the config loader
reads each schema field from the file with the same name. No mapping table
exists. A new secret = a new schema field + a line in `secrets/<env>.env` + a
build placeholder in the Dockerfile builder stage.

## The 7 runtime secrets

| Key | Consumed by | Notes |
| --- | --- | --- |
| `db_url` | `app` (config), `migrate` (drizzle) | `postgres://{{DB_USER}}:<db_password>@db:5432/{{DB_NAME}}` — the host is the service DNS name `db`, never localhost; user, database and password must match the `db` service values. |
| `session_secret` | `app` (config) | Random, at least 32 chars. |
| `app_base_url` | `app` (config) | Prod: `https://{{PUBLIC_NAME}}.{{DOMAIN}}`. Test: `https://<dev>-{{PUBLIC_NAME}}.{{DOMAIN}}` where `<dev>` is your `git config forja.devUser` (fallback `dev`) — it must match the hostname of YOUR tunnel. |
| `db_password` | `db` (`POSTGRES_PASSWORD_FILE`), `backup` | Must equal the password embedded in `db_url`. |
| `tunnel_token` | `cloudflared` (`--token-file`) | From the Cloudflare Tunnel provisioning. One token per environment — and in test, per DEVELOPER: each dev provisions their own tunnel (`<app>-test-<dev>`) and keeps its token in their local `secrets/test.env`. One tunnel = one connector. |
| `storage_box_dest` | `backup` | `uNNNNNN@uNNNNNN.your-storagebox.de` — Hetzner Storage Box SFTP destination (port 23; lives OUTSIDE the prod cloud project). |
| `backup_ssh_key_b64` | `backup` | Base64-encoded ed25519 PRIVATE key dedicated to the sidecar (base64 because a multiline value does not survive the `.env` line format). Only uploads/rotates dumps; never grants node access. |

## Source files

- `secrets/prod.env` and `secrets/test.env` — one `key=value` per line, keys
  lowercase, no quotes, no multiline values.
- Both are **gitignored** (`secrets/*.env`). They exist only on the operator's
  machine, backed up in a password manager: lose the machine without the
  backup and the secrets are gone.

## Lifecycle

- `deploy.sh <env>` materializes each line as the Docker secret
  `${STACK}_<key>` — **only if absent**. Secrets are immutable: the deploy
  never overwrites a live one, which is what makes it safe to re-run.
- It asserts ALL required secrets exist before touching the database: a
  missing secret aborts there, not with the schema already migrated.
- **Rotation** is a deliberate act, not a side effect: create the new value,
  update the service (`--secret-rm` / `--secret-add`), verify inside the
  container, remove the old object, then sync `secrets/<env>.env`. Full
  procedure: doctrine ops/07 (`forja:doctrina`).
