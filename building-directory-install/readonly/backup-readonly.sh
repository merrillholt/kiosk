#!/bin/bash
###############################################################################
# Backup script for read-only kiosk configuration
# Backs up database to /data/backups and optionally to remote server
###############################################################################

set -e

# Configuration
DATA_DIR="/data/directory"
BACKUP_DIR="/data/backups"
DB_FILE="$DATA_DIR/directory.db"
RETENTION_DAYS=30

# Remote backup (optional - set these if you want remote backups)
REMOTE_BACKUP_ENABLED=false
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_PATH=""

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Check database exists
if [ ! -f "$DB_FILE" ]; then
    log "ERROR: Database not found at $DB_FILE"
    exit 1
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Create backup filename with timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/directory_$TIMESTAMP.db"

# Use SQLite's backup command for consistency
log "Creating backup..."
sqlite3 "$DB_FILE" ".backup '$BACKUP_FILE'"

# Verify backup
if [ -f "$BACKUP_FILE" ]; then
    SIZE=$(ls -lh "$BACKUP_FILE" | awk '{print $5}')
    log "Backup created: $BACKUP_FILE ($SIZE)"

    # Create latest symlink
    ln -sf "$BACKUP_FILE" "$BACKUP_DIR/latest.db"
else
    log "ERROR: Backup failed"
    exit 1
fi

# Clean old backups
log "Cleaning backups older than $RETENTION_DAYS days..."
DELETED=$(find "$BACKUP_DIR" -name "directory_*.db" -mtime +$RETENTION_DAYS -delete -print | wc -l)
if [ "$DELETED" -gt 0 ]; then
    log "Deleted $DELETED old backup(s)"
fi

# Remote backup
if [ "$REMOTE_BACKUP_ENABLED" = true ] && [ -n "$REMOTE_HOST" ]; then
    log "Uploading to remote server..."
    if scp -q "$BACKUP_FILE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/"; then
        log "Remote backup successful"
    else
        log "WARNING: Remote backup failed"
    fi
fi

# Summary
BACKUP_COUNT=$(find "$BACKUP_DIR" -name "directory_*.db" | wc -l)
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
log "Backup complete. Total backups: $BACKUP_COUNT, Size: $TOTAL_SIZE"
