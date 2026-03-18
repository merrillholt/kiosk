# Read-Only Filesystem

## Why Use a Read-Only Filesystem?

A read-only root filesystem dramatically improves reliability for kiosk deployments by protecting against filesystem corruption from unexpected power loss.

## The Core Problem: Unexpected Power Loss

Kiosks get unplugged, lose power during outages, or get switched off without proper shutdown. When this happens mid-write:

```
Normal filesystem during write:
+----------------------------------------------+
|  1. Open file                                |
|  2. Write partial data  <<< POWER LOST HERE  |
|  3. Flush to disk           (not reached)    |
|  4. Update journal/metadata (not reached)    |
|  5. Close file              (not reached)    |
+----------------------------------------------+
         |
         v
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

+---------------------------------------------+
|         Volatile Layer (tmpfs/RAM)          |  ← Writes go here
|         Lost on reboot - that's fine        |     (disappear on power loss)
+---------------------------------------------+
|         Read-Only Root (SSD)                |  ← Never modified
|         Always pristine, always bootable    |     (can't be corrupted)
+---------------------------------------------+
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

The SSD has limited write cycles. Constant logging and temp files degrade it over time.

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

## Production Disk Layout

Current production hosts use four partitions on a single mSATA SSD:

```
/dev/sda   (mSATA SSD)
+-- sda1   ~976 MB   EFI System    vfat   (UEFI boot partition)
+-- sda2   ~20.5 GB  /             ext4   (root — mounted read-only by overlayroot)
+-- sda3   ~1.5 GB   swap
+-- sda4   ~6.8 GB   /data         ext4   (persistent data — always mounted rw)
```

The overlayroot layer sits on top of the read-only root:

```
/media/root-ro        ← lower layer: read-only ext4 (sda2, the real filesystem)
/media/root-rw        ← upper layer: tmpfs (ephemeral writes, lost on reboot)
/                     ← overlay of the two (what the running system sees)
/data                 ← mounted directly from sda4, unaffected by overlayroot
```

The application's persistent state lives on `/data`:

| Item | Path |
|------|------|
| Database | `/data/directory/directory.db` |
| Backups | `/data/backups/building-directory/` |
| DB symlink | `~/building-directory/server/directory.db → /data/directory/directory.db` in steady-state production |
| Uploaded images | persisted to overlay lower layer via `/usr/local/bin/persist-upload.sh` |

Critical: `overlayroot.conf` must be:
```
overlayroot="tmpfs:swap=1,recurse=0"
```
The `recurse=0` flag prevents `/data` from being overlaid. Without it, admin edits are lost on reboot.

## Trade-offs

| Benefit | Trade-off |
|---------|-----------|
| Can't corrupt OS | Updates require deploy or overlayroot-chroot |
| Consistent state | Logs don't persist across reboots |
| No SSD wear on root | Database needs persistent partition |
| Easy recovery | Slightly more complex initial setup |

## Making Persistent Changes

### Normal deploys (recommended)

Use `tools/deploy-ssh.sh` from the development machine. The script is overlay-aware and writes files directly to the lower layer via `overlayroot-chroot`:

```bash
tools/deploy-ssh.sh           # server-only
tools/deploy-ssh.sh --full    # server + kiosk + scripts
```

### Manual persistent change on a running host

```bash
# Run a single command in the lower layer
sudo overlayroot-chroot <command>

# Or drop into an interactive shell in the lower layer
sudo overlayroot-chroot bash
# ... make changes ...
exit
```

Note: if `/media/root-ro` is already mounted read-write (busy), `overlayroot-chroot`
will print a warning but still execute the command successfully.

### Verify /data is mounted correctly

```bash
mount | grep ' on /data '
# Expected: /dev/sda4 on /data type ext4 (rw,relatime)
```

## Maintenance Mode (Writable Root)

For changes that cannot be made via `overlayroot-chroot` (e.g. package installs, grub updates):

1. Reboot and hold/press the key for the grub menu
2. Select the **Maintenance** entry (added by `setup-readonly-simple.sh`)
3. Root filesystem is fully writable in this mode
4. Reboot normally when done — overlay is restored

Or pass the kernel parameter manually at the grub prompt:
```
overlayroot=disabled
```

## Implementation

See the `readonly/` directory for setup scripts:

- `setup-readonly-simple.sh` — Easy setup using overlayroot (recommended)
- `setup-readonly.sh` — Custom initramfs overlay setup
- `migrate-to-data-partition.sh` — Move database to persistent `/data` partition
