#!/bin/bash
set -euo pipefail

# Normal case: kill cage, which also kills chromium. The tty1 autologin loop
# restarts the kiosk session automatically.
if pgrep -x cage >/dev/null 2>&1; then
    pkill -x cage
    exit 0
fi

# Recovery case: if the kiosk session is already down, bounce tty1 so the
# autologin shell re-enters .bash_profile and restarts start-kiosk.sh.
sudo systemctl restart getty@tty1
