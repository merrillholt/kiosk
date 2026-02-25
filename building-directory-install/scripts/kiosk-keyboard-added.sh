#!/bin/bash
# Invoked by udev when a USB keyboard is added (ACTION=add, ID_INPUT_KEYBOARD=1).
# Stops the kiosk so the admin can use the keyboard + touchscreen.
# The .bash_profile loop detects /tmp/kiosk-exit and starts XFCE.
#
# Touchscreens (ID_INPUT_TOUCHSCREEN=1) do not match this rule, so plugging
# the display's USB touch cable in at boot will not trigger this script.

# Do nothing if the kiosk is not running
pgrep -x cage > /dev/null || exit 0

# Determine the autologin user so the sentinel can be chowned to them.
# /tmp uses the sticky bit: only the file owner can delete their files.
# This script runs as root; without chown the kiosk user's rm -f silently fails.
KIOSK_USER=$(awk '/--autologin/{for(i=1;i<=NF;i++) if($i=="--autologin") print $(i+1)}' \
    /etc/systemd/system/getty@tty1.service.d/autologin.conf 2>/dev/null | head -1)
KIOSK_USER=${KIOSK_USER:-merrill}

# Signal the .bash_profile loop to launch XFCE after cage exits.
touch /tmp/kiosk-exit
chown "$KIOSK_USER" /tmp/kiosk-exit

# Stop cage — start-kiosk.sh will return and the loop will start XFCE
pkill -x cage
