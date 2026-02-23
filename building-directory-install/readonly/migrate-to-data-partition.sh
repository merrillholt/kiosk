#!/bin/bash
###############################################################################
# Migration Script
# Moves existing database and configuration to /data partition
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Paths
OLD_DB="$HOME/building-directory/server/directory.db"
NEW_DATA_DIR="/data/directory"
NEW_BACKUP_DIR="/data/backups"

echo ""
echo "============================================="
echo "  Migrate to /data Partition"
echo "============================================="
echo ""

# Check /data is mounted
if ! mountpoint -q /data 2>/dev/null && [ ! -d /data ]; then
    print_error "/data is not mounted"
    echo "Please mount the data partition first:"
    echo "  1. Create partition if needed"
    echo "  2. Format: sudo mkfs.ext4 /dev/sdX"
    echo "  3. Add to /etc/fstab"
    echo "  4. Mount: sudo mount /data"
    exit 1
fi

# Create directories
print_info "Creating directory structure..."
sudo mkdir -p "$NEW_DATA_DIR"
sudo mkdir -p "$NEW_BACKUP_DIR"
sudo mkdir -p /data/logs
sudo chown -R $USER:$USER /data

# Migrate database
if [ -f "$OLD_DB" ]; then
    print_info "Migrating database..."
    cp "$OLD_DB" "$NEW_DATA_DIR/"
    print_info "Database copied to $NEW_DATA_DIR/directory.db"
else
    print_warn "No existing database found at $OLD_DB"
    print_info "A new database will be created on first server start"
fi

# Migrate backups
OLD_BACKUP_DIR="$HOME/building-directory-backups"
if [ -d "$OLD_BACKUP_DIR" ] && [ "$(ls -A $OLD_BACKUP_DIR 2>/dev/null)" ]; then
    print_info "Migrating existing backups..."
    cp "$OLD_BACKUP_DIR"/*.db "$NEW_BACKUP_DIR/" 2>/dev/null || true
    print_info "Backups copied to $NEW_BACKUP_DIR/"
fi

# Update server configuration to use new database location
print_info "Updating server configuration..."
SERVER_JS="$HOME/building-directory/server/server.js"
if [ -f "$SERVER_JS" ]; then
    # Check if already updated
    if grep -q "/data/directory" "$SERVER_JS"; then
        print_info "Server already configured for /data/directory"
    else
        # Create a symlink instead of modifying the code
        print_info "Creating symlink to new database location..."
        if [ -f "$OLD_DB" ]; then
            mv "$OLD_DB" "${OLD_DB}.bak"
        fi
        ln -sf "$NEW_DATA_DIR/directory.db" "$OLD_DB"
        print_info "Symlink created: $OLD_DB -> $NEW_DATA_DIR/directory.db"
    fi
fi

# Update backup cron job
print_info "Updating backup script..."
BACKUP_SCRIPT="$HOME/building-directory/scripts/backup.sh"
if [ -f "$BACKUP_SCRIPT" ]; then
    cat > "$BACKUP_SCRIPT" << 'EOF'
#!/bin/bash
set -e

BACKUP_DIR=/data/backups
SOURCE_DB=/data/directory/directory.db
DATE=$(date +%Y%m%d_%H%M%S)

if [ ! -f "$SOURCE_DB" ]; then
    echo "Error: Database not found at $SOURCE_DB" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"

# Use SQLite backup for consistency
sqlite3 "$SOURCE_DB" ".backup '$BACKUP_DIR/directory_$DATE.db'"

# Create latest symlink
ln -sf "$BACKUP_DIR/directory_$DATE.db" "$BACKUP_DIR/latest.db"

# Clean old backups (keep 30 days)
find "$BACKUP_DIR" -name "directory_*.db" -mtime +30 -delete

echo "Backup completed: directory_$DATE.db"
EOF
    chmod +x "$BACKUP_SCRIPT"
fi

# Summary
echo ""
echo "============================================="
echo "  Migration Complete"
echo "============================================="
echo ""
echo "Data locations:"
echo "  Database:  $NEW_DATA_DIR/directory.db"
echo "  Backups:   $NEW_BACKUP_DIR/"
echo "  Logs:      /data/logs/"
echo ""
print_info "Restart the directory server to apply changes:"
echo "  sudo systemctl restart directory-server"
echo ""
