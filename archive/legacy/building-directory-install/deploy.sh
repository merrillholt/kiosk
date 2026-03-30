#!/bin/bash
# Deploy updated server files and kiosk scripts to the kiosk VM.
# Usage: ./deploy.sh [VM_HOST]  (default: merrill@192.168.1.127)

set -e

VM="${1:-merrill@192.168.1.127}"
KIOSK_USER="${KIOSK_USER:-kiosk}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/server"

echo "==> Deploying to $VM"

# Step 1: SCP source files to /tmp on VM (writable tmpfs — safe landing zone)
echo "==> Copying files to VM /tmp/deploy-staging..."
ssh "$VM" "mkdir -p /tmp/deploy-staging"
scp "$SERVER_DIR/server.js"                          "$VM:/tmp/deploy-staging/server.js"
scp "$SERVER_DIR/admin/index.html"                   "$VM:/tmp/deploy-staging/index.html"
scp "$SERVER_DIR/admin/admin.js"                     "$VM:/tmp/deploy-staging/admin.js"
scp "$SERVER_DIR/admin/admin.css"                    "$VM:/tmp/deploy-staging/admin.css"
scp "$SERVER_DIR/persist-upload.sh"                  "$VM:/tmp/deploy-staging/persist-upload.sh"
scp "$SCRIPT_DIR/../tools/deploy-ssh.sh"             "$VM:/tmp/deploy-staging/deploy-ssh.sh"
scp "$SCRIPT_DIR/../tools/compute-revision.sh"       "$VM:/tmp/deploy-staging/compute-revision.sh"
scp "$SCRIPT_DIR/../manifest/deploy-client-files.txt" "$VM:/tmp/deploy-staging/deploy-client-files.txt"
scp "$SCRIPT_DIR/scripts/start-kiosk.sh"             "$VM:/tmp/deploy-staging/start-kiosk.sh"
scp "$SCRIPT_DIR/scripts/kiosk-keyboard-added.sh"    "$VM:/tmp/deploy-staging/kiosk-keyboard-added.sh"
scp "$SCRIPT_DIR/scripts/99-kiosk-keyboard.rules"    "$VM:/tmp/deploy-staging/99-kiosk-keyboard.rules"
scp "$SCRIPT_DIR/scripts/80-kiosk-power-button.conf" "$VM:/tmp/deploy-staging/80-kiosk-power-button.conf"
scp "$SCRIPT_DIR/scripts/bash_profile"               "$VM:/tmp/deploy-staging/bash_profile_template"

# Step 2: Move everything to /run staging area (visible inside overlayroot-chroot)
# then write all files to the ext4 lower layer in one pass.
echo "==> Writing all files to overlayroot lower layer..."
ssh "$VM" bash <<'ENDSSH'
set -e
STAGE="/run/deploy-stage"
sudo mkdir -p "$STAGE"

# Copy from /tmp (overlay tmpfs) into /run (bind-mounted inside chroot)
sudo cp /tmp/deploy-staging/persist-upload.sh        "$STAGE/persist-upload.sh"
sudo cp /tmp/deploy-staging/deploy-ssh.sh            "$STAGE/deploy-ssh.sh"
sudo cp /tmp/deploy-staging/compute-revision.sh      "$STAGE/compute-revision.sh"
sudo cp /tmp/deploy-staging/deploy-client-files.txt  "$STAGE/deploy-client-files.txt"
sudo cp /tmp/deploy-staging/server.js                "$STAGE/server.js"
sudo cp /tmp/deploy-staging/index.html               "$STAGE/index.html"
sudo cp /tmp/deploy-staging/admin.js                 "$STAGE/admin.js"
sudo cp /tmp/deploy-staging/admin.css                "$STAGE/admin.css"
sudo cp /tmp/deploy-staging/start-kiosk.sh           "$STAGE/start-kiosk.sh"
sudo cp /tmp/deploy-staging/kiosk-keyboard-added.sh  "$STAGE/kiosk-keyboard-added.sh"
sudo cp /tmp/deploy-staging/99-kiosk-keyboard.rules  "$STAGE/99-kiosk-keyboard.rules"
sudo cp /tmp/deploy-staging/80-kiosk-power-button.conf "$STAGE/80-kiosk-power-button.conf"
sudo cp /tmp/deploy-staging/bash_profile_template    "$STAGE/bash_profile_template"

# Write sudoers content to staging
echo "${KIOSK_USER} ALL=(root) NOPASSWD: /usr/local/bin/persist-upload.sh" \
    | sudo tee "$STAGE/directory-server-sudoers" > /dev/null

# Write .bash_profile to staging
sudo tee "$STAGE/bash_profile" > /dev/null << 'BPEOF'
# Auto-start kiosk on tty1.
# Use $(tty) rather than XDG_VTNR — agetty --autologin does not
# reliably set XDG_VTNR via PAM.
if [[ "$(tty 2>/dev/null)" == "/dev/tty1" ]]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    mkdir -p "${XDG_RUNTIME_DIR}"
    chmod 700 "${XDG_RUNTIME_DIR}"

    # Loop: restart kiosk automatically after a crash or manual restart.
    # When a USB keyboard is plugged in, udev writes /tmp/kiosk-exit and
    # kills cage. The loop then starts XFCE on the touchscreen for admin
    # access. When the admin logs out of XFCE the kiosk restarts.
    while true; do
        rm -f /tmp/kiosk-exit
        /home/merrill/building-directory/scripts/start-kiosk.sh
        if [[ -f /tmp/kiosk-exit ]]; then
            # Start XFCE as an X11 session (not Wayland) when exiting kiosk.
            unset WAYLAND_DISPLAY
            export XDG_SESSION_TYPE=x11
            export DESKTOP_SESSION=xfce

            # overlayroot mounts / as ro; redirect all XFCE/Xorg state to /tmp.
            export XAUTHORITY=/tmp/.Xauthority
            export ICEAUTHORITY=/tmp/.ICEauthority
            export XDG_CONFIG_HOME=/tmp/xfce4-config
            export XDG_CACHE_HOME=/tmp/xfce4-cache
            export XDG_DATA_HOME=/tmp/xfce4-data
            mkdir -p /tmp/xfce4-config /tmp/xfce4-cache /tmp/xfce4-data
            startxfce4 -- -logfile /tmp/Xorg.0.log >/tmp/xfce4-start.log 2>&1
            echo "startxfce4 exited: $?" >> /tmp/xfce4-start.log
        fi
    done
fi
BPEOF
# Patch kiosk user home in .bash_profile
sudo sed -i "s|/home/merrill|/home/${KIOSK_USER}|g" "$STAGE/bash_profile"

# --- lower layer writes via overlayroot-chroot ---

# Persist script + permissions
sudo overlayroot-chroot cp    "$STAGE/persist-upload.sh" /usr/local/bin/persist-upload.sh
sudo overlayroot-chroot chmod 755                        /usr/local/bin/persist-upload.sh

# Keyboard-added script + permissions
sudo overlayroot-chroot cp    "$STAGE/kiosk-keyboard-added.sh" /usr/local/bin/kiosk-keyboard-added.sh
sudo overlayroot-chroot chmod 755                              /usr/local/bin/kiosk-keyboard-added.sh

# udev rule
sudo overlayroot-chroot cp "$STAGE/99-kiosk-keyboard.rules" \
    /etc/udev/rules.d/99-kiosk-keyboard.rules
sudo overlayroot-chroot mkdir -p /etc/systemd/logind.conf.d
sudo overlayroot-chroot cp "$STAGE/80-kiosk-power-button.conf" \
    /etc/systemd/logind.conf.d/80-kiosk-power-button.conf

# Sudoers drop-in
sudo overlayroot-chroot cp    "$STAGE/directory-server-sudoers" /etc/sudoers.d/directory-server
sudo overlayroot-chroot chmod 440                               /etc/sudoers.d/directory-server

# Uploads directory
sudo overlayroot-chroot mkdir -p /home/${KIOSK_USER}/building-directory/server/uploads

# Server application files
sudo overlayroot-chroot cp "$STAGE/server.js"      /home/${KIOSK_USER}/building-directory/server/server.js
sudo overlayroot-chroot cp "$STAGE/index.html"     /home/${KIOSK_USER}/building-directory/server/admin/index.html
sudo overlayroot-chroot cp "$STAGE/admin.js"       /home/${KIOSK_USER}/building-directory/server/admin/admin.js
sudo overlayroot-chroot cp "$STAGE/admin.css"      /home/${KIOSK_USER}/building-directory/server/admin/admin.css
sudo overlayroot-chroot mkdir -p                    /home/${KIOSK_USER}/building-directory/tools
sudo overlayroot-chroot mkdir -p                    /home/${KIOSK_USER}/building-directory/manifest
sudo overlayroot-chroot cp "$STAGE/deploy-ssh.sh"   /home/${KIOSK_USER}/building-directory/tools/deploy-ssh.sh
sudo overlayroot-chroot chmod 755                   /home/${KIOSK_USER}/building-directory/tools/deploy-ssh.sh
sudo overlayroot-chroot cp "$STAGE/compute-revision.sh" /home/${KIOSK_USER}/building-directory/tools/compute-revision.sh
sudo overlayroot-chroot chmod 755                       /home/${KIOSK_USER}/building-directory/tools/compute-revision.sh
sudo overlayroot-chroot cp "$STAGE/deploy-client-files.txt" /home/${KIOSK_USER}/building-directory/manifest/deploy-client-files.txt

# The admin deploy path uses tools/deploy-ssh.sh --client and still needs the template.
sudo overlayroot-chroot cp "$STAGE/bash_profile_template" /home/${KIOSK_USER}/building-directory/scripts/bash_profile

# Kiosk scripts
sudo overlayroot-chroot cp    "$STAGE/start-kiosk.sh" /home/${KIOSK_USER}/building-directory/scripts/start-kiosk.sh
sudo overlayroot-chroot chmod 755                     /home/${KIOSK_USER}/building-directory/scripts/start-kiosk.sh

# .bash_profile
sudo overlayroot-chroot cp "$STAGE/bash_profile" /home/${KIOSK_USER}/.bash_profile

# Nginx site config
sudo tee "$STAGE/nginx-directory.conf" > /dev/null << 'NGINXEOF'
server {
    listen 80;
    access_log /run/nginx/access.log;
    server_name _;
    client_max_body_size 100m;

    location / {
        root /home/${KIOSK_USER}/building-directory/kiosk;
        index index.html;
        try_files $uri $uri/ =404;
    }

    location /admin {
        alias /home/${KIOSK_USER}/building-directory/server/admin;
        index index.html;
        try_files $uri $uri/ /admin/index.html;
    }

    location /api {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }

    location /uploads {
        proxy_pass http://localhost:3000;
    }
}
NGINXEOF
sudo overlayroot-chroot cp "$STAGE/nginx-directory.conf" /etc/nginx/sites-available/directory

sudo rm -rf "$STAGE"
echo "  all files written to lower layer"

# New lower-layer entries aren't visible to the running overlay until the
# kernel dentry cache is dropped. This makes them appear without a reboot.
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
echo "  kernel dentry cache dropped"
ENDSSH

# Step 3: Reload udev rules (picks up 99-kiosk-keyboard.rules)
echo "==> Reloading udev rules..."
ssh "$VM" "sudo udevadm control --reload-rules"

# Step 4: Reload nginx and restart directory server
echo "==> Reloading nginx..."
ssh "$VM" "sudo nginx -t && sudo systemctl reload nginx"

echo "==> Restarting directory-server..."
ssh "$VM" "sudo systemctl restart directory-server"
sleep 3
ssh "$VM" "sudo systemctl is-active directory-server"

echo ""
echo "==> Deployment complete!"
echo "    Admin: http://192.168.1.127/admin"
echo "    Kiosk: http://192.168.1.127/"
echo ""
echo "    To test keyboard detection: set up USB passthrough for a keyboard"
echo "    in VirtualBox VM settings, then plug/unplug it on the host."
