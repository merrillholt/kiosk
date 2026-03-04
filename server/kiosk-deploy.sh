#!/bin/bash
# Deploy kiosk system scripts to an overlayroot kiosk display machine.
# Called by server.js via POST /api/kiosks/:id/deploy.
#
# Usage: kiosk-deploy.sh <kiosk_ip> <kiosk_user> <ssh_key_path> <primary_server_url> [standby_server_url]
#
# The kiosk machine must have the server's SSH public key in
# ~/.ssh/authorized_keys for <kiosk_user>, and that user must have
# passwordless sudo (installed by kiosk install.sh).

set -e

KIOSK_IP="$1"
KIOSK_USER="$2"
SSH_KEY="$3"
SERVER_URL="${4:-http://localhost}"
SERVER_URL_STANDBY="${5:-http://192.168.1.81}"

if [[ -z "$KIOSK_IP" || -z "$KIOSK_USER" || -z "$SSH_KEY" ]]; then
    echo "Usage: kiosk-deploy.sh <ip> <user> <ssh_key> <primary_server_url> [standby_server_url]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_SRC="$(realpath "$SCRIPT_DIR/../scripts")"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

is_local_target() {
    local target="$1"
    [[ "$target" == "127.0.0.1" || "$target" == "localhost" ]] && return 0
    if hostname -I 2>/dev/null | tr ' ' '\n' | grep -Fxq "$target"; then
        return 0
    fi
    return 1
}

write_files_overlay_local() {
    local stage="$1"
    local chroot_stage="/run/deploy-stage"
    sudo mkdir -p "$chroot_stage"
    sudo cp "$stage"/* "$chroot_stage"/

    sudo overlayroot-chroot cp    "$chroot_stage/start-kiosk.sh"             /home/${KIOSK_USER}/building-directory/scripts/start-kiosk.sh
    sudo overlayroot-chroot chmod 755                                         /home/${KIOSK_USER}/building-directory/scripts/start-kiosk.sh
    sudo overlayroot-chroot cp    "$chroot_stage/restart-kiosk.sh"           /home/${KIOSK_USER}/building-directory/scripts/restart-kiosk.sh
    sudo overlayroot-chroot chmod 755                                         /home/${KIOSK_USER}/building-directory/scripts/restart-kiosk.sh
    sudo overlayroot-chroot cp    "$chroot_stage/kiosk-keyboard-added.sh"    /usr/local/bin/kiosk-keyboard-added.sh
    sudo overlayroot-chroot chmod 755                                         /usr/local/bin/kiosk-keyboard-added.sh
    sudo overlayroot-chroot cp    "$chroot_stage/99-kiosk-keyboard.rules"    /etc/udev/rules.d/99-kiosk-keyboard.rules
    sudo overlayroot-chroot mkdir -p                                          /etc/systemd/logind.conf.d
    sudo overlayroot-chroot cp    "$chroot_stage/80-kiosk-power-button.conf" /etc/systemd/logind.conf.d/80-kiosk-power-button.conf
    sudo overlayroot-chroot mkdir -p                                          /etc/systemd/user
    sudo overlayroot-chroot ln -sfn                                           /dev/null /etc/systemd/user/xfce4-notifyd.service
    sudo overlayroot-chroot cp    "$chroot_stage/bash_profile"                /home/${KIOSK_USER}/.bash_profile
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    sudo rm -rf "$chroot_stage"
}

write_files_direct_local() {
    local stage="$1"
    sudo install -D -m 755 "$stage/start-kiosk.sh"             /home/${KIOSK_USER}/building-directory/scripts/start-kiosk.sh
    sudo install -D -m 755 "$stage/restart-kiosk.sh"           /home/${KIOSK_USER}/building-directory/scripts/restart-kiosk.sh
    sudo install -D -m 755 "$stage/kiosk-keyboard-added.sh"    /usr/local/bin/kiosk-keyboard-added.sh
    sudo install -D -m 644 "$stage/99-kiosk-keyboard.rules"    /etc/udev/rules.d/99-kiosk-keyboard.rules
    sudo install -d -m 755                                      /etc/systemd/logind.conf.d
    sudo install -D -m 644 "$stage/80-kiosk-power-button.conf" /etc/systemd/logind.conf.d/80-kiosk-power-button.conf
    sudo install -d -m 755                                      /etc/systemd/user
    sudo ln -sfn                                                /dev/null /etc/systemd/user/xfce4-notifyd.service
    sudo install -D -m 644 "$stage/bash_profile"               /home/${KIOSK_USER}/.bash_profile
}

echo "==> Deploying to ${KIOSK_USER}@${KIOSK_IP} (PRIMARY=${SERVER_URL}, STANDBY=${SERVER_URL_STANDBY})"

if is_local_target "$KIOSK_IP"; then
    echo "==> Local target detected; deploying without SSH."
    STAGE="/tmp/kiosk-deploy-staging"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp "$SCRIPTS_SRC/start-kiosk.sh" "$STAGE/"
    cp "$SCRIPTS_SRC/restart-kiosk.sh" "$STAGE/"
    cp "$SCRIPTS_SRC/kiosk-keyboard-added.sh" "$STAGE/"
    cp "$SCRIPTS_SRC/99-kiosk-keyboard.rules" "$STAGE/"
    cp "$SCRIPTS_SRC/80-kiosk-power-button.conf" "$STAGE/"
    cp "$SCRIPTS_SRC/bash_profile" "$STAGE/"

    sed -i "s|^SERVER_URL=.*|SERVER_URL=\"${SERVER_URL}\"|; s|^SERVER_URL_STANDBY=.*|SERVER_URL_STANDBY=\"${SERVER_URL_STANDBY}\"|" "$STAGE/start-kiosk.sh"

    if mount | grep -q '^overlayroot on / type overlay'; then
        echo "==> Writing to overlayroot lower layer..."
        write_files_overlay_local "$STAGE"
    else
        echo "==> Writing directly (maintenance mode)..."
        write_files_direct_local "$STAGE"
    fi

    sudo udevadm control --reload-rules
    rm -rf "$STAGE"
    echo "==> Deploy to ${KIOSK_IP} complete"
    exit 0
fi

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
    "$SCRIPTS_SRC/80-kiosk-power-button.conf" \
    "$SCRIPTS_SRC/bash_profile" \
    "${KIOSK_USER}@${KIOSK_IP}:/tmp/kiosk-deploy-staging/"

# Patch primary + standby server URLs into start-kiosk.sh before deploying
ssh $SSH_OPTS "${KIOSK_USER}@${KIOSK_IP}" \
    "sed -i 's|^SERVER_URL=.*|SERVER_URL=\"${SERVER_URL}\"|; s|^SERVER_URL_STANDBY=.*|SERVER_URL_STANDBY=\"${SERVER_URL_STANDBY}\"|' /tmp/kiosk-deploy-staging/start-kiosk.sh"

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
sudo overlayroot-chroot mkdir -p                                 /etc/systemd/logind.conf.d
sudo overlayroot-chroot cp    "\$STAGE/80-kiosk-power-button.conf" /etc/systemd/logind.conf.d/80-kiosk-power-button.conf
sudo overlayroot-chroot mkdir -p                                 /etc/systemd/user
sudo overlayroot-chroot ln -sfn                                  /dev/null /etc/systemd/user/xfce4-notifyd.service

sudo overlayroot-chroot cp    "\$STAGE/bash_profile"            /home/${KIOSK_USER}/.bash_profile

# Make new lower-layer entries visible to running overlay without reboot
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null

# Reload udev so the keyboard rule takes effect immediately
sudo udevadm control --reload-rules

sudo rm -rf "\$STAGE"
ENDSSH

echo "==> Deploy to ${KIOSK_IP} complete"
