# Building Directory Kiosk — Developer & Maintainer Guide

---

## Architecture

The system consists of one **server** and three **kiosk display clients**.

```
┌─────────────────────────────────────────────┐
│  Server machine                             │
│  ├─ Node.js (Express + SQLite)  :3000       │
│  ├─ nginx (reverse proxy)       :80         │
│  ├─ Admin UI    → /admin                    │
│  ├─ Kiosk app   → /  (HTML/JS/CSS)          │
│  └─ API         → /api                      │
└──────────────────┬──────────────────────────┘
                   │  HTTP (LAN)
       ┌───────────┼───────────┐
       ▼           ▼           ▼
  Kiosk 1      Kiosk 2      Kiosk 3
  cage +        cage +        cage +
  Chromium      Chromium      Chromium
  (display      (display      (display
   only)         only)         only)
```

**Server** runs the Node.js application, SQLite database, nginx, and serves
both the admin UI and the kiosk browser application. All directory data lives
here.

**Kiosk display clients** run cage (Wayland kiosk compositor) + Chromium
pointing at the server. They display the directory and respond to touch. They
have no local database or application server — they are thin clients. All three
kiosk machines use **overlayroot** (read-only root filesystem) for
power-failure resilience.

**How updates propagate:**

| Change type | How it reaches kiosks |
|-------------|----------------------|
| Directory data (companies, people, info) | Admin UI → server DB → kiosks poll `/api/data-version` every 60 s and reload |
| Kiosk browser app (HTML/JS/CSS/app.js) | Deploy to server → kiosks load it from server automatically |
| Background image | Admin UI Appearance tab → stored on server → kiosks reload |
| System scripts (start-kiosk.sh, .bash_profile, udev rules) | Admin UI Deploy tab → SSH → direct lower-layer write to `/media/root-ro`, then reboot |

---

## Source Tree

`building-directory-install/scripts/` is a generated install-tree copy of
canonical files from the repository root. Edit the root `scripts/` files, then
regenerate the install tree with:

```bash
./tools/sync-install-tree.sh
./tools/check-install-drift.sh
```

This regeneration step also rebuilds PDF versions of the Markdown docs into:

```bash
building-directory-install/docs/
```

Do not hand-edit duplicated files under `building-directory-install/scripts/`.

```
building-directory-install/
├── deploy.sh                       # Deploy server files to a remote machine
├── install.sh                      # First-time installation (server / client / both)
├── server/
│   ├── server.js                   # Express API + kiosk deploy endpoints
│   ├── server.js                   # Express API + kiosk deploy endpoints
│   ├── persist-upload.sh           # Privileged helper: copy/delete uploads in lower layer
│   ├── test.js                     # API integration tests (run locally)
│   ├── admin/
│   │   ├── index.html              # Admin UI (Companies / Individuals / Building Info /
│   │   ├── admin.js                #           Appearance / Deploy tabs)
│   │   └── admin.css
│   └── package.json
├── kiosk/
│   ├── index.html                  # Kiosk display page
│   ├── app.js                      # Kiosk logic (search, idle timeout, data-version polling)
│   └── styles.css
└── scripts/                        # Generated copies from ../scripts/ for packaging/install
    ├── bash_profile
    ├── start-kiosk.sh
    ├── restart-kiosk.sh
    ├── kiosk-keyboard-added.sh
    └── 99-kiosk-keyboard.rules
```

---

## Installation

### Server

Run on the machine that will serve the application. Requires Debian 13.

```bash
cd building-directory-install
./install.sh
# Select: 1) Server
```

The installer:
- Installs Node.js (LTS), nginx, sqlite3
- Copies server files to `~/building-directory/`
- Runs `npm install`
- Installs `persist-upload.sh` to `/usr/local/bin/` with sudoers entry
- Installs `tools/deploy-ssh.sh` and `manifest/deploy-client-files.txt`
- Creates and enables the `directory-server` systemd service
- Configures nginx as a reverse proxy on port 80
- Starts the server

After installation:
```
Admin UI:  http://<server-ip>/admin
Kiosk app: http://<server-ip>/
```

**Note:** The server auto-detects its LAN IP for use as `KIOSK_SERVER_URL`
(the URL pushed to kiosk machines during deploy). If the auto-detected IP is
wrong (e.g. multiple network interfaces), override it by adding to the
systemd service environment:

```bash
sudo systemctl edit directory-server
# Add:
# [Service]
# Environment=KIOSK_SERVER_URL=http://192.168.1.x
```

---

### Kiosk Display Clients

Run on each of the three kiosk display machines. Requires Debian 13.

```bash
cd building-directory-install
./install.sh
# Select: 2) Kiosk Client
# Enter server IP when prompted (e.g. 192.168.1.100)
```

The installer:
- Installs cage, Chromium, wlr-randr, XFCE4, Xorg, overlayroot
- Copies kiosk scripts to `~/building-directory/scripts/`
- Patches server URL defaults in `start-kiosk-lib.sh`
- Installs the udev keyboard detection rule
- Configures getty autologin on tty1
- Writes `.bash_profile` (kiosk loop + XFCE fallback)
- Masks PulseAudio user units in `/etc/systemd/user`
- Removes `pam_wtmpdb` from `/etc/pam.d/common-session`
- Installs the Broadcom Wi-Fi blacklist for wired kiosk deployments
- Configures overlayroot (read-only root on next boot)
- Prompts to reboot (required to activate overlayroot and start the kiosk)

After reboot, Chromium opens fullscreen automatically displaying the kiosk UI.

---

### SSH Deploy Key Setup

The Deploy tab in the admin UI uses SSH to push system script updates to kiosk
machines. One-time setup per kiosk machine:

**1. Generate the deploy key** (done automatically on first Deploy tab load):

Open `http://<server-ip>/admin` → Deploy tab. The server generates an ed25519
key pair at `~/.ssh/kiosk_deploy_key` on first access. The public key is
displayed on the page.

**2. Authorize the key on each kiosk machine:**

Copy the public key from the Deploy tab, then on each kiosk machine:

```bash
# SSH in while kiosk is not yet overlayroot, OR use overlayroot-chroot:
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "<paste public key here>" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

If the kiosk is already running with overlayroot, write via chroot so the key
persists:
```bash
sudo overlayroot-chroot bash -c "
  mkdir -p /home/kiosk/.ssh && chmod 700 /home/kiosk/.ssh
  echo '<public key>' >> /home/kiosk/.ssh/authorized_keys
  chmod 600 /home/kiosk/.ssh/authorized_keys
"
```

**3. Configure kiosk IPs** in `server/server.js` (see [Configuring Kiosk
Machines](#configuring-kiosk-machines) below).

---

## Development Environment

The development VM (`kiosk-dev`) is a VirtualBox machine running the kiosk
client role. Use it to test kiosk display behaviour and system script changes
without touching production hardware.

| Item | Value |
|------|-------|
| Source tree | `/home/security/Public-Kiosk/` |
| VM name | `kiosk-dev` |
| VM IP | `192.168.1.127` |
| VM user | `merrill` |
| Admin UI (on server) | `http://<server-ip>/admin` |
| Kiosk UI on VM | `http://192.168.1.127/` (runs local server for dev) |

**Start the VM:**

```bash
# Headless (SSH only):
VBoxManage startvm "kiosk-dev" --type headless

# With display (test kiosk UI or keyboard detection):
VBoxManage startvm "kiosk-dev"
```

Wait for SSH:
```bash
until ssh -o ConnectTimeout=2 merrill@192.168.1.127 true 2>/dev/null; do
    sleep 2; echo -n "."
done && echo "ready"
```

**Shut down the VM:**
```bash
VBoxManage controlvm "kiosk-dev" acpipowerbutton
VBoxManage showvminfo "kiosk-dev" | grep "State:"
```

> **Display resolution:** the current kiosk launcher does not force display
> resolution. Chromium is started directly inside `cage`, and the display uses
> the compositor/kernel-selected mode for the connected panel.

---

## Development Workflow

All source lives in the repo on this machine. Edit files here; deployed
machines never hold the source of truth.

### What to edit

**Server / admin UI:**

| File | What to change |
|------|----------------|
| `server/server.js` | API routes, business logic, image handling, deploy endpoints |
| `server/admin/index.html` | Admin page structure and tabs |
| `server/admin/admin.js` | Admin page behaviour |
| `server/admin/admin.css` | Admin page styles |
| `server/persist-upload.sh` | Privileged helper for writing images to overlayroot lower layer |
| `tools/deploy-ssh.sh` | Explicit `--client/--server/--full` SSH deploy tool |

**Kiosk browser app** (served from server, auto-updates to all clients):

| File | What to change |
|------|----------------|
| `kiosk/index.html` | Kiosk page structure |
| `kiosk/app.js` | Search, idle timeout, data-version polling |
| `kiosk/styles.css` | Visual styles |

**Kiosk system scripts** (live on each kiosk machine, require explicit deploy):

| File | What to change |
|------|----------------|
| `scripts/start-kiosk.sh` | cage launch options, Chromium flags, SERVER_URL |
| `scripts/bash_profile` | Autologin loop, XFCE fallback, environment setup |
| `scripts/kiosk-keyboard-added.sh` | Logic run when a USB keyboard is plugged in |
| `scripts/99-kiosk-keyboard.rules` | udev match rule for keyboard insertion |

### Running locally for development

```bash
cd building-directory-install/server
npm install          # first time only
node server.js       # runs on http://localhost:3000
```

Admin UI: `http://localhost:3000/admin`

The server uses environment variables to override default paths during
local development:

```bash
# Use a local mock persist script instead of sudo
KIOSK_PERSIST_CMD=/tmp/mock-persist.sh node server.js
```

### Running the server tests

The test suite starts a real Express server on port 3099 with a temp SQLite
database and a mock persist script, exercises all API endpoints, then cleans
up.

```bash
cd building-directory-install/server
node test.js
```

---

## Deploying Application Changes

"Application changes" are changes to the Node.js server, admin UI, or kiosk
browser app (HTML/JS/CSS). Once deployed to the server, all three kiosk
clients receive browser app updates automatically on next load.

### If the server is the development machine (this host)

Copy the changed files directly into the installed location:

```bash
INSTALL="$HOME/building-directory"
cp server/server.js            "$INSTALL/server/"
cp server/admin/index.html     "$INSTALL/server/admin/"
cp server/admin/admin.js       "$INSTALL/server/admin/"
cp server/admin/admin.css      "$INSTALL/server/admin/"
cp tools/deploy-ssh.sh         "$INSTALL/tools/"
cp kiosk/index.html            "$INSTALL/kiosk/"
cp kiosk/app.js                "$INSTALL/kiosk/"
cp kiosk/styles.css            "$INSTALL/kiosk/"
sudo systemctl restart directory-server
```

### If the server is a remote machine (or the dev VM)

```bash
cd building-directory-install
./deploy.sh [user@host]      # default: merrill@192.168.1.127
```

`deploy.sh` handles the overlayroot filesystem on the target machine:

1. **SCP** all files to `/tmp/deploy-staging/` on the target.
2. **Write to the ext4 lower layer** under `/media/root-ro`:
   - `/usr/local/bin/persist-upload.sh` (chmod 755)
   - `/usr/local/bin/kiosk-keyboard-added.sh` (chmod 755)
   - `/etc/udev/rules.d/99-kiosk-keyboard.rules`
   - `/etc/sudoers.d/directory-server` (chmod 440)
   - `/home/kiosk/building-directory/server/` (all server files)
   - `/home/kiosk/building-directory/scripts/` (kiosk scripts + bash_profile template)
   - `/home/kiosk/.bash_profile`
   - `/etc/nginx/sites-available/directory`
3. **Drop the kernel dentry cache** so new lower-layer files become visible
   to the running overlay without a reboot.
4. **Reload udev**, **reload nginx**, **restart `directory-server`**.

### Verify after deployment

```bash
TARGET=192.168.1.127   # replace with server IP

# Service running
ssh merrill@$TARGET "sudo systemctl is-active directory-server"

# Admin UI loads
curl -s -o /dev/null -w "%{http_code}" http://$TARGET/admin

# API responds
curl -s http://$TARGET/api/data-version
```

---

## Deploying System Changes to Kiosk Display Clients

System scripts (`start-kiosk.sh`, `.bash_profile`, `kiosk-keyboard-added.sh`,
`99-kiosk-keyboard.rules`) live on each kiosk machine. Changes require an
explicit deploy — the kiosk browser app auto-update mechanism does not cover
these files.

### Via the Admin UI (recommended)

1. Open `http://<server-ip>/admin` → **Deploy** tab.
2. Verify the **Server URL** shown is the correct LAN IP for the kiosks.
3. Click **Deploy** for an individual kiosk, or **Deploy to All**.
4. Watch the output log for progress and any errors.

The deploy tab calls `POST /api/kiosks/:id/deploy` on the server, which
runs `tools/deploy-ssh.sh --client` via SSH.

### Via command line

```bash
cd building-directory-install/server
bash tools/deploy-ssh.sh --client --host <kiosk_user@kiosk_ip>

# Example:
bash tools/deploy-ssh.sh --client --host merrill@192.168.1.127
```

### What `tools/deploy-ssh.sh --client` does

1. Verifies SSH connectivity to the kiosk machine.
2. Stages the client manifest on the kiosk.
3. Patches server URL defaults in `start-kiosk-lib.sh`.
4. Writes each file to the overlayroot lower layer under `/media/root-ro`.
5. Applies client-only cleanup:
   - removes `directory-backup` units
   - installs the wireless blacklist
   - masks PulseAudio user units in `/etc/systemd/user`
6. Reboots the kiosk to restore a clean overlayroot state.

Files deployed to each kiosk:

| Source | Destination on kiosk |
|--------|----------------------|
| `scripts/start-kiosk.sh` (SERVER_URL patched) | `/home/kiosk/building-directory/scripts/start-kiosk.sh` |
| `scripts/restart-kiosk.sh` | `/home/kiosk/building-directory/scripts/restart-kiosk.sh` |
| `scripts/kiosk-keyboard-added.sh` | `/usr/local/bin/kiosk-keyboard-added.sh` |
| `scripts/99-kiosk-keyboard.rules` | `/etc/udev/rules.d/99-kiosk-keyboard.rules` |
| `scripts/bash_profile` | `/home/kiosk/.bash_profile` |

Script changes take effect on the kiosk's **next cage restart** (i.e. next
keyboard-triggered XFCE session, or next reboot). The running cage session
uses the previously loaded scripts.

### Configuring kiosk machines

Kiosk IPs and usernames are set at the top of `server/server.js`:

```javascript
const KIOSK_CLIENTS = [
    { id: 1, name: 'Kiosk 1', ip: '192.168.1.127', user: 'merrill' },
    { id: 2, name: 'Kiosk 2', ip: '192.168.1.128', user: 'merrill' },
    { id: 3, name: 'Kiosk 3', ip: '192.168.1.129', user: 'merrill' },
];
```

Update these IPs when machines are provisioned, then redeploy the server. The
Deploy tab will reflect the updated list immediately.

The server URL pushed to kiosks (`KIOSK_SERVER_URL`) is auto-detected from the
server's first non-loopback IPv4 address. Override via systemd environment if
needed (see [Server installation](#server)).

---

## Admin Access: Keyboard Detection

Plugging a USB keyboard into a kiosk machine stops the kiosk and launches XFCE
on the touchscreen for local admin/maintenance access.

### How it works

1. udev rule `/etc/udev/rules.d/99-kiosk-keyboard.rules` matches
   `ACTION==add, SUBSYSTEM==input, ENV{ID_BUS}==usb, ENV{ID_INPUT_KEYBOARD}==1`.
   The `ID_BUS==usb` filter prevents spurious triggers from virtual/PS2/AT
   keyboards (relevant in VirtualBox; not an issue on physical hardware).
   Touchscreens (`ID_INPUT_TOUCHSCREEN=1`) do not match.
2. udev runs `/usr/local/bin/kiosk-keyboard-added.sh` as root.
3. The script reads the autologin username from `autologin.conf`, creates
   `/tmp/kiosk-exit` owned by that user, and calls `pkill cage`.
   (`/tmp` has the sticky bit; the file must be owned by the kiosk user so
   `.bash_profile` can delete it.)
4. cage exits → `.bash_profile` loop detects `/tmp/kiosk-exit` → redirects
   all XFCE/Xorg state to `/tmp` (overlayroot mounts `/` as read-only) →
   calls `startxfce4`.
5. XFCE opens on the touchscreen. Admin uses keyboard + touch.
6. Admin logs out of XFCE → loop removes sentinel → loop restarts the kiosk.

Unplugging the keyboard after XFCE opens has no effect — the udev rule only
fires on `ACTION==add`.

### XFCE environment on overlayroot

Because overlayroot mounts `/` as read-only, all XFCE/Xorg state is redirected
to `/tmp` in `.bash_profile`:

```
XAUTHORITY=/tmp/.Xauthority
ICEAUTHORITY=/tmp/.ICEauthority
XDG_CONFIG_HOME=/tmp/xfce4-config
XDG_CACHE_HOME=/tmp/xfce4-cache
XDG_DATA_HOME=/tmp/xfce4-data
Xorg log: -logfile /tmp/Xorg.0.log
```

This state does not persist across reboots.

### Testing keyboard detection on the dev VM

**SSH simulation** (no physical keyboard needed):
```bash
ssh merrill@192.168.1.127 "sudo /usr/local/bin/kiosk-keyboard-added.sh"
# XFCE opens; to restart the kiosk:
ssh merrill@192.168.1.127 "DISPLAY=:0 xfce4-session-logout --logout"
```

**Full USB passthrough test** (closest to physical):
1. VM Settings → USB → add a filter for the keyboard to use.
2. Start VM with display: `VBoxManage startvm "kiosk-dev"`
3. Plug in the keyboard on the host — VirtualBox passes it to the VM, udev
   fires, cage stops, XFCE opens.
4. Log out of XFCE — kiosk restarts automatically.

> While the keyboard is passed through to the VM it is unavailable to the
> host. Use a second keyboard or SSH for host-side work during the test.

---

## Environment Variables

All variables are optional. Set them in the systemd service unit for
persistent configuration:

```bash
sudo systemctl edit directory-server
# Then add under [Service]:
# Environment=VARIABLE=value
```

A documented template is at `server/.env.example`.

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3000` | TCP port the Node.js server listens on. nginx proxies 80 → this port. |
| `KIOSK_TEMP_DIR` | `/tmp/kiosk-uploads` | Temporary directory for multer image uploads. Lost on reboot; persist script copies to lower layer. |
| `KIOSK_UPLOADS_LOWER` | `/media/root-ro/…/uploads` | Persistent uploads directory on the overlayroot ext4 lower layer. Served as `/uploads`. |
| `KIOSK_PERSIST_CMD` | `sudo /usr/local/bin/persist-upload.sh` | Space-separated command for copying/deleting files in the lower layer. Set to a mock script path for local development. |
| `KIOSK_CLIENTS` | hardcoded array | JSON array of kiosk display machines: `[{"id":1,"name":"Kiosk 1","ip":"192.168.1.x","user":"merrill"},…]`. Update IPs when machines are provisioned. |
| `KIOSK_SSH_KEY` | `~/.ssh/kiosk_deploy_key` | SSH private key used by the admin Deploy tab. Auto-generated (ed25519) on first Deploy tab load. |
| `KIOSK_SERVER_URL` | auto-detected LAN IP | URL kiosk machines use to reach this server. Override if the server has multiple NICs or uses a hostname. |

---

## Overlayroot Constraints

All kiosk display machines (and the dev VM) use overlayroot. The root
filesystem is read-only; writes go to a tmpfs upper layer that is discarded
on reboot.

| Goal | How to do it |
|------|-------------|
| Write a file that survives reboot | write to `/media/root-ro/...` or use a deploy helper |
| Make a new lower-layer file visible immediately | `echo 3 \| sudo tee /proc/sys/vm/drop_caches > /dev/null` |
| Install a package that must survive reboot | `sudo overlayroot-chroot apt-get install -y <pkg>` |
| Write a file only needed until next reboot | Write directly to `/tmp` or `/run` (tmpfs) |
| Stage a file for a deploy helper | Copy to `/tmp` or `/run` as appropriate for the helper |

`tools/deploy-ssh.sh --client` and `deploy.sh` handle all of this automatically.

---

## Persistent Image Uploads

Background images uploaded through the admin Appearance tab are written to
the ext4 lower layer on the server at:

```
/media/root-ro/home/kiosk/building-directory/server/uploads/
```

via `sudo /usr/local/bin/persist-upload.sh copy <src> <filename>`. They
survive reboots. The built-in `18.jpg` is served from the kiosk static
directory and cannot be deleted via the UI.

To delete an uploaded image, use the Delete button in the Appearance tab;
this calls `persist-upload.sh delete <filename>` and resets the active
background to the built-in default if needed.
