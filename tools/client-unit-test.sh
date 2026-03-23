#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/start-kiosk-lib.sh"

PASS=0
FAIL=0
LOGS=()

log_kiosk_start() {
    LOGS+=("$*")
}

sleep() { :; }

HEALTHY_URLS=()
WAIT_SUCCESS_URLS=()

wait_for_server_url() {
    local base_url="$1"
    local attempts="$2"
    LAST_WAIT_URL="$base_url"
    LAST_WAIT_ATTEMPTS="$attempts"
    local item
    for item in "${WAIT_SUCCESS_URLS[@]:-}"; do
        if [[ "$item" == "$base_url" ]]; then
            log_kiosk_start "Server ready at $(server_endpoint "$base_url") after 1s"
            return 0
        fi
    done
    return 1
}

server_healthy() {
    local base_url="$1"
    local item
    for item in "${HEALTHY_URLS[@]:-}"; do
        if [[ "$item" == "$base_url" ]]; then
            return 0
        fi
    done
    return 1
}

reset_case() {
    kiosk_lib_init
    LOGS=()
    HEALTHY_URLS=()
    WAIT_SUCCESS_URLS=()
    LAST_WAIT_URL=""
    LAST_WAIT_ATTEMPTS=""
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        printf 'PASS %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
    fi
}

run_case() {
    local name="$1"
    reset_case
    "$name"
}

test_primary_up_launches_primary() {
    WAIT_SUCCESS_URLS=("$SERVER_URL")
    select_launch_target
    assert_eq "$FUNCNAME mode" "primary" "$ACTIVE_MODE"
    assert_eq "$FUNCNAME target" "$SERVER_URL" "$ACTIVE_TARGET"
}

test_primary_down_standby_up_launches_standby() {
    WAIT_SUCCESS_URLS=("$SERVER_URL_STANDBY")
    select_launch_target
    assert_eq "$FUNCNAME mode" "standby" "$ACTIVE_MODE"
    assert_eq "$FUNCNAME target" "$SERVER_URL_STANDBY" "$ACTIVE_TARGET"
}

test_primary_down_standby_down_launches_offline_page() {
    select_launch_target
    assert_eq "$FUNCNAME mode" "offline" "$ACTIVE_MODE"
    assert_eq "$FUNCNAME target" "$UNAVAILABLE_PAGE" "$ACTIVE_TARGET"
}

test_recovery_from_offline_prefers_primary() {
    ACTIVE_MODE="offline"
    decide_recovery_action "offline" 1 2 0 0 1
    assert_eq "$FUNCNAME action" "promote_to_primary_from_offline" "$KIOSK_ACTION"
}

test_recovery_from_offline_uses_standby_if_primary_absent() {
    ACTIVE_MODE="offline"
    decide_recovery_action "offline" 0 0 1 1 0
    assert_eq "$FUNCNAME action" "switch_to_standby_from_offline" "$KIOSK_ACTION"
}

test_standby_promotes_back_to_primary() {
    ACTIVE_MODE="standby"
    decide_recovery_action "standby" 1 2 0 1 0
    assert_eq "$FUNCNAME action" "promote_to_primary_from_standby" "$KIOSK_ACTION"
}

test_primary_fails_over_after_threshold() {
    ACTIVE_MODE="primary"
    decide_recovery_action "primary" 0 0 2 1 0
    assert_eq "$FUNCNAME action" "switch_to_standby" "$KIOSK_ACTION"
}

test_primary_fails_to_offline_when_no_servers() {
    ACTIVE_MODE="primary"
    decide_recovery_action "primary" 0 0 2 0 2
    assert_eq "$FUNCNAME action" "switch_to_offline" "$KIOSK_ACTION"
}

test_standby_re_evaluates_when_standby_fails() {
    ACTIVE_MODE="standby"
    decide_recovery_action "standby" 0 0 1 0 2
    assert_eq "$FUNCNAME action" "reselect_from_standby" "$KIOSK_ACTION"
}

test_startup_timeout_uses_configured_values() {
    KIOSK_PRIMARY_TIMEOUT_SEC=9
    KIOSK_WAIT_INTERVAL_SEC=4
    kiosk_lib_init
    primary_startup_attempts >/dev/null
    assert_eq "$FUNCNAME attempts" "2" "$(primary_startup_attempts)"
}

for case_name in \
    test_primary_up_launches_primary \
    test_primary_down_standby_up_launches_standby \
    test_primary_down_standby_down_launches_offline_page \
    test_recovery_from_offline_prefers_primary \
    test_recovery_from_offline_uses_standby_if_primary_absent \
    test_standby_promotes_back_to_primary \
    test_primary_fails_over_after_threshold \
    test_primary_fails_to_offline_when_no_servers \
    test_standby_re_evaluates_when_standby_fails \
    test_startup_timeout_uses_configured_values
do
    run_case "$case_name"
done

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
    printf 'All %s client unit tests passed.\n' "$PASS"
else
    printf '%s client unit test(s) failed, %s passed.\n' "$FAIL" "$PASS"
fi

[[ "$FAIL" -eq 0 ]]
