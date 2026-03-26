#!/bin/bash

kiosk_lib_init() {
    SERVER_URL="${KIOSK_SERVER_URL:-http://192.168.1.80}"
    SERVER_URL_STANDBY="${KIOSK_SERVER_URL_STANDBY:-http://192.168.1.81}"
    UNAVAILABLE_PAGE="${KIOSK_UNAVAILABLE_PAGE:-file:///home/kiosk/building-directory/kiosk/unavailable.html}"
    TOUCH_WAIT_USB_ID="${KIOSK_TOUCH_WAIT_USB_ID:-04e7:0020}"
    TOUCH_DEVICE_NAME="${KIOSK_TOUCH_DEVICE_NAME:-Elo virtual single touch digitizer - uinput v5}"
    TOUCH_READY_TIMEOUT_SEC="${KIOSK_TOUCH_READY_TIMEOUT_SEC:-30}"
    TOUCH_READY_SETTLE_SEC="${KIOSK_TOUCH_READY_SETTLE_SEC:-3}"
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
    KIOSK_ACTION="none"
}

touchscreen_wait_required() {
    command -v lsusb >/dev/null 2>&1 || return 1
    lsusb -d "$TOUCH_WAIT_USB_ID" >/dev/null 2>&1
}

touchscreen_ready() {
    grep -Fq "$TOUCH_DEVICE_NAME" /proc/bus/input/devices 2>/dev/null
}

wait_for_touchscreen_ready() {
    local i

    if ! touchscreen_wait_required; then
        return 0
    fi

    if touchscreen_ready; then
        log_kiosk_start "Touchscreen device already present: ${TOUCH_DEVICE_NAME}"
        if (( TOUCH_READY_SETTLE_SEC > 0 )); then
            sleep "$TOUCH_READY_SETTLE_SEC"
        fi
        return 0
    fi

    log_kiosk_start "Waiting up to ${TOUCH_READY_TIMEOUT_SEC}s for touchscreen device: ${TOUCH_DEVICE_NAME}"
    for ((i = 1; i <= TOUCH_READY_TIMEOUT_SEC; i++)); do
        if touchscreen_ready; then
            log_kiosk_start "Touchscreen device ready after ${i}s: ${TOUCH_DEVICE_NAME}"
            if (( TOUCH_READY_SETTLE_SEC > 0 )); then
                sleep "$TOUCH_READY_SETTLE_SEC"
            fi
            return 0
        fi
        sleep 1
    done

    log_kiosk_start "Touchscreen device not detected after ${TOUCH_READY_TIMEOUT_SEC}s; continuing startup"
    return 0
}

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

primary_startup_attempts() {
    local attempts=$(( PRIMARY_TIMEOUT_SEC / WAIT_INTERVAL_SEC ))
    if (( attempts < 1 )); then
        attempts=1
    fi
    printf '%s\n' "$attempts"
}

select_launch_target() {
    local primary_attempts
    primary_attempts="$(primary_startup_attempts)"

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

apply_recovery_action() {
    local action="$1"
    KIOSK_ACTION="$action"
    case "$action" in
        none)
            return 1
            ;;
        switch_to_standby)
            log_kiosk_start "Primary unhealthy for ${2} probes; restarting kiosk onto standby ${SERVER_URL_STANDBY}"
            ;;
        switch_to_offline)
            log_kiosk_start "Primary unhealthy for ${2} probes and standby unavailable; restarting kiosk onto unavailable page"
            ;;
        promote_to_primary_from_standby)
            log_kiosk_start "Primary healthy for ${2} consecutive probes while on standby; restarting kiosk onto primary"
            ;;
        reselect_from_standby)
            log_kiosk_start "Standby unhealthy for ${2} probes; restarting kiosk to re-evaluate targets"
            ;;
        promote_to_primary_from_offline)
            log_kiosk_start "Primary healthy for ${2} consecutive probes while offline; restarting kiosk onto primary"
            ;;
        switch_to_standby_from_offline)
            log_kiosk_start "Standby reachable while offline; restarting kiosk to use standby"
            ;;
        *)
            echo "Unknown kiosk recovery action: $action" >&2
            return 2
            ;;
    esac
    return 0
}

decide_recovery_action() {
    local current_mode="$1"
    local primary_ok="$2"
    local primary_successes="$3"
    local primary_failures="$4"
    local standby_ok="$5"
    local standby_failures="$6"

    case "$current_mode" in
        primary)
            if (( primary_ok == 0 && primary_failures >= PRIMARY_FAILOVER_FAILURES )); then
                if (( standby_ok == 1 )); then
                    apply_recovery_action "switch_to_standby" "$primary_failures"
                else
                    apply_recovery_action "switch_to_offline" "$primary_failures"
                fi
                return 0
            fi
            ;;
        standby)
            if (( primary_ok == 1 && primary_successes >= PRIMARY_PROMOTE_SUCCESSES )); then
                apply_recovery_action "promote_to_primary_from_standby" "$primary_successes"
                return 0
            fi
            if (( standby_ok == 0 && standby_failures >= STANDBY_FAILOVER_FAILURES )); then
                apply_recovery_action "reselect_from_standby" "$standby_failures"
                return 0
            fi
            ;;
        offline)
            if (( primary_ok == 1 && primary_successes >= PRIMARY_PROMOTE_SUCCESSES )); then
                apply_recovery_action "promote_to_primary_from_offline" "$primary_successes"
                return 0
            fi
            if (( standby_ok == 1 )); then
                apply_recovery_action "switch_to_standby_from_offline"
                return 0
            fi
            ;;
        *)
            echo "Unknown kiosk mode: $current_mode" >&2
            return 2
            ;;
    esac

    KIOSK_ACTION="none"
    return 1
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

            if decide_recovery_action "$ACTIVE_MODE" "$primary_ok" "$primary_successes" "$primary_failures" "$standby_ok" "$standby_failures"; then
                pkill -x cage 2>/dev/null || true
                exit 0
            fi

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
