#!/bin/bash
###############################################################################
# Read-Only Filesystem Setup Script
# Configures overlayfs for kiosk reliability
###############################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (sudo)"
    exit 1
fi

# Check for Debian/Ubuntu
if ! command -v apt &> /dev/null; then
    print_error "This script is designed for Debian/Ubuntu systems"
    exit 1
fi

echo ""
echo "============================================="
echo "  Read-Only Filesystem Setup for Kiosk"
echo "============================================="
echo ""
print_warn "This will configure the system for read-only operation."
print_warn "Make sure you have a /data partition for persistent storage."
echo ""
read -p "Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Install required packages
print_info "Installing required packages..."
apt update
apt install -y overlayroot busybox-initramfs

# Create /data mount point if it doesn't exist
if [ ! -d /data ]; then
    mkdir -p /data
fi

# Check if /data partition exists
print_info "Checking for /data partition..."
if ! grep -q "/data" /etc/fstab; then
    print_warn "No /data partition found in /etc/fstab"
    echo ""
    echo "Available partitions:"
    lsblk -f
    echo ""
    read -p "Enter the partition to use for /data (e.g., /dev/sda3): " DATA_PART

    if [ -z "$DATA_PART" ]; then
        print_error "No partition specified. Creating /data as a directory on root."
        print_warn "Data will NOT persist across reboots in read-only mode!"
    else
        # Get UUID
        DATA_UUID=$(blkid -s UUID -o value "$DATA_PART")
        if [ -z "$DATA_UUID" ]; then
            print_error "Could not get UUID for $DATA_PART"
            exit 1
        fi

        # Add to fstab
        echo "UUID=$DATA_UUID /data ext4 defaults,noatime 0 2" >> /etc/fstab
        mount /data
        print_info "Mounted $DATA_PART at /data"
    fi
fi

# Create data directory structure
print_info "Creating data directory structure..."
mkdir -p /data/directory
mkdir -p /data/backups
mkdir -p /data/logs
chown -R 1000:1000 /data  # Assuming first user (UID 1000)

# Install overlay-root initramfs hook
print_info "Installing initramfs overlay hook..."
cat > /etc/initramfs-tools/scripts/init-bottom/overlay << 'OVERLAY_SCRIPT'
#!/bin/sh

PREREQ=""
prereqs()
{
    echo "$PREREQ"
}

case $1 in
prereqs)
    prereqs
    exit 0
    ;;
esac

# Skip if disabled via kernel parameter
for x in $(cat /proc/cmdline); do
    case $x in
        overlay=disable)
            exit 0
            ;;
    esac
done

. /scripts/functions

log_begin_msg "Setting up overlay filesystem"

# Create overlay directories in RAM
mkdir -p /overlay
mount -t tmpfs tmpfs /overlay -o size=256M
mkdir -p /overlay/upper
mkdir -p /overlay/work

# Move the real root to /overlay/lower
mkdir -p /overlay/lower
mount --move ${rootmnt} /overlay/lower

# Create the overlay mount
mount -t overlay overlay -o lowerdir=/overlay/lower,upperdir=/overlay/upper,workdir=/overlay/work ${rootmnt}

# Move /overlay into the new root so we can access it later
mkdir -p ${rootmnt}/overlay
mount --move /overlay ${rootmnt}/overlay

# Remount lower as read-only
mount -o remount,ro ${rootmnt}/overlay/lower

log_end_msg

exit 0
OVERLAY_SCRIPT

chmod +x /etc/initramfs-tools/scripts/init-bottom/overlay

# Create overlay management scripts
print_info "Creating management scripts..."

# Status script
cat > /usr/local/bin/readonly-status << 'EOF'
#!/bin/bash
if mount | grep -q "overlay on / type overlay"; then
    echo "System is running in READ-ONLY mode with overlay"
    echo ""
    echo "Lower (read-only): $(df -h /overlay/lower 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " used"}')"
    echo "Upper (tmpfs):     $(df -h /overlay/upper 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " used"}')"
    echo "Data partition:    $(df -h /data 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " used"}')"
else
    echo "System is running in NORMAL (read-write) mode"
fi
EOF
chmod +x /usr/local/bin/readonly-status

# Read-write mode script
cat > /usr/local/bin/rwmode << 'EOF'
#!/bin/bash
if [ "$EUID" -ne 0 ]; then
    echo "Must be run as root"
    exit 1
fi

if ! mount | grep -q "overlay on / type overlay"; then
    echo "System is not in overlay mode"
    exit 0
fi

echo "Remounting lower filesystem as read-write..."
mount -o remount,rw /overlay/lower
echo "Lower filesystem is now writable."
echo "Changes to /overlay/lower will persist."
echo "Run 'romode' when done to return to read-only."
EOF
chmod +x /usr/local/bin/rwmode

# Read-only mode script
cat > /usr/local/bin/romode << 'EOF'
#!/bin/bash
if [ "$EUID" -ne 0 ]; then
    echo "Must be run as root"
    exit 1
fi

if ! mount | grep -q "overlay on / type overlay"; then
    echo "System is not in overlay mode"
    exit 0
fi

echo "Syncing filesystems..."
sync

echo "Remounting lower filesystem as read-only..."
mount -o remount,ro /overlay/lower
echo "Lower filesystem is now read-only."
EOF
chmod +x /usr/local/bin/romode

# Persist script - copy file from overlay to lower
cat > /usr/local/bin/persist << 'EOF'
#!/bin/bash
if [ "$EUID" -ne 0 ]; then
    echo "Must be run as root"
    exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: persist <file-path>"
    echo "Copies a file from the overlay to the persistent lower filesystem"
    exit 1
fi

FILE="$1"
if [ ! -e "$FILE" ]; then
    echo "File not found: $FILE"
    exit 1
fi

if ! mount | grep -q "overlay on / type overlay"; then
    echo "System is not in overlay mode, file is already persistent"
    exit 0
fi

# Enable writes temporarily
mount -o remount,rw /overlay/lower

# Copy file to lower
LOWER_PATH="/overlay/lower$FILE"
mkdir -p "$(dirname "$LOWER_PATH")"
cp -a "$FILE" "$LOWER_PATH"
echo "Persisted: $FILE"

# Return to read-only
mount -o remount,ro /overlay/lower
echo "Done."
EOF
chmod +x /usr/local/bin/persist

# Create systemd service to bind-mount /data directories
print_info "Creating systemd mount service..."
cat > /etc/systemd/system/data-mounts.service << 'EOF'
[Unit]
Description=Bind mount persistent data directories
After=local-fs.target
Before=directory-server.service

[Service]
Type=oneshot
RemainAfterExit=yes

# Bind mount the database directory
ExecStart=/bin/mkdir -p /home/kiosk/building-directory/server
ExecStart=/bin/mount --bind /data/directory /home/kiosk/building-directory/server

# Bind mount logs
ExecStart=/bin/mkdir -p /var/log/directory
ExecStart=/bin/mount --bind /data/logs /var/log/directory

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable data-mounts.service

# Update the directory server service to depend on data-mounts
if [ -f /etc/systemd/system/directory-server.service ]; then
    print_info "Updating directory-server service dependencies..."
    sed -i 's/After=network.target/After=network.target data-mounts.service/' \
        /etc/systemd/system/directory-server.service
    systemctl daemon-reload
fi

# Configure log rotation to use tmpfs
print_info "Configuring logging for read-only operation..."
cat > /etc/systemd/journald.conf.d/volatile.conf << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
EOF

# Disable apt daily updates (can't write anyway)
print_info "Disabling automatic updates..."
systemctl disable apt-daily.timer 2>/dev/null || true
systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable logrotate.timer 2>/dev/null || true
systemctl disable man-db.timer 2>/dev/null || true
systemctl disable dpkg-db-backup.timer 2>/dev/null || true
systemctl disable wtmpdb-update-boot.service 2>/dev/null || true

# Update initramfs
print_info "Updating initramfs..."
update-initramfs -u

echo ""
echo "============================================="
echo "  Read-Only Setup Complete!"
echo "============================================="
echo ""
print_info "The system will boot in read-only mode after reboot."
echo ""
echo "Important paths:"
echo "  /data/directory/  - Database files (persistent)"
echo "  /data/backups/    - Backup files (persistent)"
echo "  /data/logs/       - Log files (persistent)"
echo ""
echo "Commands:"
echo "  readonly-status   - Check current mode"
echo "  sudo rwmode       - Enable writes for updates"
echo "  sudo romode       - Return to read-only"
echo "  sudo persist FILE - Make a file change permanent"
echo ""
echo "To disable read-only mode at boot, add 'overlay=disable' to kernel parameters."
echo ""
read -p "Reboot now to enable read-only mode? (y/n): " REBOOT
if [ "$REBOOT" = "y" ]; then
    print_info "Rebooting in 5 seconds..."
    sleep 5
    reboot
fi
