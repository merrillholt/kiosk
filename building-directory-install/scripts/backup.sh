#!/bin/bash
BACKUP_DIR=~/building-directory-backups
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p $BACKUP_DIR
cp ~/building-directory/server/directory.db "$BACKUP_DIR/directory_$DATE.db"
find $BACKUP_DIR -name "directory_*.db" -mtime +30 -delete
echo "Backup completed: directory_$DATE.db"
