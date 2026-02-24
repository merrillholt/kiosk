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
├── deploy.sh                   # One-shot deploy to VM
├── install.sh                  # First-time installation script
├── server/
│   ├── server.js               # Express API server (Node.js)
│   ├── persist-upload.sh       # Privileged helper — copy/delete files in lower layer
│   ├── test.js                 # Server integration tests (run locally)
│   ├── admin/
│   │   ├── index.html          # Admin UI
│   │   ├── admin.js            # Admin UI logic
│   │   └── admin.css           # Admin UI styles
│   └── package.json
├── kiosk/
│   ├── index.html              # Kiosk display page
│   ├── app.js                  # Kiosk logic (polling, search, idle reset)
│   └── styles.css              # Kiosk styles
└── scripts/
    ├── start-kiosk.sh          # Launches cage + kiosk-breakout.py
    ├── kiosk-breakout.py       # Watches raw input for breakout key combo
    ├── test-breakout.py        # Unit tests for kiosk-breakout.py
    └── restart-kiosk.sh        # pkill cage (triggers autorestart)
```

---

## 1. Start the VM

The VM is a VirtualBox machine managed from the host with `VBoxManage`.

```bash
VBoxManage startvm "kiosk-dev" --type headless
```

Wait for SSH to become available (usually 15–20 seconds):

```bash
until ssh -o ConnectTimeout=2 merrill@192.168.1.127 true 2>/dev/null; do
    sleep 2; echo -n "."
done && echo "ready"
```

---

## 2. Modify the code

All source lives in the repo on the **host machine**. Edit files there; the
VM never holds the source of truth.

### Server (API + admin UI)

| File | What to change |
|------|---------------|
| `server/server.js` | API routes, business logic, upload/delete handling |
| `server/admin/index.html` | Admin page structure |
| `server/admin/admin.js` | Admin page behaviour |
| `server/admin/admin.css` | Admin page styles |
| `server/persist-upload.sh` | Privileged persist/delete script (runs via sudo on VM) |

### Kiosk client

| File | What to change |
|------|---------------|
| `kiosk/index.html` | Kiosk page structure |
| `kiosk/app.js` | Kiosk behaviour (search, idle timeout, background polling) |
| `kiosk/styles.css` | Kiosk visual styles |
| `scripts/start-kiosk.sh` | cage launch options, breakout combo |
| `scripts/kiosk-breakout.py` | Breakout key watcher logic |

---

## 3. Test locally before deploying

Running tests locally catches most bugs without a deploy round-trip.

### Server tests

```bash
cd building-directory-install/server
node test.js
```

Starts a real Express server on port 3099 with a temp SQLite DB and a
mock persist script; exercises all background-image endpoints. Cleans up
after itself. Expects Node.js and dependencies installed:

```bash
npm install   # first time only
```

### Breakout watcher tests

```bash
cd building-directory-install/scripts
python3 test-breakout.py
```

Unit-tests combo detection logic, `do_breakout()`, `parse_combo()`, and
`open_keyboards()` via mocks — no hardware or `/dev/uinput` access needed.

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
   - `/etc/sudoers.d/directory-server` (chmod 440)
   - `/home/merrill/building-directory/server/` (server files)
   - `/home/merrill/building-directory/scripts/` (kiosk scripts)
   - `/etc/nginx/sites-available/directory` (nginx config)
   - `/home/merrill/building-directory/server/uploads/` (created if absent)
4. **Drop the kernel dentry cache** (`echo 3 > /proc/sys/vm/drop_caches`) —
   new files written to the lower layer are invisible to the running overlay
   until the cache is dropped; this avoids requiring a reboot.
5. **Install `python3-evdev`** via `overlayroot-chroot apt-get install` if
   not already present (regular `apt` cannot write to its cache on the
   read-only overlay).
6. **Reload nginx** to pick up any config changes.
7. **Restart `directory-server`** systemd service.

### Deploy a single file quickly

If only one file changed, you can push it manually rather than running the
full deploy:

```bash
# Example: update just server.js
scp server/server.js merrill@192.168.1.127:/tmp/server.js
ssh merrill@192.168.1.127 "
  sudo cp /tmp/server.js /run/server.js
  sudo overlayroot-chroot cp /run/server.js /home/merrill/building-directory/server/server.js
  sudo rm /run/server.js
  echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
  sudo systemctl restart directory-server
"
```

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
| Install a package | `sudo overlayroot-chroot apt-get install -y <pkg>` |
| Write a file only needed until next reboot | Write directly to `/tmp` or `/run` (tmpfs) |
| Stage a file for use inside `overlayroot-chroot` | Copy to `/run/` — it is bind-mounted; `/tmp` is not |

The `deploy.sh` script encapsulates all of this so day-to-day work does
not require thinking about the overlay.

---

## Kiosk breakout key

When the physical kiosk is running (cage compositor, Chromium fullscreen),
press **Right-Shift + Right-Ctrl + Backspace** to kill cage and return to
the tty1 shell. This is handled by `kiosk-breakout.py` which runs in the
background alongside cage.

To change the combo, edit the `--combo` argument in `scripts/start-kiosk.sh`:

```bash
python3 kiosk-breakout.py --combo KEY_RIGHTSHIFT,KEY_RIGHTCTRL,KEY_BACKSPACE
```

Key names are evdev constants (`KEY_*`). After changing, redeploy with
`./deploy.sh`.

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
