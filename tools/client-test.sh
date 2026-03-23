#!/usr/bin/env bash
set -euo pipefail

HOST="kiosk@192.168.1.82"
COLOR=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --no-color) COLOR=0; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ $COLOR -eq 1 && -t 1 ]]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; DIM='\033[2m'; RESET='\033[0m'
else
    GREEN=''; RED=''; DIM=''; RESET=''
fi

PASS=0
FAIL=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "${GREEN}PASS${RESET} %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RESET} %s ${DIM}(expected %s, got %s)${RESET}\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

remote() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$HOST" "$@"
}

SCRIPT_PATH="/home/kiosk/building-directory/scripts/start-kiosk.sh"
OFFLINE_PATH="/home/kiosk/building-directory/kiosk/unavailable.html"

check "deployed script exists" "yes" "$(remote "test -f '$SCRIPT_PATH' && echo yes || echo no")"
check "offline page exists" "yes" "$(remote "test -f '$OFFLINE_PATH' && echo yes || echo no")"
check "script exposes unavailable page support" "yes" "$(remote "grep -q '^UNAVAILABLE_PAGE=' '$SCRIPT_PATH' && echo yes || echo no")"
check "script exposes recovery interval support" "yes" "$(remote "grep -q '^RECOVERY_CHECK_INTERVAL_SEC=' '$SCRIPT_PATH' && echo yes || echo no")"
check "primary URL patched" 'SERVER_URL="http://192.168.1.80"' "$(remote "grep '^SERVER_URL=' '$SCRIPT_PATH'")"
check "standby URL patched" 'SERVER_URL_STANDBY="http://192.168.1.81"' "$(remote "grep '^SERVER_URL_STANDBY=' '$SCRIPT_PATH'")"
check "overlayroot active" "yes" "$(remote "mount | grep -q '^overlayroot on / type overlay' && echo yes || echo no")"
check "/media/root-ro mounted" "yes" "$(remote "mount | grep -q ' on /media/root-ro ' && echo yes || echo no")"
check "getty@tty1 active" "active" "$(remote "systemctl is-active getty@tty1 2>/dev/null || echo inactive")"
check "kiosk-guard active" "active" "$(remote "systemctl is-active kiosk-guard 2>/dev/null || echo inactive")"
check "cage running" "yes" "$(remote "pgrep -x cage >/dev/null 2>&1 && echo yes || echo no")"
check "chromium command present" "yes" "$(remote "pgrep -af chromium >/dev/null 2>&1 && echo yes || echo no")"
check "startup log records launch decision" "yes" "$(remote "grep -Eq 'Launching kiosk against primary|Launching kiosk against standby|No server available; launching unavailable page' /tmp/kiosk-start.log && echo yes || echo no")"

printf '\n'
if [[ $FAIL -eq 0 ]]; then
    printf "${GREEN}All %s client integration checks passed.${RESET}\n" "$PASS"
else
    printf "${RED}%s client integration check(s) failed${RESET}, %s passed.\n" "$FAIL" "$PASS"
fi

[[ $FAIL -eq 0 ]]
