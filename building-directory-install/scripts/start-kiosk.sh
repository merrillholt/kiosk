#!/bin/bash
set -euo pipefail

SERVER_URL="http://192.168.1.80"
SERVER_URL_STANDBY="http://192.168.1.81"
UNAVAILABLE_PAGE="${KIOSK_UNAVAILABLE_PAGE:-file:///home/kiosk/building-directory/kiosk/unavailable.html}"
PRIMARY_TIMEOUT_SEC="${KIOSK_PRIMARY_TIMEOUT_SEC:-30}"
STANDBY_WAIT_ATTEMPTS="${KIOSK_STANDBY_WAIT_ATTEMPTS:-10}"
WAIT_INTERVAL_SEC="${KIOSK_WAIT_INTERVAL_SEC:-2}"
RECOVERY_INITIAL_DELAY_SEC="${KIOSK_RECOVERY_INITIAL_DELAY_SEC:-15}"
RECOVERY_CHECK_INTERVAL_SEC="${KIOSK_RECOVERY_CHECK_INTERVAL_SEC:-15}"
PRIMARY_PROMOTE_SUCCESSES="${KIOSK_PRIMARY_PROMOTE_SUCCESSES:-2}"
PRIMARY_FAILOVER_FAILURES="${KIOSK_PRIMARY_FAILOVER_FAILURES:-2}"
STANDBY_FAILOVER_FAILURES="${KIOSK_STANDBY_FAILOVER_FAILURES:-2}"
ACTIVE_TARGET="$SERVER_URL"
ACTIVE_MODE="primary"
RECOVERY_PID=""

log_kiosk_start() {
    echo "[$(date '+%F %T')] $*" >> /tmp/kiosk-start.log
}

server_endpoint() {
    local base_url="$1"
    printf '%s/api/data-version\n' "${base_url%/}"
}

wait_for_server_url() {
    local base_url="$1"
    local attempts="$2"
    local endpoint
    endpoint="$(server_endpoint "$base_url")"
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

server_healthy() {
    local endpoint
    endpoint="$(server_endpoint "$1")"
    curl -fsS --max-time 5 "$endpoint" >/dev/null 2>&1
}

select_launch_target() {
    local primary_attempts=$(( PRIMARY_TIMEOUT_SEC / WAIT_INTERVAL_SEC ))
    if (( primary_attempts < 1 )); then primary_attempts=1; fi

    if wait_for_server_url "$SERVER_URL" "$primary_attempts"; then
        ACTIVE_MODE="primary"
        ACTIVE_TARGET="$SERVER_URL"
        log_kiosk_start "Launching kiosk against primary ${ACTIVE_TARGET}"
        return 0
    fi

    if [[ -n "$SERVER_URL_STANDBY" && "$SERVER_URL_STANDBY" != "$SERVER_URL" ]]; then
        log_kiosk_start "Primary unreachable after ${PRIMARY_TIMEOUT_SEC}s; switching to standby ${SERVER_URL_STANDBY}"
        if wait_for_server_url "$SERVER_URL_STANDBY" "$STANDBY_WAIT_ATTEMPTS"; then
            ACTIVE_MODE="standby"
            ACTIVE_TARGET="$SERVER_URL_STANDBY"
            log_kiosk_start "Launching kiosk against standby ${ACTIVE_TARGET}"
            return 0
        fi
        log_kiosk_start "Standby not confirmed after ${STANDBY_WAIT_ATTEMPTS} attempts; launching unavailable page"
    fi

    ACTIVE_MODE="offline"
    ACTIVE_TARGET="$UNAVAILABLE_PAGE"
    log_kiosk_start "No server available; launching unavailable page ${ACTIVE_TARGET}"
    return 0
}

start_recovery_watcher() {
    (
        local primary_successes=0
        local primary_failures=0
        local standby_failures=0
        local primary_ok=0
        local standby_ok=0
        log_kiosk_start "Recovery watcher armed: initial_delay=${RECOVERY_INITIAL_DELAY_SEC}s interval=${RECOVERY_CHECK_INTERVAL_SEC}s"
        sleep "$RECOVERY_INITIAL_DELAY_SEC"

        while true; do
            if ! pgrep -x cage >/dev/null 2>&1; then
                log_kiosk_start "Recovery watcher exiting because cage is no longer running"
                exit 0
            fi

            if server_healthy "$SERVER_URL"; then
                primary_ok=1
                primary_successes=$((primary_successes + 1))
                primary_failures=0
            else
                primary_ok=0
                primary_successes=0
                primary_failures=$((primary_failures + 1))
            fi

            if [[ -n "$SERVER_URL_STANDBY" && "$SERVER_URL_STANDBY" != "$SERVER_URL" ]] && server_healthy "$SERVER_URL_STANDBY"; then
                standby_ok=1
                standby_failures=0
            else
                standby_ok=0
                standby_failures=$((standby_failures + 1))
            fi

            case "$ACTIVE_MODE" in
                primary)
                    if (( primary_ok == 0 && primary_failures >= PRIMARY_FAILOVER_FAILURES )); then
                        if (( standby_ok == 1 )); then
                            log_kiosk_start "Primary unhealthy for ${primary_failures} probes; restarting kiosk onto standby ${SERVER_URL_STANDBY}"
                        else
                            log_kiosk_start "Primary unhealthy for ${primary_failures} probes and standby unavailable; restarting kiosk onto unavailable page"
                        fi
                        pkill -x cage 2>/dev/null || true
                        exit 0
                    fi
                    ;;
                standby)
                    if (( primary_ok == 1 && primary_successes >= PRIMARY_PROMOTE_SUCCESSES )); then
                        log_kiosk_start "Primary healthy for ${primary_successes} consecutive probes while on standby; restarting kiosk onto primary"
                        pkill -x cage 2>/dev/null || true
                        exit 0
                    fi
                    if (( standby_ok == 0 && standby_failures >= STANDBY_FAILOVER_FAILURES )); then
                        log_kiosk_start "Standby unhealthy for ${standby_failures} probes; restarting kiosk to re-evaluate targets"
                        pkill -x cage 2>/dev/null || true
                        exit 0
                    fi
                    ;;
                offline)
                    if (( primary_ok == 1 && primary_successes >= PRIMARY_PROMOTE_SUCCESSES )); then
                        log_kiosk_start "Primary healthy for ${primary_successes} consecutive probes while offline; restarting kiosk onto primary"
                        pkill -x cage 2>/dev/null || true
                        exit 0
                    fi
                    if (( standby_ok == 1 )); then
                        log_kiosk_start "Standby reachable while offline; restarting kiosk to use standby"
                        pkill -x cage 2>/dev/null || true
                        exit 0
                    fi
                    ;;
            esac

            sleep "$RECOVERY_CHECK_INTERVAL_SEC"
        done
    ) &
    RECOVERY_PID=$!
}

cleanup_recovery_watcher() {
    if [[ -n "$RECOVERY_PID" ]]; then
        kill "$RECOVERY_PID" 2>/dev/null || true
        wait "$RECOVERY_PID" 2>/dev/null || true
    fi
}

select_launch_target
start_recovery_watcher
trap cleanup_recovery_watcher EXIT

# ── cage: hides cursor (-d), manages Chromium lifecycle ──────────────────────
# exec replaces sh with chromium so cage sees one long-lived client.
cage -d -- sh -c '
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
    '"$ACTIVE_TARGET"'
'
