# New Host Installation

Step-by-step procedure for installing a new kiosk host from bare metal.
Applies to all deployed hardware (Qotom Q305P and Intel NUC DC3217IYE).
Hardware-specific notes are called out inline.

---

## Pre-flight

Before starting:

- Confirm the target IP and hostname:
  - `.80` — Qotom Q305P, primary
  - `.81` — Intel NUC DC3217IYE, standby
  - `.82` — Qotom Q305P, reserved
- Configure a DHCP reservation on the router for the host's MAC address.
- Have a USB stick (≥ 2GB) available for the installer.
- Confirm the correct power supply is connected (Qotom/reserved: 12V; NUC: 19V — **do not interchange**).
- Have physical keyboard and monitor access for the install.

---

## Phase 1 — Debian 13 OS Install

### 1.1 Create installation media

Download the Debian 13 (Trixie) `amd64` netinst ISO from `debian.org`.
Write it to a USB stick:

```bash
# On the dev machine — replace /dev/sdX with the USB device
sudo dd if=debian-13-amd64-netinst.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

### 1.2 BIOS setup

Boot the target machine and enter BIOS:

| Hardware | BIOS key |
|----------|----------|
| Qotom Q305P | `Del` or `F2` |
| Intel NUC DC3217IYE | `F2` |

In BIOS:

- Set USB as the first boot device.
- Disable Secure Boot if present.
- Save and exit.

### 1.3 Partition layout

At the Debian installer partitioning step, set up partitions manually:

**Qotom Q305P (.80 / .82) — two drives:**

| Drive | Partition | Size | Mount | Filesystem |
|-------|-----------|------|-------|------------|
| mSATA | sda1 | ~18 GB | `/` | ext4 |
| mSATA | sda2 | 2 GB | swap | swap |
| 2.5" SATA | sdb1 | all | `/data` | ext4 |

**Intel NUC DC3217IYE (.81) — mSATA only:**

| Partition | Size | Mount | Filesystem |
|-----------|------|-------|------------|
| sda1 | ~18 GB | `/` | ext4 |
| sda2 | 2 GB | swap | swap |
| sda4 | remainder | `/data` | ext4 |

> The `/data` partition holds the database and backups. It is never covered by
> overlayroot and is always mounted read-write. See `docs/03-read-only-filesystem.md`.

### 1.4 Software selection

At the "Software selection" step, deselect everything except:

- [x] SSH server
- [x] standard system utilities

Do not install a desktop environment — the kiosk session is configured separately.

### 1.5 Post-install user

The installer creates a user during setup. Use `kiosk` as the username.

After first boot, verify SSH access from the dev machine:

```bash
ssh kiosk@192.168.1.XX
```

---

## Phase 2 — Kiosk Base Setup

All steps in this phase run **on the target host** unless noted.

### 2.1 Copy the installer

From the dev machine:

```bash
# Package the installer from canonical source
cd /home/security/Public-Kiosk
tools/package-install.sh

# Copy to target host
scp -r dist/install/building-directory-install kiosk@192.168.1.XX:~
```

### 2.2 Run install.sh

On the target host:

```bash
cd ~/building-directory-install
bash install.sh
```

When prompted:

| Prompt | Answer |
|--------|--------|
| Installation type | `3` (Both Server and Client) |
| Load sample data | `n` |
| Enable HTTP Basic Auth | `n` (systems are physically secure) |
| Restrict to IP/CIDR | `n` |
| Install Elo legacy driver (IntelliTouch/2700) | `n` — the Elo 3239L (ET3239L-8CNA) is PCAP/USB HID; no legacy driver needed |
| Reboot now | `n` — complete Phase 2 steps first |

### 2.3 Fix overlayroot configuration

The install script writes a minimal `overlayroot.conf`. Replace it with the
correct value that prevents `/data` from being overlaid:

```bash
echo 'overlayroot="tmpfs:swap=1,recurse=0"' | sudo tee /etc/overlayroot.conf
```

> `recurse=0` is critical. Without it, database writes on `/data` are lost on
> reboot. See `docs/03-read-only-filesystem.md` for details.

### 2.4 Verify /data mounts correctly

```bash
grep /data /etc/fstab
# Expected: an entry for the /data partition
mount | grep ' on /data '
# Expected: /dev/sda4 (or sdb1) on /data type ext4 (rw,relatime)
```

If `/data` is not in `fstab`, add it:

```bash
# Find the /data device UUID
sudo blkid | grep /data-device
# Add to /etc/fstab:
# UUID=xxxx  /data  ext4  defaults  0  2
```

### 2.5 Reboot and verify overlayroot

```bash
sudo reboot
```

After reboot, SSH back in and confirm:

```bash
mount | grep overlayroot
# Expected: overlayroot on / type overlay ...

mount | grep root-ro
# Expected: /dev/sda1 on /media/root-ro type ext4 (ro,relatime)

mount | grep ' on /data '
# Expected: /dev/sda4 on /data type ext4 (rw,relatime)
```

Confirm from the dev machine using kioskctl:

```bash
cd /home/security/Public-Kiosk
kiosk-fleet/kioskctl status
# Expected: overlayroot=1, root_ro_lower=ro
```

---

## Phase 3 — Application Deploy

All steps run **from the dev machine** unless noted.

### 3.1 Full deploy

```bash
cd /home/security/Public-Kiosk
tools/deploy-ssh.sh --full --host kiosk@192.168.1.XX
```

This syncs server, kiosk, and scripts into the overlayroot lower layer and
restarts `directory-server`. Smoke tests run automatically at the end.

> The git working tree must be clean before deploying to protected IPs.

### 3.2 Sync the database from production

```bash
tools/sync-primary-db.sh --skip-standby
```

Or deploy with a specific DB file:

```bash
tools/deploy-ssh.sh --full --host kiosk@192.168.1.XX \
  --with-db --db-source /home/security/building-directory/server/directory.db
```

### 3.3 Verify the server

```bash
tools/smoke-test.sh --url http://192.168.1.XX
```

All tests should pass. If any fail, check `directory-server` on the target:

```bash
ssh kiosk@192.168.1.XX 'sudo journalctl -u directory-server -n 50 --no-pager'
```

---

## Phase 4 — Display and Touchscreen

### 4.1 Physical connections

Connect the Elo 3239L (ET3239L-8CNA) to the host:

| Cable | From | To |
|-------|------|----|
| HDMI (via DVI-to-HDMI adapter) | Host HDMI port | Display DVI-I input |
| USB | Display USB-B | Host USB port |

> The touch signal travels over USB, not HDMI. Both cables are required.
> The DVI-to-HDMI adapter is a passive converter — the host sees a standard HDMI display.

### 4.2 Verify touchscreen detection

```bash
# Confirm USB HID device is present
lsusb | grep -i elo
# Expected: Bus ... ID 04e7:0020 Elo TouchSystems 2700 IntelliTouch

# Confirm kernel recognises the device
sudo dmesg | grep -i elo

# Confirm libinput sees it
sudo libinput list-devices | grep -A5 -i elo
```

### 4.3 Verify udev rules are applied

The install script deploys `99-elo-usb-power.rules` (disables USB autosuspend).
Confirm the pointer/touch conflict fix rule is also present:

```bash
ls /etc/udev/rules.d/99-elo-touchscreen.rules
```

If missing, create it:

```bash
sudo tee /etc/udev/rules.d/99-elo-touchscreen.rules <<'EOF'
SUBSYSTEM=="input", ATTRS{idVendor}=="04e7", ATTRS{idProduct}=="0020", ENV{ID_INPUT_MOUSE}="0"
SUBSYSTEM=="input", ATTRS{idVendor}=="04e7", ATTRS{idProduct}=="0020", ENV{ID_INPUT_JOYSTICK}="0"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Then unplug and replug the touchscreen USB, or reboot.
See `docs/elo-cage-wayland-kiosk-hardening.md` for full detail.

### 4.4 Verify the kiosk session

The kiosk should start automatically on `tty1` after login. Confirm on the physical display — Chromium should be fullscreen showing the directory.

From the dev machine:

```bash
kiosk-fleet/kioskctl status
```

Expected output (all hosts):

```
overlayroot=1
root_ro_lower=ro
ssh=active
getty@tty1=active
cage=running
chromium=running
fan=none          # Qotom (fanless)
fan=XXXX RPM      # NUC (active cooling) — or "none" if hwmon driver not loaded
failed_units_unexpected:
  none
recent_log_errors_unexpected:
  none
```

### 4.5 Touch verification

Plug in a USB keyboard to exit the kiosk session and open XFCE. Then test touch input directly:

```bash
sudo evtest
# Select the Elo event device
# Touch the screen — confirm coordinate events appear
```

Unplug the keyboard. The kiosk session restarts automatically.

---

## Post-Install

- Remove the USB installer stick.
- Update `kiosk-fleet/hosts` if the new host is not already listed.
- Run `kiosk-fleet/kioskctl status` from the dev machine to confirm the host appears healthy.
- For `.81` specifically: work through `docs/standby-81-todo.md` once the host is stable.
