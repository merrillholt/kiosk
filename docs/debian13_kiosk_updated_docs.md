# Debian 13 Hardened Kiosk (Qotom/Ootom Q305P) — Updated Deployment + Client Verification

**Scope:** 24/7 public display kiosk, landscape, single web app in Chromium, business deployment, resilient to power loss (no UPS).  
**Current architecture (updated):** `overlayroot` (read-only root) + **GRUB Maintenance (writable)** entry + **tty1 autologin** + **Wayland cage + Chromium** (no LightDM/X11) + optional XFCE admin fallback when a keyboard is inserted.

---

## 1) High-level architecture

### Normal mode (default boot)
- Root filesystem mounted read-only using `overlayroot="tmpfs"` (RAM upperdir)
- Kiosk runs on **tty1** with autologin user `kiosk`
- `.bash_profile` on tty1 launches the kiosk session:
  - `cage` (Wayland kiosk compositor) launches `chromium --ozone-platform=wayland --kiosk ... URL`
  - Loop restarts kiosk session after crash
  - Optional “keyboard inserted → drop to XFCE” flow (existing mechanism)

### Maintenance mode (GRUB menu)
- Boot with overlay disabled (`overlayroot=disabled`) so root is **writable and persistent**
- Used for:
  - installing packages
  - updating kiosk scripts
  - updating the server on the display node
  - debugging

---

## 2) Verify read-only overlay and maintenance boot

### Verify overlay is active (normal mode)
```bash
mount | grep "^overlayroot on /" || echo "no overlayroot"
```
Expected in normal mode:
- a line like `overlayroot on / type overlay (...)`

### Verify maintenance mode (writable)
Boot GRUB entry: **Debian Kiosk — MAINTENANCE (writable root)**  
Then run:
```bash
mount | grep overlay || echo "no overlay"
```
Expected:
- `no overlay`

---

## 3) GRUB Maintenance entry (writable root)

**Goal:** add a second boot menu entry that disables overlayroot for persistence/debug.

### Where the entry lives
- `/etc/grub.d/40_custom` (edited in writable maintenance mode)
- then run `update-grub`

### Verify entry present
```bash
sudo grep -A3 "MAINTENANCE" /boot/grub/grub.cfg
```
Expected:
- `menuentry "Debian Kiosk — MAINTENANCE (writable root)" {`

---

## 4) Kiosk display stack (tty1 + cage + chromium)

### 4.1 tty1 autologin
Drop-in: `/etc/systemd/system/getty@tty1.service.d/override.conf`
```ini
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
Type=simple
```

Verify:
```bash
systemctl cat getty@tty1.service | sed -n '1,120p'
```

### 4.2 Default boot target
For tty1 kiosk, use:
```bash
systemctl get-default
```
Expected:
- `multi-user.target`

Set in maintenance mode:
```bash
sudo systemctl set-default multi-user.target
```

### 4.3 Disable LightDM (avoid VT/DRM conflicts)
In maintenance mode:
```bash
sudo systemctl disable --now lightdm
systemctl is-enabled lightdm || true
systemctl is-active lightdm || true
```
Expected:
- `disabled`
- `inactive`

### 4.4 Kiosk launch scripts (persistent)
Installed paths (recommended):
- `/usr/local/bin/kiosk-cage-start`
- `/usr/local/bin/kiosk-cage-stop`

Example `kiosk-cage-start` (Wayland cage + chromium):
```bash
#!/bin/bash
set -euo pipefail

SERVER_URL="http://192.168.1.131:3000"   # dev server during testing
PROFILE_DIR="/tmp/chromium-profile"

exec cage -d -- sh -c '
    OUTPUT=$(wlr-randr 2>/dev/null | sed -n "1s/ .*//p")
    [ -n "$OUTPUT" ] && wlr-randr --output "$OUTPUT" --mode 1920x1080 2>/tmp/wlr-randr.log
    rm -rf '"$PROFILE_DIR"' 2>/dev/null || true
    exec chromium       --ozone-platform=wayland       --user-data-dir='"$PROFILE_DIR"'       --password-store=basic       --kiosk       --noerrdialogs       --disable-infobars       --disable-session-crashed-bubble       --overscroll-history-navigation=0       --check-for-update-interval=31536000       --no-first-run       --disable-restore-session-state       --disable-sync       --disable-translate       --disable-features=TranslateUI       '"$SERVER_URL"'
'
```

### 4.5 tty1 autostart via `.bash_profile`
Your existing pattern is correct: only run on tty1, loop restart, XFCE fallback when `/tmp/kiosk-exit` exists.  
**Key requirement:** ensure the launcher path is correct (typo-free), e.g.:
```bash
/usr/local/bin/kiosk-cage-start
```

---

## 5) Client install verification checklist (display node)

Use this checklist after any change.

### 5.1 Network and reachability
On kiosk:
```bash
ip -br addr
ip route
ping -c 3 192.168.1.131
```

### 5.2 Server connectivity (dev server test)
On kiosk:
```bash
curl -m 3 http://192.168.1.131:3000
curl -m 3 http://192.168.1.131:3000/api/data-version
```

If `curl` hangs, test TCP quickly:
```bash
timeout 3 bash -c 'cat < /dev/null > /dev/tcp/192.168.1.131/3000' && echo "tcp3000:open" || echo "tcp3000:blocked"
```

### 5.3 Confirm kiosk processes
On kiosk:
```bash
pgrep -a cage || echo "no cage"
pgrep -a chromium | head -n 5 || echo "no chromium"
```

### 5.4 If display is blank: capture logs
On kiosk:
```bash
journalctl -b --no-pager | grep -Ei 'cage|chromium|wayland|wlroots|libseat' | tail -n 200
```

---

## 6) Dev server firewall (UFW) requirement

Your dev server at `192.168.1.131` had UFW enabled with default deny inbound.  
To allow kiosks to connect to port 3000:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 3000 proto tcp
sudo ufw reload
sudo ufw status | grep 3000
```

---

## 7) Fleet control script (kioskctl) — updated for cage-based kiosks

**Purpose:** central control from an admin workstation for 1→3 kiosks.  
Host list file:
- `building-directory/kiosk-fleet/hosts` (one IP per line)

Updated `kioskctl` (no LightDM/Monit; reports getty@tty1, kiosk-guard, cage, chromium):

```bash
#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${HOSTS_FILE:-$(dirname "$0")/hosts}"
USER_NAME="${USER_NAME:-kiosk}"

usage() {
  cat <<'EOF'
Usage: kioskctl {status|uptime|reboot-normal|reboot-maint|restart-kiosk|cmd <command...>}

Commands:
  status            Show kiosk health: overlayroot, ssh, getty@tty1, kiosk-guard, cage, chromium
  uptime            Show uptime
  reboot-normal     Reboot (boots default GRUB entry)
  reboot-maint      Reboot (then select MAINTENANCE at GRUB)
  restart-kiosk     Kill cage; tty1 login loop should restart kiosk automatically
  cmd <command...>  Run an arbitrary remote command on all hosts

Environment:
  HOSTS_FILE   Path to hosts file (default: ./hosts)
  USER_NAME    SSH username (default: kiosk)
EOF
  exit 2
}

hosts() { grep -vE '^\s*($|#)' "$HOSTS_FILE"; }

run_all() {
  local cmd="$1"
  while read -r h; do
    echo "=== $h ==="
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new       "${USER_NAME}@${h}" "$cmd" || echo "ERROR on $h"
  done < <(hosts)
}

case "${1:-}" in
  status)
    run_all '
hostname;
if mount | grep -q "^overlayroot on / type overlay"; then echo "overlayroot=1"; else echo "overlayroot=0"; fi;

echo -n "ssh="; systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo "unknown";
echo -n "getty@tty1="; systemctl is-active getty@tty1 2>/dev/null || echo "unknown";
echo -n "kiosk-guard="; systemctl is-active kiosk-guard 2>/dev/null || echo "inactive";

if pgrep -x cage >/dev/null 2>&1; then echo "cage=running"; else echo "cage=stopped"; fi;
if pgrep -a chromium >/dev/null 2>&1; then echo "chromium=running"; else echo "chromium=stopped"; fi;
'
    ;;
  uptime)
    run_all 'hostname; uptime'
    ;;
  reboot-normal)
    run_all 'sudo /sbin/reboot'
    ;;
  reboot-maint)
    echo "NOTE: Select GRUB entry: Debian Kiosk — MAINTENANCE (writable root)"
    run_all 'sudo /sbin/reboot'
    ;;
  restart-kiosk)
    run_all 'sudo pkill -x cage || true'
    ;;
  cmd)
    shift
    [ "$#" -ge 1 ] || usage
    run_all "$*"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: $1" >&2
    usage
    ;;
esac
```

---

## 8) Server placement and migration plan (dev → kiosk node)

### Phase 1 (current): server on dev machine
- Server: `192.168.1.131:3000`
- Kiosk URL: `http://192.168.1.131:3000`
- Ensure UFW rule allows port 3000 from kiosks.

### Phase 2 (later): move server to display node `192.168.1.80`
- Production URL is via nginx on port 80:
  - `http://192.168.1.80/`
  - `http://192.168.1.80/admin`
- Keep Node API local-only on the server host:
  - `127.0.0.1:3000` (no LAN exposure)
- Use a systemd service on the server kiosk for auto-restart.
- Put DB + uploads on persistent storage (lower layer) so overlayroot doesn’t erase them.

---

## 9) “Known good” validation sequence (after changes)

1. Boot normal mode
   - `overlayroot=1`  
2. Confirm `getty@tty1` running
3. Confirm `cage` and `chromium` running
4. Confirm `curl http://SERVER/api/data-version` returns quickly
5. Kill cage:
   - `sudo pkill -x cage`
   - verify it restarts automatically (your tty1 loop)

## 10) Startup race protection

`start-kiosk.sh` waits for local API readiness before launching Chromium:
- Checks `http://localhost/api/data-version`
- Defaults: `KIOSK_WAIT_ATTEMPTS=90`, `KIOSK_WAIT_INTERVAL_SEC=1`
- Logs outcome to `/tmp/kiosk-start.log`

This prevents blank/partial UI on boot when the browser starts before backend readiness.

---

## 11) Audio policy for kiosks without sound

If kiosk audio is not used, disable audio daemons persistently to avoid read-only
filesystem crash loops and log noise:

```bash
sudo overlayroot-chroot ln -sfn /dev/null /etc/systemd/user/pulseaudio.service
sudo overlayroot-chroot ln -sfn /dev/null /etc/systemd/user/pulseaudio.socket
sudo overlayroot-chroot ln -sfn /dev/null /etc/systemd/user/pipewire.service
sudo overlayroot-chroot ln -sfn /dev/null /etc/systemd/user/pipewire.socket
sudo overlayroot-chroot ln -sfn /dev/null /etc/systemd/user/pipewire-pulse.service
sudo overlayroot-chroot ln -sfn /dev/null /etc/systemd/user/wireplumber.service
```

---

## 12) Notes on LightDM/Xorg tmpfs mounts (legacy)
Earlier the design used LightDM/Xorg and required tmpfs mounts for `/var/log` and `/var/lib/lightdm`.  
With the updated tty1 + Wayland cage design and LightDM disabled, these are no longer required for kiosk operation.

Keep maintenance mode for:
- package installs
- editing system files
- server deployment to kiosk node

---
