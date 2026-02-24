#!/bin/bash
SERVER_URL="http://localhost"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Breakout key watcher ──────────────────────────────────────────────────────
# Runs in background alongside cage. Reads raw /dev/input events — works even
# though cage holds the Wayland session. Kill combo: Right-Shift + Right-Ctrl +
# Backspace (all three held, then Backspace is the trigger).
# To change the combo pass --combo KEY_x,KEY_y,KEY_z (evdev key names).
if command -v python3 &>/dev/null && python3 -c "import evdev" 2>/dev/null; then
    python3 "$SCRIPT_DIR/kiosk-breakout.py" \
        --combo KEY_RIGHTSHIFT,KEY_RIGHTCTRL,KEY_BACKSPACE \
        2>/tmp/kiosk-breakout.log &
    BREAKOUT_PID=$!
else
    echo "kiosk-breakout: python3-evdev not installed, breakout key disabled" \
        >> /tmp/kiosk-breakout.log
    BREAKOUT_PID=""
fi

# ── cage: hides cursor (-d), manages Chromium lifecycle ──────────────────────
cage -d -- chromium \
    --ozone-platform=wayland \
    --user-data-dir=/tmp/chromium-profile \
    --password-store=basic \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --disable-pinch \
    --overscroll-history-navigation=0 \
    --disable-features=TranslateUI \
    --check-for-update-interval=31536000 \
    --no-first-run \
    --disable-restore-session-state \
    --disable-sync \
    --disable-translate \
    --touch-events=enabled \
    "$SERVER_URL"

# cage exited (breakout or crash) — kill the watcher
[ -n "$BREAKOUT_PID" ] && kill "$BREAKOUT_PID" 2>/dev/null
