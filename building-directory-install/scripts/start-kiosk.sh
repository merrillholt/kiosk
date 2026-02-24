#!/bin/bash
SERVER_URL="http://localhost"

# cage -d hides the cursor; cage manages the process lifecycle.
# --ozone-platform=wayland enables native Wayland rendering in Chromium.
exec cage -d -- chromium \
    --ozone-platform=wayland \
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
