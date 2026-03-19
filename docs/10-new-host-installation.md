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

**Qotom Q305P (.80 / .82) — single mSATA SSD (confirmed on .80):**

| Partition | Size | Mount | Filesystem |
|-----------|------|-------|------------|
| sda1 | ~1 GB | EFI | vfat |
| sda2 | ~20 GB | `/` | ext4 |
| sda3 | ~1.5 GB | swap | swap |
| sda4 | remainder | `/data` | ext4 |

The Qotom has a 2.5" SATA bay but both .80 and .82 use the mSATA drive for all
partitions. The 2.5" bay can hold a second drive if additional `/data` capacity
is needed, but this has not been used in practice.

**Intel NUC DC3217IYE (.81) — mSATA only:**

| Partition | Size | Mount | Filesystem |
|-----------|------|-------|------------|
| sda1 | ~1 GB | EFI | vfat |
| sda2 | ~20 GB | `/` | ext4 |
| sda3 | ~1.5 GB | swap | swap |
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

The Debian installer does not add `kiosk` to the sudo group automatically.
After first boot, add it via `su`:

```bash
su -
adduser kiosk sudo
exit
```

Then log out and back in as `kiosk` for the group membership to take effect.

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
| Installation type | `3` (Both Server and Client) for `.80`; `2` (Client only) for `.82` |
| Load sample data | `n` |
| Enable HTTP Basic Auth | `n` (systems are physically secure) |
| Restrict to IP/CIDR | `n` |
| Install optional Elo legacy touchscreen driver bundle | `y` — required for the Elo 3239L; installs `elomtusbd` userspace daemon and `uinput` module |
| Reboot now | `n` — complete Phase 2 steps first |

### 2.3 Add GRUB maintenance entry

Add a GRUB menu entry that boots with `overlayroot=disabled` (writable root).
This must be done before the first reboot into overlayroot — once overlayroot
is active, GRUB changes must go through `overlayroot-chroot`.

On the target host:

```bash
# Get the root partition UUID and current kernel version
ROOT_UUID=$(sudo blkid -s UUID -o value $(findmnt -n -o SOURCE /))
KERNEL=$(ls /boot/vmlinuz-* | sort -V | tail -1 | sed 's|/boot/vmlinuz-||')

sudo tee /etc/grub.d/40_custom > /dev/null <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry "Debian Kiosk — MAINTENANCE (writable root)" {
    insmod gzio
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /boot/vmlinuz-${KERNEL} root=UUID=${ROOT_UUID} ro overlayroot=disabled quiet
    initrd /boot/initrd.img-${KERNEL}
}
EOF

sudo chmod +x /etc/grub.d/40_custom
sudo update-grub
```

Confirm the entry appears in the GRUB menu output:

```bash
grep -A1 "MAINTENANCE" /boot/grub/grub.cfg
```

### 2.4 Fix overlayroot configuration

The install script writes a minimal `overlayroot.conf`. Replace it with the
correct value that prevents `/data` from being overlaid:

```bash
echo 'overlayroot="tmpfs:swap=1,recurse=0"' | sudo tee /etc/overlayroot.conf
```

> `recurse=0` is critical. Without it, database writes on `/data` are lost on
> reboot. See `docs/03-read-only-filesystem.md` for details.

### 2.5 Verify /data mounts correctly

```bash
grep /data /etc/fstab
# Expected: an entry for the /data partition
mount | grep ' on /data '
# Expected: /dev/sda4 on /data type ext4 (rw,relatime)
```

If `/data` is not in `fstab`, add it:

```bash
# Find the /data device UUID
sudo blkid | grep /data-device
# Add to /etc/fstab:
# UUID=xxxx  /data  ext4  defaults  0  2
```

### 2.6 Install SSH key for passwordless access

This must be done before the overlayroot reboot — once overlayroot is active,
writes to the home directory are lost on reboot.

From the dev machine:

```bash
ssh-copy-id kiosk@192.168.1.XX
```

### 2.7 Reboot and verify overlayroot

```bash
sudo reboot
```

After reboot, SSH back in and confirm:

```bash
mount | grep overlayroot
# Expected: overlayroot on / type overlay ...

mount | grep root-ro
# Expected: /dev/sda2 on /media/root-ro type ext4 (ro,relatime)

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

### 4.2 Verify the Elo driver is installed

The install script runs `scripts/install-elo-driver.sh` which copies the Elo
MT USB driver bundle to `/etc/opt/elo-mt-usb/` and enables `elo.service`.

```bash
# Confirm driver files are present
ls /etc/opt/elo-mt-usb/elomtusbd

# Confirm service is enabled (it runs at boot; exits after initialising uinput)
systemctl is-enabled elo.service

# Confirm uinput module is loaded
lsmod | grep uinput
```

**How the driver works on `.80` (confirmed):** `elo.service` runs
`loadEloMultiTouchUSB.sh` at boot, which launches `elomtusbd --stdigitizer`.
The daemon registers a uinput virtual device and exits. Touch input is then
handled by the `hid-generic` kernel driver, which presents the Elo 2700
controller as an absolute pointer on `/dev/input/event*`. This is the
production-confirmed working configuration.

### 4.3 Verify touchscreen detection

```bash
# Confirm USB device is present
lsusb | grep -i elo
# Expected: Bus ... ID 04e7:0020 Elo TouchSystems 2700 IntelliTouch

# Confirm kernel recognised the device and assigned it an event node
sudo dmesg | grep -i elo
# Expected: hid-generic ... input,hidraw: USB HID ... Pointer [Elo ...]

# Confirm the input device is present
sudo libinput list-devices | grep -A5 -i elo
# Expected: Capabilities: pointer  (absolute pointing device)
```

### 4.4 Verify udev rules are applied

Two udev rules are installed by the installer:

| Rule file | Purpose |
|-----------|---------|
| `99-elotouch.rules` | USB device permissions (mode 0666 for vendor `04e7`) |
| `99-elo-usb-power.rules` | Disables USB autosuspend on the Elo device |

```bash
ls /etc/udev/rules.d/99-elotouch.rules
ls /etc/udev/rules.d/99-elo-usb-power.rules
```

Both must be present. If either is missing, re-run `scripts/install-elo-driver.sh`.

### 4.5 Verify the kiosk session

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
kiosk-guard=active
cage=running
chromium=running
fan=none          # Qotom (fanless)
fan=XXXX RPM      # NUC (active cooling) — or "none" if hwmon driver not loaded
failed_units_unexpected:
  none
recent_log_errors_unexpected:
  none
```

On the host directly, you can also confirm the watchdog is enabled:

```bash
systemctl is-enabled kiosk-guard.service
systemctl status kiosk-guard.service --no-pager
```

### 4.6 Touch verification

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
