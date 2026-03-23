#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/start-kiosk-lib.sh"

kiosk_lib_init

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
