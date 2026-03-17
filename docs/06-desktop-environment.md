# Desktop Environment

## Production Setup: Cage + Wayland

The kiosk does not use a traditional desktop environment. It runs Chromium
fullscreen under **Cage**, a minimal Wayland compositor designed for single-app
kiosk use. There is no display manager, no X11 session, and no window
decorations.

## Component Overview

| Package | Purpose |
|---------|---------|
| `cage` | Wayland kiosk compositor — runs one app fullscreen |
| `chromium` | Kiosk browser |
| `wlr-randr` | Wayland output inspection and resolution control |
| `xfce4` | Admin desktop (X11) — started only on USB keyboard insertion |
| `xserver-xorg` + `xserver-xorg-input-libinput` | X11 server for XFCE admin sessions |
| `overlayroot` | Read-only root filesystem overlay |

These packages are installed by `building-directory-install/install.sh` (mode 3 — both).

## Kiosk Session Boot Sequence

```
Power on
  └─ systemd boots to multi-user.target (no graphical.target)
       └─ getty@tty1 autologin as kiosk user
            └─ .bash_profile detects tty1
                 └─ loop:
                      ├─ run start-kiosk.sh  (cage + chromium)
                      │    cage exits
                      ├─ if /tmp/kiosk-exit present:
                      │    start XFCE (X11) for admin access
                      │    XFCE exits
                      └─ repeat
```

There is no systemd kiosk service — the loop runs entirely within the kiosk
user's login shell on `tty1`.

## start-kiosk.sh

Located at `~/building-directory/scripts/start-kiosk.sh`. Launched by the
`.bash_profile` loop. Before starting Cage it runs a server health check:

1. Polls `$SERVER_URL/api/data-version` for up to 300 seconds.
2. If the primary is unreachable, switches to `$SERVER_URL_STANDBY`.
3. Launches Cage once a server responds (or after timeout).

`SERVER_URL` and `SERVER_URL_STANDBY` are set at the top of the script and
patched in by `tools/deploy-ssh.sh --full` on each deploy.

The Cage launch uses `-d` to hide the cursor, detects the active display output
with `wlr-randr` and forces 1920×1080, then starts Chromium:

```bash
cage -d -- sh -c '
    OUTPUT=$(wlr-randr 2>/dev/null | sed -n "1s/ .*//p")
    [ -n "$OUTPUT" ] && wlr-randr --output "$OUTPUT" --mode 1920x1080
    exec chromium \
      --ozone-platform=wayland \
      --user-data-dir=/tmp/chromium-profile \
      --password-store=basic \
      --kiosk \
      --noerrdialogs \
      --disable-infobars \
      --disable-notifications \
      --deny-permission-prompts \
      --disable-session-crashed-bubble \
      --disable-pinch \
      --overscroll-history-navigation=0 \
      --disable-features=TranslateUI,NotificationTriggers \
      --check-for-update-interval=31536000 \
      --no-first-run \
      --disable-restore-session-state \
      --disable-sync \
      --disable-translate \
      "$ACTIVE_SERVER_URL"
'
```

Chromium profile and state are written to `/tmp` so nothing persists across
reboots on the read-only root filesystem.

## Admin Breakout (USB Keyboard)

Plugging in a USB keyboard triggers a udev rule (`99-kiosk-keyboard.rules`)
which runs `/usr/local/bin/kiosk-keyboard-added.sh`. That script writes
`/tmp/kiosk-exit` and kills `cage`. The `.bash_profile` loop detects the flag
file and starts XFCE as an X11 session:

```bash
# Started by .bash_profile after cage exits with /tmp/kiosk-exit present
startxfce4 -- -logfile /tmp/Xorg.0.log
```

XFCE runs entirely in `/tmp` (config, cache, auth files) because the root
filesystem is read-only:

```bash
export XAUTHORITY=/tmp/.Xauthority
export XDG_CONFIG_HOME=/tmp/xfce4-config
export XDG_CACHE_HOME=/tmp/xfce4-cache
```

Logging out of XFCE returns to the `.bash_profile` loop which restarts the
kiosk automatically. Unplugging the keyboard is not required.

## kiosk-guard Service

`kiosk-guard.service` runs as a system daemon (`/usr/local/sbin/kiosk-guard`),
enabled at `multi-user.target`. It monitors the kiosk session and restarts
`cage` if Chromium dies unexpectedly, independently of the `.bash_profile` loop.

```bash
systemctl status kiosk-guard
```

The service is set to `OOMScoreAdjust=-500` so the OOM killer targets it last.

> **Note:** The `kiosk-guard` binary is installed directly on production hosts
> and is not currently tracked in this repository. If reinstalling a host,
> confirm the binary is present at `/usr/local/sbin/kiosk-guard` and
> `kiosk-guard.service` is installed in `/etc/systemd/system/`.

## Restarting the Kiosk Session

From the dev machine:

```bash
kiosk-fleet/kioskctl restart-kiosk
# or:
scripts/kioskctl restart-kiosk
```

This kills `cage`; the `.bash_profile` loop restarts it automatically (no
keyboard insertion needed, no reboot needed).

On the host directly:

```bash
sudo pkill -x cage
```

## Why No Display Manager

| Aspect | Display manager (GDM/LightDM) | This setup (getty autologin) |
|--------|------------------------------|------------------------------|
| Boot time | Slower (extra service) | Faster |
| Complexity | Higher | Minimal |
| Failure mode | DM crash = black screen | Loop restarts cage automatically |
| Kiosk escape risk | Possible via DM UI | None |

## Output Resolution

Inspect the active Wayland output from within a running kiosk session:

```bash
# Via kioskctl (from dev machine):
kiosk-fleet/kioskctl cmd 'wlr-randr'
```

Or directly on the host after plugging in a USB keyboard to get XFCE, then
opening a terminal:

```bash
wlr-randr
```

## Checking Kiosk State

From the dev machine:

```bash
kiosk-fleet/kioskctl status
```

Key fields:

| Field | Expected |
|-------|----------|
| `cage` | `running` |
| `chromium` | `running` |
| `getty@tty1` | `active` |
| `overlayroot` | `1` |
| `root_ro_lower` | `ro` |
