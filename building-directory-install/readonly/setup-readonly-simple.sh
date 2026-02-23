#!/bin/bash
###############################################################################
# Simple Read-Only Setup using overlayroot (Ubuntu/Debian)
# This is the easier method using the built-in overlayroot package
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (sudo)"
    exit 1
fi

echo ""
echo "============================================="
echo "  Simple Read-Only Setup (overlayroot)"
echo "============================================="
echo ""

# Install overlayroot
print_info "Installing overlayroot package..."
apt update
apt install -y overlayroot

# Create /data partition mount if needed
if [ ! -d /data ]; then
    mkdir -p /data
fi

if ! grep -q "/data" /etc/fstab; then
    echo ""
    echo "Available partitions:"
    lsblk -f
    echo ""
    read -p "Enter partition for persistent /data (e.g., /dev/sda3) or press Enter to skip: " DATA_PART

    if [ -n "$DATA_PART" ]; then
        DATA_UUID=$(blkid -s UUID -o value "$DATA_PART")
        if [ -n "$DATA_UUID" ]; then
            echo "UUID=$DATA_UUID /data ext4 defaults,noatime 0 2" >> /etc/fstab
            mount /data 2>/dev/null || true
            print_info "Added /data to fstab"
        fi
    fi
fi

# Create data directories
mkdir -p /data/directory
mkdir -p /data/backups
mkdir -p /data/logs
chown -R 1000:1000 /data

# Configure overlayroot
print_info "Configuring overlayroot..."
cat > /etc/overlayroot.conf << 'EOF'
# overlayroot configuration
# tmpfs overlay - all changes stored in RAM, lost on reboot
overlayroot="tmpfs:swap=1,recurse=0"

# To disable temporarily, set:
# overlayroot=""
#
# Or boot with kernel parameter: overlayroot=disabled
EOF

# Create bind mount service for persistent data
print_info "Creating persistent data mount service..."
cat > /etc/systemd/system/kiosk-data.service << 'EOF'
[Unit]
Description=Mount persistent kiosk data
After=local-fs.target overlayroot.service
Before=directory-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/mount-kiosk-data.sh

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/bin/mount-kiosk-data.sh << 'EOF'
#!/bin/bash

# Wait for /data to be available
for i in {1..30}; do
    if mountpoint -q /data 2>/dev/null || [ -d /data/directory ]; then
        break
    fi
    sleep 1
done

# Create target directories
mkdir -p /home/kiosk/building-directory/server

# Bind mount database directory
if [ -d /data/directory ]; then
    mount --bind /data/directory /home/kiosk/building-directory/server
fi

# Bind mount logs
mkdir -p /var/log/kiosk
if [ -d /data/logs ]; then
    mount --bind /data/logs /var/log/kiosk
fi

exit 0
EOF
chmod +x /usr/local/bin/mount-kiosk-data.sh

systemctl daemon-reload
systemctl enable kiosk-data.service

# Create helper scripts
print_info "Creating helper scripts..."

cat > /usr/local/bin/overlayroot-chroot << 'EOF'
#!/bin/bash
# Enter a chroot to make persistent changes
if [ "$EUID" -ne 0 ]; then
    echo "Must be run as root"
    exit 1
fi
echo "Entering chroot to make persistent changes..."
echo "Type 'exit' when done."
overlayroot-chroot
EOF
chmod +x /usr/local/bin/overlayroot-chroot

cat > /usr/local/bin/kiosk-status << 'EOF'
#!/bin/bash
echo "=== Kiosk System Status ==="
echo ""

if grep -q "overlayroot" /proc/mounts 2>/dev/null; then
    echo "Filesystem: READ-ONLY (overlay active)"
else
    echo "Filesystem: READ-WRITE (normal mode)"
fi

echo ""
echo "Storage:"
df -h / /data 2>/dev/null | grep -v "^Filesystem"

echo ""
echo "Services:"
systemctl is-active --quiet directory-server && echo "  directory-server: running" || echo "  directory-server: stopped"
systemctl is-active --quiet nginx && echo "  nginx: running" || echo "  nginx: stopped"

echo ""
echo "Database:"
if [ -f /data/directory/directory.db ]; then
    ls -lh /data/directory/directory.db | awk '{print "  Size: " $5 ", Modified: " $6 " " $7}'
else
    echo "  Not found at /data/directory/directory.db"
fi
EOF
chmod +x /usr/local/bin/kiosk-status

# Disable unnecessary services
print_info "Disabling unnecessary services..."
systemctl disable apt-daily.timer 2>/dev/null || true
systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable man-db.timer 2>/dev/null || true

# Configure journal to volatile
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/volatile.conf << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
EOF

# Update initramfs
print_info "Updating initramfs..."
update-initramfs -u

echo ""
echo "============================================="
echo "  Setup Complete!"
echo "============================================="
echo ""
echo "After reboot, the system will run in read-only mode."
echo ""
echo "Persistent data location: /data/"
echo "  /data/directory/  - Database files"
echo "  /data/backups/    - Backups"
echo "  /data/logs/       - Logs"
echo ""
echo "Commands:"
echo "  kiosk-status            - Show system status"
echo "  sudo overlayroot-chroot - Make persistent changes"
echo ""
echo "To disable read-only mode, boot with: overlayroot=disabled"
echo ""
read -p "Reboot now? (y/n): " REBOOT
if [ "$REBOOT" = "y" ]; then
    reboot
fi
