#!/bin/bash
# Deploy kiosk system scripts to an overlayroot kiosk display machine.
# Called by server.js via POST /api/kiosks/:id/deploy.
#
# Usage: kiosk-deploy.sh <kiosk_ip> <kiosk_user> <ssh_key_path> <server_url>
#
# The kiosk machine must have the server's SSH public key in
# ~/.ssh/authorized_keys for <kiosk_user>, and that user must have
# passwordless sudo (installed by kiosk install.sh).

set -e

KIOSK_IP="$1"
KIOSK_USER="$2"
SSH_KEY="$3"
SERVER_URL="${4:-http://localhost}"

if [[ -z "$KIOSK_IP" || -z "$KIOSK_USER" || -z "$SSH_KEY" ]]; then
    echo "Usage: kiosk-deploy.sh <ip> <user> <ssh_key> [server_url]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_SRC="$(realpath "$SCRIPT_DIR/../scripts")"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

echo "==> Deploying to ${KIOSK_USER}@${KIOSK_IP} (SERVER_URL=${SERVER_URL})"

# Test SSH connectivity
if ! ssh $SSH_OPTS "${KIOSK_USER}@${KIOSK_IP}" true 2>&1; then
    echo "ERROR: Cannot reach ${KIOSK_IP} via SSH" >&2
    exit 1
fi

# Stage files in /tmp on kiosk (user-writable)
echo "==> Staging files..."
ssh $SSH_OPTS "${KIOSK_USER}@${KIOSK_IP}" \
    "rm -rf /tmp/kiosk-deploy-staging && mkdir -p /tmp/kiosk-deploy-staging"

scp $SSH_OPTS \
    "$SCRIPTS_SRC/start-kiosk.sh" \
    "$SCRIPTS_SRC/restart-kiosk.sh" \
    "$SCRIPTS_SRC/kiosk-keyboard-added.sh" \
    "$SCRIPTS_SRC/99-kiosk-keyboard.rules" \
    "$SCRIPTS_SRC/bash_profile" \
    "${KIOSK_USER}@${KIOSK_IP}:/tmp/kiosk-deploy-staging/"

# Patch SERVER_URL into start-kiosk.sh before deploying
ssh $SSH_OPTS "${KIOSK_USER}@${KIOSK_IP}" \
    "sed -i 's|SERVER_URL=.*|SERVER_URL=\"${SERVER_URL}\"|' /tmp/kiosk-deploy-staging/start-kiosk.sh"

# Move to /run (bind-mounted inside overlayroot-chroot), then write lower layer
echo "==> Writing to overlayroot lower layer..."
ssh $SSH_OPTS "${KIOSK_USER}@${KIOSK_IP}" bash <<ENDSSH
set -e
STAGE="/run/deploy-stage"
sudo mkdir -p "\$STAGE"
sudo cp /tmp/kiosk-deploy-staging/* "\$STAGE/"
rm -rf /tmp/kiosk-deploy-staging

sudo overlayroot-chroot cp    "\$STAGE/start-kiosk.sh"          /home/${KIOSK_USER}/building-directory/scripts/start-kiosk.sh
sudo overlayroot-chroot chmod 755                                /home/${KIOSK_USER}/building-directory/scripts/start-kiosk.sh

sudo overlayroot-chroot cp    "\$STAGE/restart-kiosk.sh"        /home/${KIOSK_USER}/building-directory/scripts/restart-kiosk.sh
sudo overlayroot-chroot chmod 755                                /home/${KIOSK_USER}/building-directory/scripts/restart-kiosk.sh

sudo overlayroot-chroot cp    "\$STAGE/kiosk-keyboard-added.sh" /usr/local/bin/kiosk-keyboard-added.sh
sudo overlayroot-chroot chmod 755                                /usr/local/bin/kiosk-keyboard-added.sh

sudo overlayroot-chroot cp    "\$STAGE/99-kiosk-keyboard.rules" /etc/udev/rules.d/99-kiosk-keyboard.rules

sudo overlayroot-chroot cp    "\$STAGE/bash_profile"            /home/${KIOSK_USER}/.bash_profile

# Make new lower-layer entries visible to running overlay without reboot
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

# Reload udev so the keyboard rule takes effect immediately
sudo udevadm control --reload-rules

sudo rm -rf "\$STAGE"
ENDSSH

echo "==> Deploy to ${KIOSK_IP} complete"
