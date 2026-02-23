# Read-Only Filesystem Configuration for Kiosk

This configuration makes the root filesystem read-only while allowing:
- Temporary writes to RAM (lost on reboot)
- Persistent database storage on a dedicated partition

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    OverlayFS (merged view)                  │
│                 What the system actually sees               │
├─────────────────────────────────────────────────────────────┤
│  Upper Layer (tmpfs)    │  Lower Layer (read-only SSD)     │
│  - All writes go here   │  - Original system files         │
│  - Lost on reboot       │  - Never modified                │
│  - RAM-based            │  - Always pristine               │
├─────────────────────────┴───────────────────────────────────┤
│              /data partition (small, writable)              │
│              - SQLite database                              │
│              - Synced to backup server                      │
└─────────────────────────────────────────────────────────────┘
```

## Installation Steps

### 1. Partition Layout (during OS install)

| Partition | Size | Mount | Filesystem | Purpose |
|-----------|------|-------|------------|---------|
| /dev/sda1 | 512MB | /boot | ext4 | Bootloader (keep writable) |
| /dev/sda2 | 24GB | / | ext4 | Root filesystem (will be read-only) |
| /dev/sda3 | 4GB | /data | ext4 | Persistent data |
| /dev/sda4 | 2GB | swap | swap | Swap space |

### 2. Install the read-only overlay system

```bash
sudo ./setup-readonly.sh
```

### 3. Reboot

```bash
sudo reboot
```

## Management Commands

```bash
# Check if running in read-only mode
readonly-status

# Temporarily enable writes (for updates)
sudo rwmode

# Return to read-only mode
sudo romode

# Persist a file from overlay to lower filesystem
sudo persist /etc/some-config-file
```

## Updating the System

```bash
# 1. Enable write mode
sudo rwmode

# 2. Perform updates
sudo apt update && sudo apt upgrade

# 3. Return to read-only mode
sudo romode

# 4. Reboot to apply
sudo reboot
```

## Database Location

The SQLite database is stored at `/data/directory.db` which is on the
persistent writable partition. This survives reboots and is the only
user data that persists.

## Troubleshooting

### System won't boot after enabling read-only mode

Boot with kernel parameter `overlay=disable` to bypass the overlay and
boot normally for troubleshooting.

### Need to make permanent changes

Use `sudo rwmode` to temporarily enable writes, make changes, then
`sudo romode` to return to read-only mode.

### Database corruption

The database is on a separate partition. If corrupted:
1. Boot normally (overlay protects the OS)
2. Restore from backup: `cp /data/backups/latest.db /data/directory.db`
