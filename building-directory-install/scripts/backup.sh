#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_ROOT="${SCRIPT_DIR%/scripts}"
DB_LINK="${DB_LINK:-$DEPLOY_ROOT/server/directory.db}"
DB_FILE="$(readlink -f "$DB_LINK")"
BACKUP_DIR="${BACKUP_DIR:-/data/backups/building-directory}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-60}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BASENAME="directory-${TIMESTAMP}.sqlite"
BACKUP_PATH="$BACKUP_DIR/$BASENAME"
TMP_PATH="$BACKUP_DIR/.${BASENAME}.tmp"
LATEST_PATH="$BACKUP_DIR/directory-latest.sqlite"

if [[ ! -f "$DB_FILE" ]]; then
    echo "Database not found: $DB_FILE" >&2
    exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "sqlite3 not found in PATH." >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"
rm -f "$TMP_PATH"

sqlite_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

escaped_tmp="$(sqlite_escape "$TMP_PATH")"
sqlite3 "$DB_FILE" ".backup '$escaped_tmp'"
sqlite3 "$TMP_PATH" 'PRAGMA schema_version;' >/dev/null

if [[ -f "$LATEST_PATH" ]] && cmp -s "$TMP_PATH" "$LATEST_PATH"; then
    rm -f "$TMP_PATH"
    echo "Backup skipped: database unchanged since latest backup."
    echo "Current latest backup: $LATEST_PATH"
    exit 0
fi

mv "$TMP_PATH" "$BACKUP_PATH"
cp -f "$BACKUP_PATH" "$LATEST_PATH"

if [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && [[ "$RETENTION_DAYS" -gt 0 ]]; then
    mapfile -t old_backups < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'directory-*.sqlite' -mtime +"$RETENTION_DAYS" | sort)
    for old_backup in "${old_backups[@]}"; do
        [[ -n "$old_backup" ]] || continue
        [[ "$old_backup" == "$BACKUP_PATH" ]] && continue
        rm -f "$old_backup"
    done
fi

echo "Backup completed: $BACKUP_PATH"
echo "Latest alias updated: $LATEST_PATH -> $BASENAME"
