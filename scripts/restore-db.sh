#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/restore-db.sh <backup.sqlite>

Restore the production SQLite database from a local backup file.
The script creates a safety backup first, stops directory-server,
replaces the database, and restarts the service.
USAGE
}

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

SOURCE_DB="$1"
if [[ ! -f "$SOURCE_DB" ]]; then
    echo "Backup file not found: $SOURCE_DB" >&2
    exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "sqlite3 not found in PATH." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR%/scripts}"
DB_LINK="${DB_LINK:-$DEPLOY_ROOT/server/directory.db}"
DB_FILE="$(readlink -f "$DB_LINK")"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
SERVICE_NAME="${SERVICE_NAME:-directory-server}"
STOPPED_SERVICE=0

if [[ ! -f "$DB_FILE" ]]; then
    echo "Database not found: $DB_FILE" >&2
    exit 1
fi

sqlite3 "$SOURCE_DB" 'PRAGMA schema_version;' >/dev/null
TABLE_COUNT="$(sqlite3 "$SOURCE_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('companies','individuals','settings');")"
if [[ "$TABLE_COUNT" -lt 3 ]]; then
    echo "Backup is missing required tables." >&2
    exit 1
fi

restart_service_if_needed() {
    if [[ "$STOPPED_SERVICE" -eq 1 ]]; then
        sudo -n systemctl start "$SERVICE_NAME"
    fi
}

trap restart_service_if_needed EXIT

if [[ -x "$BACKUP_SCRIPT" ]]; then
    "$BACKUP_SCRIPT" >/dev/null
fi

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "$SERVICE_NAME.service" >/dev/null 2>&1; then
    sudo -n systemctl stop "$SERVICE_NAME"
    STOPPED_SERVICE=1
fi

TMP_RESTORE="${DB_FILE}.restore.$$"
cp "$SOURCE_DB" "$TMP_RESTORE"
sqlite3 "$TMP_RESTORE" 'PRAGMA quick_check;' >/dev/null
mv "$TMP_RESTORE" "$DB_FILE"

if [[ "$STOPPED_SERVICE" -eq 1 ]]; then
    sudo -n systemctl start "$SERVICE_NAME"
    STOPPED_SERVICE=0
fi

sqlite3 "$DB_FILE" "SELECT 'companies=' || COUNT(*) FROM companies;" >/dev/null
echo "Restore completed from: $SOURCE_DB"
