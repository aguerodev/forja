#!/bin/sh
# PLACEHOLDER — the real implementation lands with forja phase 3c.
# Contract it will fulfill (doctrine: wiki ops/09): daily pg_dump -Fc at
# 03:30 UTC + one run on start, validated with pg_restore --list, keep 7
# local in /backups (volume dbbackups) + SFTP upload (port 23) to
# $BACKUP_REMOTE_DIR on the Storage Box; failed upload = WARN, retry next day.
# Inputs: PGHOST/PGPORT/PGUSER/PGDATABASE, DB_PASSWORD_FILE, BACKUP_KEEP,
# BACKUP_REMOTE_DIR, /run/secrets/storage_box_dest, /run/secrets/backup_ssh_key_b64.
echo "db-backup: not implemented yet (placeholder; real script ships with forja phase 3c)" >&2
exit 1
