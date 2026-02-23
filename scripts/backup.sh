#!/bin/bash
set -e

BACKUP_DIR=~/building-directory-backups
SOURCE_DB=~/building-directory/server/directory.db
DATE=$(date +%Y%m%d_%H%M%S)

if [ ! -f "$SOURCE_DB" ]; then
    echo "Error: Database not found at $SOURCE_DB" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"
cp "$SOURCE_DB" "$BACKUP_DIR/directory_$DATE.db"
find "$BACKUP_DIR" -name "directory_*.db" -mtime +30 -delete
echo "Backup completed: directory_$DATE.db"
