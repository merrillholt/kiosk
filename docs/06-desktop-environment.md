# Desktop Environment Selection

## Recommendation: No Desktop Environment

For a kiosk deployment, **no desktop environment** is the best choice. You only need enough to run Chromium fullscreen.

## Debian Install Selection

During Debian install, **uncheck all desktop options**:

```
[ ] Debian desktop environment
[ ] ... GNOME
[ ] ... Xfce
[ ] ... KDE Plasma
[ ] ... Cinnamon
[ ] ... MATE
[ ] ... LXDE
[ ] ... LXQt
[x] SSH server
[x] standard system utilities
```

Then install only what's needed after first boot:

```bash
sudo apt install --no-install-recommends \
  xorg \
  chromium \
  openbox \
  unclutter
```

**Total additional install: ~300-400 MB** (vs 2-4 GB for a full DE)

## Why No Desktop Environment

| Aspect | Full DE (GNOME/KDE) | Minimal X11 |
|--------|---------------------|-------------|
| RAM usage | 800 MB - 1.5 GB | ~150 MB |
| Disk space | 2-4 GB | ~400 MB |
| Boot time | 30-60 sec | 10-15 sec |
| Attack surface | Large | Minimal |
| Things to break | Many | Few |
| User can exit kiosk | Possibly | No |

## Component Overview

| Package | Purpose |
|---------|---------|
| `xorg` | X11 display server (required for GUI) |
| `chromium` | The kiosk browser |
| `openbox` | Minimal window manager (optional but helps) |
| `unclutter` | Hides mouse cursor after idle |

## Auto-Start Configuration

### Step 1: Create X11 startup script

Create `/home/kiosk/.xinitrc`:

```bash
#!/bin/bash

# Hide cursor after 2 seconds
unclutter -idle 2 &

# Disable screen blanking
xset s off
xset -dpms
xset s noblank

# Start Chromium in kiosk mode
chromium --kiosk --noerrdialogs --disable-infobars http://localhost
```

Make it executable:

```bash
chmod +x /home/kiosk/.xinitrc
```

### Step 2: Create systemd service

Create `/etc/systemd/system/kiosk.service`:

```ini
[Unit]
Description=Kiosk Display
After=network.target

[Service]
User=kiosk
Environment=DISPLAY=:0
ExecStart=/usr/bin/startx
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
```

### Step 3: Enable the service

```bash
sudo systemctl enable kiosk
```

The kiosk will now start automatically on boot, launching directly into Chromium fullscreen with no desktop environment visible.

## Optional: Debug Desktop

If you want the ability to occasionally use a desktop for debugging, install Xfce but don't auto-start it:

```bash
sudo apt install --no-install-recommends xfce4
```

Usage:
- Normal boot: Goes directly to Chromium kiosk
- Debug mode: SSH in, stop kiosk service, run `startxfce4`

## Admin Breakout (USB Keyboard)

When a USB keyboard is plugged in, the kiosk session exits and XFCE starts for admin access. Logging out of XFCE restarts the kiosk automatically. This is handled by a udev rule and the `.bash_profile` autostart loop installed by `install.sh`.

```bash
# To temporarily use Xfce for debugging:
sudo systemctl stop kiosk
export DISPLAY=:0
startxfce4
```

## Desktop Environment Comparison

If for some reason you need a full DE, here's a comparison:

| DE | RAM Usage | Disk Space | Best For |
|----|-----------|------------|----------|
| **None (X11 only)** | ~150 MB | ~400 MB | Production kiosk |
| LXDE | ~300 MB | ~800 MB | Extremely limited hardware |
| LXQt | ~350 MB | ~900 MB | Qt-based lightweight option |
| Xfce | ~400 MB | ~1 GB | Debug/development flexibility |
| MATE | ~500 MB | ~1.5 GB | Traditional desktop feel |
| Cinnamon | ~700 MB | ~2 GB | Modern but heavier |
| GNOME | ~1 GB+ | ~3 GB | Not recommended for kiosk |
| KDE Plasma | ~800 MB+ | ~3 GB | Not recommended for kiosk |

## Security Considerations

A minimal X11 setup is more secure for a public kiosk:

- **No file manager**: Users can't browse filesystem
- **No terminal**: No command-line access
- **No application menu**: Can't launch other programs
- **No window decorations**: Can't minimize/close/move browser
- **Kiosk mode**: Chromium runs fullscreen with no UI chrome

## Chromium Kiosk Flags

Key flags for kiosk mode:

```bash
chromium \
  --kiosk \                          # Fullscreen, no UI
  --noerrdialogs \                   # Suppress error dialogs
  --disable-infobars \               # No "Chrome is being controlled" bar
  --disable-session-crashed-bubble \ # No "restore session" prompt
  --disable-pinch \                  # Disable pinch-to-zoom
  --overscroll-history-navigation=0 \ # Disable swipe navigation
  --disable-translate \              # No translation prompts
  --no-first-run \                   # Skip first-run wizard
  --disable-sync \                   # No Google sync prompts
  --touch-events=enabled \           # Enable touch support
  "http://localhost"
```

## Summary

| Scenario | What to Install |
|----------|-----------------|
| **Production kiosk** | `xorg chromium openbox unclutter` |
| **Dev/debug flexibility** | Add `xfce4` (but don't autostart) |
| **Never for kiosk** | GNOME, KDE, full desktop environments |
