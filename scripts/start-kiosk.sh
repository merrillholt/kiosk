#!/bin/bash

# Configuration
SERVER_URL="http://localhost"

# Detect the display
if [ -z "$DISPLAY" ]; then
    export DISPLAY=:0
fi

# Set X authority if not set
if [ -z "$XAUTHORITY" ]; then
    export XAUTHORITY=$HOME/.Xauthority
fi

# Check if we can access the display
if ! xset q &>/dev/null; then
    echo "ERROR: Cannot access display $DISPLAY"
    echo "Make sure you're running as the logged-in user or set XAUTHORITY correctly"
    exit 1
fi

# Kill existing Chromium instances
pkill -f chromium
sleep 1

# Hide mouse cursor after 2 seconds of inactivity
unclutter -idle 2 2>/dev/null &

# Disable screen blanking and power management
xset s off 2>/dev/null
xset -dpms 2>/dev/null
xset s noblank 2>/dev/null

# Start Chromium in kiosk mode
# Using snap chromium, add --ozone-platform=x11 to fix Wayland warning
chromium-browser \
    --ozone-platform=x11 \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --disable-pinch \
    --overscroll-history-navigation=0 \
    --disable-features=TranslateUI \
    --check-for-update-interval=31536000 \
    --no-first-run \
    --fast \
    --fast-start \
    --disable-java \
    --disable-restore-session-state \
    --disable-sync \
    --disable-translate \
    --touch-events=enabled \
    "$SERVER_URL" 2>&1 | grep -v "libpxbackend\|libgiolibproxy\|Gtk-WARNING\|PHONE_REGISTRATION_ERROR\|DEPRECATED_ENDPOINT"
