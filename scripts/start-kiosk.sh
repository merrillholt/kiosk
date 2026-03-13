#!/bin/bash
set -euo pipefail

SERVER_URL="http://192.168.1.80"
SERVER_URL_STANDBY="http://192.168.1.81"
PRIMARY_TIMEOUT_SEC="${KIOSK_PRIMARY_TIMEOUT_SEC:-300}"
STANDBY_WAIT_ATTEMPTS="${KIOSK_STANDBY_WAIT_ATTEMPTS:-30}"
WAIT_INTERVAL_SEC="${KIOSK_WAIT_INTERVAL_SEC:-1}"
ACTIVE_SERVER_URL="$SERVER_URL"

wait_for_server_url() {
    local base_url="$1"
    local attempts="$2"
    local endpoint="${base_url%/}/api/data-version"
    local i
    for ((i = 1; i <= attempts; i++)); do
        if curl -fsS --max-time 2 "$endpoint" >/dev/null 2>&1; then
            echo "Server ready at $endpoint after ${i}s" >> /tmp/kiosk-start.log
            return 0
        fi
        sleep "$WAIT_INTERVAL_SEC"
    done
    return 1
}

select_server_url() {
    local primary_attempts=$(( PRIMARY_TIMEOUT_SEC / WAIT_INTERVAL_SEC ))
    if (( primary_attempts < 1 )); then primary_attempts=1; fi

    if wait_for_server_url "$SERVER_URL" "$primary_attempts"; then
        ACTIVE_SERVER_URL="$SERVER_URL"
        return 0
    fi

    if [[ -n "$SERVER_URL_STANDBY" && "$SERVER_URL_STANDBY" != "$SERVER_URL" ]]; then
        echo "Primary unreachable after ${PRIMARY_TIMEOUT_SEC}s; switching to standby ${SERVER_URL_STANDBY}" >> /tmp/kiosk-start.log
        ACTIVE_SERVER_URL="$SERVER_URL_STANDBY"
        if wait_for_server_url "$ACTIVE_SERVER_URL" "$STANDBY_WAIT_ATTEMPTS"; then
            return 0
        fi
        echo "Standby not confirmed after ${STANDBY_WAIT_ATTEMPTS}s; launching kiosk against standby anyway" >> /tmp/kiosk-start.log
        return 0
    fi

    echo "Primary unreachable after ${PRIMARY_TIMEOUT_SEC}s and no standby configured; launching kiosk anyway" >> /tmp/kiosk-start.log
    ACTIVE_SERVER_URL="$SERVER_URL"
    return 0
}

select_server_url

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
    '"$ACTIVE_SERVER_URL"'
'
