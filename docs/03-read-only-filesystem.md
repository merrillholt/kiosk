# Read-Only Filesystem

## Why Use a Read-Only Filesystem?

A read-only root filesystem dramatically improves reliability for kiosk deployments by protecting against filesystem corruption from unexpected power loss.

## The Core Problem: Unexpected Power Loss

Kiosks get unplugged, lose power during outages, or get switched off without proper shutdown. When this happens mid-write:

```
Normal filesystem during write:
┌──────────────────────────────────────┐
│  1. Open file                        │
│  2. Write partial data ──────────────┼──── POWER LOST HERE
│  3. Flush to disk                    │
│  4. Update journal/metadata          │
│  5. Close file                       │
└──────────────────────────────────────┘
         ↓
   Corrupted file, orphaned inodes,
   or inconsistent filesystem state
```

## What Can Get Corrupted

| Component | Consequence |
|-----------|-------------|
| SQLite database | Data loss, "database is malformed" errors |
| systemd journal | Boot delays while journal recovers |
| Package manager state | `apt` breaks, can't install/update |
| Filesystem metadata | Won't boot, requires fsck or reinstall |
| Application configs | App won't start correctly |

## How Read-Only Solves This

```
Read-only root + overlay architecture:

┌─────────────────────────────────────────────┐
│         Volatile Layer (tmpfs/RAM)          │  ← Writes go here
│         Lost on reboot - that's fine        │     (disappear on power loss)
├─────────────────────────────────────────────┤
│         Read-Only Root (SSD)                │  ← Never modified
│         Always pristine, always bootable    │     (can't be corrupted)
└─────────────────────────────────────────────┘
```

**On power loss:** RAM contents vanish, but the SSD was never being written to. Next boot starts from a known-good state.

## Additional Reliability Benefits

### 1. Eliminates Filesystem Corruption

```
# Traditional system after hard power-off:
"Checking filesystem..."
"Recovering journal..."
"fsck found errors, manual intervention required"  ← Kiosk is now a brick

# Read-only system after hard power-off:
Boots normally in seconds. Every time.
```

### 2. Prevents State Drift

Over months of operation, writable systems accumulate:
- Stale temp files
- Growing logs
- Cached data
- Failed update artifacts

Read-only systems boot to identical state whether it's day 1 or day 500.

### 3. Reduces SSD Wear

The 32GB SSD has limited write cycles. Constant logging and temp files degrade it over time.

```
Writable system:     ~10-50 GB written/day (logs, journals, tmp)
Read-only system:    ~0 GB written/day
```

### 4. Security Hardening

Malware or buggy software can't persist. Even if compromised, a reboot returns to clean state.

### 5. Trivial Recovery

```
Kiosk acting strange?

Writable:    SSH in → diagnose → maybe fix → maybe reinstall
Read-only:   Reboot. Done.
```

## How It Works in Practice

```
Typical read-only kiosk layout:

/                    → read-only (squashfs or ext4 ro)
├── /etc             → overlay (changes in RAM)
├── /var             → tmpfs (RAM)
├── /tmp             → tmpfs (RAM)
├── /home            → tmpfs (RAM)
└── /data            → persistent writable partition
                       mounted directly as ext4 in normal mode
```

For the building directory app, the important persistent state is:
1. the SQLite database
2. uploaded background images

Current production model:
- `server/directory.db` is a symlink into `/data/directory/directory.db`
- `/data` must mount directly as ext4 in normal mode
- uploaded files are persisted via `/usr/local/bin/persist-upload.sh`
- production-local backups are created explicitly, not automatically on boot

Important:
- if `/data` is accidentally overlaid by overlayroot, admin edits will be lost on reboot
- current production systems should use `overlayroot="tmpfs:swap=1,recurse=0"` so `/data` remains persistent

## Trade-offs

| Benefit | Trade-off |
|---------|-----------|
| Can't corrupt OS | Updates require reboot or remount |
| Consistent state | Logs don't persist (send to server instead) |
| No SSD wear | Database needs special handling |
| Easy recovery | Slightly more complex initial setup |

## Implementation

See the `readonly/` directory for setup scripts:

- `setup-readonly-simple.sh` - Easy setup using overlayroot (recommended)
- `setup-readonly.sh` - Custom initramfs overlay setup
- `migrate-to-data-partition.sh` - Move database to persistent partition

## Management Commands

After setup, these commands are available:

```bash
# Check current mode
kiosk-status

# Verify /data is truly persistent
mount | grep ' on /data '

# Make persistent changes (for updates)
sudo overlayroot-chroot
# ... make changes ...
exit

# Or with custom setup:
sudo rwmode           # Enable writes
# ... make changes ...
sudo romode           # Return to read-only
```

## Disabling Read-Only Mode

For troubleshooting, boot with kernel parameter:
- `overlayroot=disabled` (simple method)
- `overlay=disable` (custom method)
