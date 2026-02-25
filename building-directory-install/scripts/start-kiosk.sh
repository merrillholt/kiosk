#!/bin/bash
SERVER_URL="http://localhost"

# ── cage: hides cursor (-d), manages Chromium lifecycle ──────────────────────
# wlr-randr auto-detects the first connected output and sets 1920x1080.
# Works in both the VirtualBox dev VM (Virtual-1) and on physical hardware
# (HDMI-1 or similar) without any configuration change.
# exec replaces sh with chromium so cage sees one long-lived client.
cage -d -- sh -c '
    OUTPUT=$(wlr-randr 2>/dev/null | sed -n "1s/ .*//p")
    [ -n "$OUTPUT" ] && wlr-randr --output "$OUTPUT" --mode 1920x1080 2>/tmp/wlr-randr.log
    exec chromium \
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
    '"$SERVER_URL"'
'
