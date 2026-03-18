#!/bin/bash
set -euo pipefail

SERVER_URL="http://192.168.1.80"
SERVER_URL_STANDBY="http://192.168.1.81"
PRIMARY_TIMEOUT_SEC="${KIOSK_PRIMARY_TIMEOUT_SEC:-300}"
STANDBY_WAIT_ATTEMPTS="${KIOSK_STANDBY_WAIT_ATTEMPTS:-30}"
WAIT_INTERVAL_SEC="${KIOSK_WAIT_INTERVAL_SEC:-1}"
FAILBACK_INITIAL_DELAY_SEC="${KIOSK_FAILBACK_INITIAL_DELAY_SEC:-7200}"
FAILBACK_CHECK_INTERVAL_SEC="${KIOSK_FAILBACK_CHECK_INTERVAL_SEC:-1800}"
FAILBACK_REQUIRED_SUCCESSES="${KIOSK_FAILBACK_REQUIRED_SUCCESSES:-4}"
ACTIVE_SERVER_URL="$SERVER_URL"
FAILBACK_PID=""

log_kiosk_start() {
    echo "[$(date '+%F %T')] $*" >> /tmp/kiosk-start.log
}

wait_for_server_url() {
    local base_url="$1"
    local attempts="$2"
    local endpoint="${base_url%/}/api/data-version"
    local i
    for ((i = 1; i <= attempts; i++)); do
        if curl -fsS --max-time 2 "$endpoint" >/dev/null 2>&1; then
            log_kiosk_start "Server ready at $endpoint after ${i}s"
            return 0
        fi
        sleep "$WAIT_INTERVAL_SEC"
    done
    return 1
}

primary_server_healthy() {
    local endpoint="${SERVER_URL%/}/api/data-version"
    curl -fsS --max-time 5 "$endpoint" >/dev/null 2>&1
}

select_server_url() {
    local primary_attempts=$(( PRIMARY_TIMEOUT_SEC / WAIT_INTERVAL_SEC ))
    if (( primary_attempts < 1 )); then primary_attempts=1; fi

    if wait_for_server_url "$SERVER_URL" "$primary_attempts"; then
        ACTIVE_SERVER_URL="$SERVER_URL"
        return 0
    fi

    if [[ -n "$SERVER_URL_STANDBY" && "$SERVER_URL_STANDBY" != "$SERVER_URL" ]]; then
        log_kiosk_start "Primary unreachable after ${PRIMARY_TIMEOUT_SEC}s; switching to standby ${SERVER_URL_STANDBY}"
        ACTIVE_SERVER_URL="$SERVER_URL_STANDBY"
        if wait_for_server_url "$ACTIVE_SERVER_URL" "$STANDBY_WAIT_ATTEMPTS"; then
            return 0
        fi
        log_kiosk_start "Standby not confirmed after ${STANDBY_WAIT_ATTEMPTS}s; launching kiosk against standby anyway"
        return 0
    fi

    log_kiosk_start "Primary unreachable after ${PRIMARY_TIMEOUT_SEC}s and no standby configured; launching kiosk anyway"
    ACTIVE_SERVER_URL="$SERVER_URL"
    return 0
}

start_failback_watcher() {
    if [[ "$ACTIVE_SERVER_URL" != "$SERVER_URL_STANDBY" ]]; then
        return 0
    fi

    (
        local successes=0
        log_kiosk_start "Standby failback watcher armed: initial_delay=${FAILBACK_INITIAL_DELAY_SEC}s interval=${FAILBACK_CHECK_INTERVAL_SEC}s successes=${FAILBACK_REQUIRED_SUCCESSES}"
        sleep "$FAILBACK_INITIAL_DELAY_SEC"

        while true; do
            if ! pgrep -x cage >/dev/null 2>&1; then
                log_kiosk_start "Standby failback watcher exiting because cage is no longer running"
                exit 0
            fi

            if primary_server_healthy; then
                successes=$((successes + 1))
                log_kiosk_start "Primary health probe succeeded (${successes}/${FAILBACK_REQUIRED_SUCCESSES}) while running on standby"
                if (( successes >= FAILBACK_REQUIRED_SUCCESSES )); then
                    log_kiosk_start "Primary healthy for ${FAILBACK_REQUIRED_SUCCESSES} consecutive probes; restarting kiosk to fail back"
                    pkill -x cage 2>/dev/null || true
                    exit 0
                fi
            else
                if (( successes > 0 )); then
                    log_kiosk_start "Primary health probe failed; resetting failback success counter"
                fi
                successes=0
            fi

            sleep "$FAILBACK_CHECK_INTERVAL_SEC"
        done
    ) &
    FAILBACK_PID=$!
}

cleanup_failback_watcher() {
    if [[ -n "$FAILBACK_PID" ]]; then
        kill "$FAILBACK_PID" 2>/dev/null || true
        wait "$FAILBACK_PID" 2>/dev/null || true
    fi
}

select_server_url
start_failback_watcher
trap cleanup_failback_watcher EXIT

# ── cage: hides cursor (-d), manages Chromium lifecycle ──────────────────────
# wlr-randr auto-detects the first connected output and forces 1920x1080.
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
