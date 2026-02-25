# Development Workflow

This document covers the end-to-end workflow for modifying and deploying the
Building Directory Kiosk on the `kiosk-dev` VirtualBox VM.

---

## Environment

| Item | Value |
|------|-------|
| Source tree | `/home/security/Public-Kiosk/` |
| VM name | `kiosk-dev` |
| VM IP | `192.168.1.127` |
| VM user | `merrill` |
| Admin UI | `http://192.168.1.127/admin` |
| Kiosk UI | `http://192.168.1.127/` |

---

## Source tree layout

```
building-directory-install/
├── deploy.sh                       # One-shot deploy to VM
├── install.sh                      # First-time installation script (Debian 13)
├── server/
│   ├── server.js                   # Express API server (Node.js)
│   ├── persist-upload.sh           # Privileged helper — copy/delete files in lower layer
│   ├── test.js                     # Server integration tests (run locally)
│   ├── admin/
│   │   ├── index.html              # Admin UI
│   │   ├── admin.js                # Admin UI logic
│   │   └── admin.css               # Admin UI styles
│   └── package.json
├── kiosk/
│   ├── index.html                  # Kiosk display page
│   ├── app.js                      # Kiosk logic (polling, search, idle reset)
│   └── styles.css                  # Kiosk styles
└── scripts/
    ├── start-kiosk.sh              # Launches cage + Chromium
    ├── restart-kiosk.sh            # pkill cage (triggers loop restart)
    ├── kiosk-keyboard-added.sh     # Called by udev on keyboard insertion
    └── 99-kiosk-keyboard.rules     # udev rule: keyboard add → stop kiosk
```

---

## 1. Start the VM

The VM is a VirtualBox machine managed from the host with `VBoxManage`.

**Headless** (server work, no display needed):
```bash
VBoxManage startvm "kiosk-dev" --type headless
```

**With display** (testing the kiosk UI or keyboard detection):
```bash
VBoxManage startvm "kiosk-dev"
```

Wait for SSH to become available (usually 15–20 seconds):

```bash
until ssh -o ConnectTimeout=2 merrill@192.168.1.127 true 2>/dev/null; do
    sleep 2; echo -n "."
done && echo "ready"
```

> **Display resolution**: `start-kiosk.sh` runs `wlr-randr` inside the cage
> session to auto-detect the connected output and set 1920x1080. This works
> without configuration on both the VM (Virtual-1) and physical hardware (HDMI-1).

---

## 2. Modify the code

All source lives in the repo on the **host machine**. Edit files there; the
VM never holds the source of truth.

### Server (API + admin UI)

| File | What to change |
|------|----------------|
| `server/server.js` | API routes, business logic, upload/delete handling |
| `server/admin/index.html` | Admin page structure |
| `server/admin/admin.js` | Admin page behaviour |
| `server/admin/admin.css` | Admin page styles |
| `server/persist-upload.sh` | Privileged persist/delete script (runs via sudo on VM) |

### Kiosk client

| File | What to change |
|------|----------------|
| `kiosk/index.html` | Kiosk page structure |
| `kiosk/app.js` | Kiosk behaviour (search, idle timeout, background polling) |
| `kiosk/styles.css` | Kiosk visual styles |
| `scripts/start-kiosk.sh` | cage launch options, Chromium flags |
| `scripts/kiosk-keyboard-added.sh` | Logic run when a keyboard is plugged in |
| `scripts/99-kiosk-keyboard.rules` | udev match rule for keyboard insertion |

---

## 3. Test locally before deploying

### Server tests

```bash
cd building-directory-install/server
node test.js
```

Starts a real Express server on port 3099 with a temp SQLite DB and a
mock persist script; exercises all background-image endpoints. Cleans up
after itself. Requires Node.js and dependencies:

```bash
npm install   # first time only
```

---

## 4. Deploy to the VM

```bash
cd building-directory-install
./deploy.sh
```

The script handles everything; no manual SSH steps are needed.

### What deploy.sh does

1. **SCP** all changed files to `/tmp/deploy-staging/` on the VM.
2. **Move to `/run/deploy-stage/`** — this directory is bind-mounted inside
   `overlayroot-chroot`, making files accessible from within the chroot.
   `/tmp` is *not* bind-mounted and cannot be used as a source.
3. **Write to the ext4 lower layer** via `overlayroot-chroot` for every
   destination path:
   - `/usr/local/bin/persist-upload.sh` (chmod 755)
   - `/usr/local/bin/kiosk-keyboard-added.sh` (chmod 755)
   - `/etc/udev/rules.d/99-kiosk-keyboard.rules`
   - `/etc/sudoers.d/directory-server` (chmod 440)
   - `/home/merrill/building-directory/server/` (server files)
   - `/home/merrill/building-directory/scripts/` (kiosk scripts)
   - `/home/merrill/.bash_profile` (kiosk loop + XFCE fallback)
   - `/etc/nginx/sites-available/directory` (nginx config)
   - `/home/merrill/building-directory/server/uploads/` (created if absent)
4. **Drop the kernel dentry cache** (`echo 3 > /proc/sys/vm/drop_caches`) —
   new files written to the lower layer are invisible to the running overlay
   until the cache is dropped; this avoids requiring a reboot.
5. **Reload udev rules** so the keyboard detection rule takes effect immediately.
6. **Reload nginx** to pick up any config changes.
7. **Restart `directory-server`** systemd service.

---

## 5. Verify the deployment

```bash
# Server is running
ssh merrill@192.168.1.127 "sudo systemctl is-active directory-server"

# Admin UI loads
curl -s -o /dev/null -w "%{http_code}" http://192.168.1.127/admin

# API responds
curl -s http://192.168.1.127/api/background-image
curl -s http://192.168.1.127/api/background-images
```

---

## 6. Shut down the VM

```bash
VBoxManage controlvm "kiosk-dev" acpipowerbutton
```

Wait a few seconds, then confirm:

```bash
VBoxManage showvminfo "kiosk-dev" | grep "State:"
```

---

## Overlayroot constraints

The VM filesystem is a read-only overlayfs. Understanding this prevents
surprises:

| What you want to do | How to do it |
|---------------------|-------------|
| Write a file that persists across reboots | `overlayroot-chroot cp /run/<staged> <dest>` |
| Make a new lower-layer file visible immediately | `echo 3 \| sudo tee /proc/sys/vm/drop_caches > /dev/null` |
| Install a package that must survive reboot | `sudo overlayroot-chroot apt-get install -y <pkg>` |
| Write a file only needed until next reboot | Write directly to `/tmp` or `/run` (tmpfs) |
| Stage a file for use inside `overlayroot-chroot` | Copy to `/run/` — it is bind-mounted; `/tmp` is not |

The `deploy.sh` script encapsulates all of this so day-to-day work does
not require thinking about the overlay.

---

## Admin access: keyboard detection

On the physical kiosk (and in the VM with USB passthrough), plugging in a
USB keyboard stops the kiosk and launches XFCE on the touchscreen.

### How it works

1. udev rule `/etc/udev/rules.d/99-kiosk-keyboard.rules` matches
   `ACTION=add, SUBSYSTEM=input, ID_BUS=usb, ID_INPUT_KEYBOARD=1`.
   The `ID_BUS=usb` filter prevents spurious triggers from virtual/PS2/AT
   keyboards (relevant in VirtualBox; not an issue on physical hardware).
2. udev runs `/usr/local/bin/kiosk-keyboard-added.sh` as root.
3. The script reads the autologin username from `autologin.conf`, touches
   `/tmp/kiosk-exit` owned by that user, and calls `pkill cage`.
   (`/tmp` has the sticky bit; the file must be owned by the kiosk user so
   `.bash_profile` can delete it with `rm -f`.)
4. cage exits → `start-kiosk.sh` returns → `.bash_profile` loop detects
   `/tmp/kiosk-exit` → calls `startxfce4`.
5. XFCE opens on the touchscreen. Admin uses keyboard + touch for maintenance.
   XFCE/Xorg state is redirected to `/tmp` because overlayroot mounts `/` as
   read-only (`XAUTHORITY`, `ICEAUTHORITY`, `XDG_*` all point to `/tmp`).
6. Admin logs out of XFCE → `startxfce4` returns → loop removes sentinel →
   loop restarts the kiosk.

Touchscreens use `ID_INPUT_TOUCHSCREEN=1` and do **not** match the rule.

### Testing keyboard detection in the VM

**Quick SSH simulation** (no physical keyboard needed):

```bash
ssh merrill@192.168.1.127 "sudo /usr/local/bin/kiosk-keyboard-added.sh"
# XFCE opens; to restart the kiosk:
ssh merrill@192.168.1.127 "DISPLAY=:0 xfce4-session-logout --logout"
```

**Full USB passthrough test** (closest to physical hardware):

1. **Set up a USB filter** in VirtualBox Manager:
   - VM Settings → USB → click **+** to add a filter
   - Plug in the keyboard you'll use for testing; it appears in the list
   - Select it and click OK
2. **Start the VM with display** (`VBoxManage startvm "kiosk-dev"`)
3. With the kiosk running, **plug the keyboard in** on the host — VirtualBox
   passes the device through to the VM, udev fires, cage stops, XFCE opens.
4. **Log out of XFCE** — the kiosk restarts automatically.

> **Note**: while the keyboard is passed through to the VM, it is not
> available to the host. Use a second keyboard or SSH for host-side work
> during testing.

---

## Persistent image uploads

Images uploaded through the admin Appearance tab are written to the ext4
lower layer at:

```
/media/root-ro/home/merrill/building-directory/server/uploads/
```

via `sudo /usr/local/bin/persist-upload.sh`. They survive reboots.
The built-in `18.jpg` is served from the kiosk static directory and is
not deletable.
