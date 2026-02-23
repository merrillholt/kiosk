# Complete Kiosk Deployment Guide

Step-by-step deployment for the Qotom Q305P (or similar mini PC) with read-only filesystem.

## Hardware Setup

1. Connect SSD, RAM, display, and network
2. Boot from USB installer

## Partition Layout

During Debian/Ubuntu installation, create this partition layout:

| Partition | Size | Mount | Type | Purpose |
|-----------|------|-------|------|---------|
| sda1 | 512 MB | /boot/efi | EFI | UEFI boot (if applicable) |
| sda2 | 22 GB | / | ext4 | Root filesystem |
| sda3 | 6 GB | /data | ext4 | Persistent data |
| sda4 | 2 GB | swap | swap | Swap (or use zram) |

## Installation Steps

### Step 1: Install Base OS

Install Debian 12 minimal or Ubuntu Server 24.04 minimal:

```bash
# During install:
# - Select minimal installation
# - Create user: kiosk
# - Set hostname: kiosk-01 (or kiosk-02, kiosk-03)
# - Enable SSH for remote management
```

### Step 2: Initial System Setup

```bash
# Login as kiosk user, then:
sudo apt update && sudo apt upgrade -y

# Install git
sudo apt install -y git

# Clone the building directory repository
git clone <your-repo-url> ~/building-directory-install
cd ~/building-directory-install
```

### Step 3: Run Main Installation

```bash
# For kiosk client:
./install.sh
# Select option 2 (Kiosk Client)
# Enter server IP when prompted
```

### Step 4: Migrate Data to /data Partition

```bash
cd readonly
chmod +x *.sh
./migrate-to-data-partition.sh
```

### Step 5: Enable Read-Only Mode

Choose one method:

**Method A: Simple (recommended)**
```bash
sudo ./setup-readonly-simple.sh
```

**Method B: Custom overlay**
```bash
sudo ./setup-readonly.sh
```

### Step 6: Setup Watchdog (optional but recommended)

```bash
sudo ./setup-watchdog.sh
```

### Step 7: Reboot and Verify

```bash
sudo reboot

# After reboot, verify read-only mode:
kiosk-status
```

## Post-Installation

### Verify Everything Works

```bash
# Check system status
kiosk-status

# Check services
systemctl status directory-server
systemctl status nginx

# Check kiosk display is running
pgrep chromium
```

### Configure Remote Backups (optional)

Edit `/data/directory/backup.sh` and set:
```bash
REMOTE_BACKUP_ENABLED=true
REMOTE_HOST="your-backup-server"
REMOTE_USER="backup"
REMOTE_PATH="/backups/kiosk-01"
```

## Maintenance

### Updating the System

```bash
# Method 1: Using overlayroot-chroot (simple method)
sudo overlayroot-chroot
apt update && apt upgrade
exit
sudo reboot

# Method 2: Using rwmode (custom method)
sudo rwmode
sudo apt update && sudo apt upgrade
sudo romode
sudo reboot
```

### Updating Kiosk Application

```bash
# Enable writes
sudo overlayroot-chroot  # or: sudo rwmode

# Pull updates
cd ~/building-directory
git pull

# Update dependencies
cd server && npm install

# Exit and reboot
exit  # or: sudo romode
sudo reboot
```

### Restoring from Backup

```bash
# List available backups
ls -la /data/backups/

# Restore (example)
cp /data/backups/directory_20240115_020000.db /data/directory/directory.db
sudo systemctl restart directory-server
```

## Troubleshooting

### Kiosk won't boot

Boot with kernel parameter: `overlayroot=disabled`
or: `overlay=disable`

### Black screen on kiosk

```bash
# SSH into the kiosk
ssh kiosk@<kiosk-ip>

# Check X server
systemctl status display-manager

# Restart kiosk
~/building-directory/scripts/restart-kiosk.sh
```

### Database errors

```bash
# Check database integrity
sqlite3 /data/directory/directory.db "PRAGMA integrity_check;"

# Restore from backup if needed
cp /data/backups/latest.db /data/directory/directory.db
```

### Reset to clean state

Since the filesystem is read-only, just reboot:
```bash
sudo reboot
```
The system will return to its pristine state.

## Network Diagram

```
                                    ┌─────────────────┐
                                    │  Admin Computer │
                                    │  (web browser)  │
                                    └────────┬────────┘
                                             │
    ┌────────────────────────────────────────┼────────────────────────────────────────┐
    │                                   Network                                        │
    └────────┬───────────────────────────────┼───────────────────────────┬────────────┘
             │                               │                           │
    ┌────────┴────────┐             ┌────────┴────────┐         ┌────────┴────────┐
    │    Kiosk 1      │             │    Kiosk 2      │         │    Kiosk 3      │
    │  (Read-only)    │             │  (Read-only)    │         │  (Read-only)    │
    │                 │             │                 │         │                 │
    │  ┌───────────┐  │             │  ┌───────────┐  │         │  ┌───────────┐  │
    │  │ Chromium  │  │             │  │ Chromium  │  │         │  │ Chromium  │  │
    │  │  Kiosk    │  │             │  │  Kiosk    │  │         │  │  Kiosk    │  │
    │  └───────────┘  │             │  └───────────┘  │         │  └───────────┘  │
    │        ↓        │             │        ↓        │         │        ↓        │
    │    Server       │◄─ sync ─────┤    Cache        │──sync ──┤    Cache        │
    │    + SQLite     │             │    (localStorage)         │    (localStorage)
    │                 │             │                 │         │                 │
    └─────────────────┘             └─────────────────┘         └─────────────────┘
           │
           └── One kiosk runs the server, others connect to it
               Or: dedicated server machine + 3 display-only kiosks
```

## File Locations Summary

| Path | Purpose | Persistent? |
|------|---------|-------------|
| /data/directory/directory.db | Database | Yes |
| /data/backups/ | Backup files | Yes |
| /data/logs/ | Application logs | Yes |
| ~/building-directory/ | Application code | No (read-only) |
| /etc/ | System config | No (overlay) |
| /var/ | Variable data | No (tmpfs) |
