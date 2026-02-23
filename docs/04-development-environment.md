# Development Environment

## Overview

Use VirtualBox with Debian for development, then deploy to the Qotom mini PC (or similar hardware). This approach allows testing without risking hardware, and you can snapshot before experimenting with the read-only setup.

## Recommended VM Configuration

| Setting | Value | Rationale |
|---------|-------|-----------|
| OS | Debian 13 (64-bit) | Matches target recommendation |
| RAM | 4 GB | Matches Qotom hardware |
| CPUs | 2 | Celeron 3205U has 2 cores |
| Disk | 32 GB (dynamic) | Matches target SSD |
| Graphics | 128 MB, VMSVGA | Sufficient for Chromium |
| Network | Bridged Adapter | Accessible from host for admin |

## Actual VM: kiosk-dev

The development VM is configured and running at:

- **VM name:** `kiosk-dev` (registered in VirtualBox at `/disk/virtualbox/kiosk-dev/`)
- **SSH:** `ssh merrill@192.168.1.127`
- **Shared folder:** `Public-Kiosk` → `/mnt/Public-Kiosk` in VM (host: `/home/security/Public-Kiosk`)

## Disk Layout

The VM uses three separate VDI disks (mirroring the target's separate partitions):

```
/dev/sda  (Kiosk.vdi, 20 GB)
├─ sda1   18.9 GB   /        ext4   (root)
└─ sda5    1.1 GB   -        swap   (inactive, replaced by sdc)

/dev/sdb  (data.vdi, 2 GB)   /data  ext4   (persistent database storage)
/dev/sdc  (swap.vdi, 6 GB)   -      swap   (active swap)
```

`/etc/fstab` is configured with UUIDs for all three mountpoints.

## VirtualBox-Specific Tips

### KDE Wayland Host

The development host runs KDE Plasma on Wayland. VirtualBox requires specific configuration to avoid display issues:

```bash
# Graphics controller must be VMSVGA (not VBoxSVGA — Manager will warn)
VBoxManage modifyvm kiosk-dev --graphicscontroller=vmsvga

# Disable auto-resize — prevents DRMClient "first monitor cannot be disabled" abort
VBoxManage setextradata kiosk-dev "GUI/AutoresizeGuest" "off"
```

**View mode:** Use **Scaled Mode** (`View → Scaled Mode`) in VirtualBox Manager.
Seamless mode is not supported on Wayland.

### Enable useful features for development:

```bash
# Clipboard and drag-drop (already enabled on kiosk-dev)
VBoxManage modifyvm kiosk-dev --clipboard-mode bidirectional

# Guest Additions are already installed (v7.2.4) on kiosk-dev
```

### Shared Folder

The project directory is shared into the VM automatically:

```
Host:  /home/security/Public-Kiosk  →  VM: /mnt/Public-Kiosk  (vboxsf, rw, auto-mount)
```

Develop on the host; the VM sees changes immediately via the shared folder.

### Simulate touchscreen (optional):

```bash
# VirtualBox Settings → USB → Add USB filter for touch device
# Or test touch events with mouse (Chromium treats clicks as touch in kiosk mode)
```

## Development Workflow

```
┌─────────────────────────────────────────────────────────────┐
│                     Development Cycle                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. Develop/test in VM (read-write mode)                    │
│              ↓                                               │
│  2. Snapshot VM                                              │
│              ↓                                               │
│  3. Enable read-only, test recovery scenarios               │
│              ↓                                               │
│  4. Revert to snapshot if needed                            │
│              ↓                                               │
│  5. When stable, deploy to physical hardware                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Key Differences: VM vs Hardware

| Aspect | VirtualBox VM | Qotom Hardware |
|--------|---------------|----------------|
| Watchdog | Software only (`softdog`) | Hardware (`/dev/watchdog`) |
| Graphics | VMSVGA virtual GPU | Intel integrated |
| Display | Windowed/fullscreen | Direct to monitor |
| Boot time | Fast (host SSD) | Slower (embedded SSD) |
| Network | Virtual NAT/Bridge | Physical Ethernet |

## Suggested Development Snapshots

Create snapshots at these stages:

1. **Fresh Install** - Clean Debian minimal
2. **Post-Install** - After running `install.sh`
3. **Pre-ReadOnly** - Before enabling read-only filesystem
4. **Production-Ready** - Final tested configuration

## Quick VM Setup Commands

```bash
# In the VM (via SSH or terminal):

# 1. Access project via shared folder
ls /mnt/Public-Kiosk   # project files available immediately

# 2. Run installation
cd /mnt/Public-Kiosk/building-directory-install
sudo ./install.sh   # Choose option 3 (both) for standalone testing

# 3. Test the application works
# Browse to http://192.168.1.127 from host browser

# 4. Snapshot before read-only setup
# (Do this from VirtualBox Manager on host)

# 5. Enable read-only
cd /mnt/Public-Kiosk/building-directory-install/readonly
sudo ./setup-readonly-simple.sh
```

## Network Configuration for Development

### Bridged Adapter (configured)

VM has its own IP on the local network. Access from host:

```
SSH    → ssh merrill@192.168.1.127
Browser → http://192.168.1.127/admin
```

Use a DHCP reservation on your router to keep the IP stable.

## Testing Checklist

Before deploying to hardware, verify in VM:

- [ ] Kiosk display loads correctly
- [ ] Touch/click navigation works
- [ ] Search functionality works
- [ ] Admin interface accessible
- [ ] Data persists after reboot
- [ ] Read-only mode works (if enabled)
- [ ] Recovery from simulated power loss
- [ ] Watchdog restarts crashed services
