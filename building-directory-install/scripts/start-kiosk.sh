#!/bin/bash
set -euo pipefail

SERVER_URL="http://localhost"
READY_ENDPOINT="${SERVER_URL%/}/api/data-version"
WAIT_ATTEMPTS="${KIOSK_WAIT_ATTEMPTS:-90}"
WAIT_INTERVAL_SEC="${KIOSK_WAIT_INTERVAL_SEC:-1}"

wait_for_server() {
    local i
    for ((i = 1; i <= WAIT_ATTEMPTS; i++)); do
        if curl -fsS --max-time 2 "$READY_ENDPOINT" >/dev/null 2>&1; then
            echo "Server ready at $READY_ENDPOINT after ${i}s" >> /tmp/kiosk-start.log
            return 0
        fi
        sleep "$WAIT_INTERVAL_SEC"
    done
    echo "Server not ready after ${WAIT_ATTEMPTS}s; launching kiosk anyway" >> /tmp/kiosk-start.log
    return 0
}

wait_for_server

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
    --touch-events=enabled \
    '"$SERVER_URL"'
'
