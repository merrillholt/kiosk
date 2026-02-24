#!/bin/bash
# Deploy updated server files and persist script to the kiosk VM
# Usage: ./deploy.sh [VM_HOST]  (default: merrill@192.168.1.127)

set -e

VM="${1:-merrill@192.168.1.127}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/server"

echo "==> Deploying to $VM"

# Step 1: SCP source files to /tmp on VM (writable tmpfs — safe landing zone)
echo "==> Copying files to VM /tmp/deploy-staging..."
ssh "$VM" "mkdir -p /tmp/deploy-staging"
scp "$SERVER_DIR/server.js"                      "$VM:/tmp/deploy-staging/server.js"
scp "$SERVER_DIR/admin/index.html"               "$VM:/tmp/deploy-staging/index.html"
scp "$SERVER_DIR/admin/admin.js"                 "$VM:/tmp/deploy-staging/admin.js"
scp "$SERVER_DIR/admin/admin.css"                "$VM:/tmp/deploy-staging/admin.css"
scp "$SERVER_DIR/persist-upload.sh"              "$VM:/tmp/deploy-staging/persist-upload.sh"
scp "$SCRIPT_DIR/scripts/start-kiosk.sh"         "$VM:/tmp/deploy-staging/start-kiosk.sh"
scp "$SCRIPT_DIR/scripts/kiosk-breakout.py"      "$VM:/tmp/deploy-staging/kiosk-breakout.py"

# Step 2: Move everything to /run staging area (visible inside overlayroot-chroot)
# then write all files to the ext4 lower layer in one pass.
echo "==> Writing all files to overlayroot lower layer..."
ssh "$VM" bash <<'ENDSSH'
set -e
STAGE="/run/deploy-stage"
sudo mkdir -p "$STAGE"

# Copy from /tmp (overlay tmpfs) into /run (also tmpfs, but bind-mounted in chroot)
sudo cp /tmp/deploy-staging/persist-upload.sh "$STAGE/persist-upload.sh"
sudo cp /tmp/deploy-staging/server.js         "$STAGE/server.js"
sudo cp /tmp/deploy-staging/index.html        "$STAGE/index.html"
sudo cp /tmp/deploy-staging/admin.js          "$STAGE/admin.js"
sudo cp /tmp/deploy-staging/admin.css         "$STAGE/admin.css"
sudo cp /tmp/deploy-staging/start-kiosk.sh    "$STAGE/start-kiosk.sh"
sudo cp /tmp/deploy-staging/kiosk-breakout.py "$STAGE/kiosk-breakout.py"

# Write sudoers content to staging (so we can copy atomically via chroot)
echo 'merrill ALL=(root) NOPASSWD: /usr/local/bin/persist-upload.sh' \
    | sudo tee "$STAGE/directory-server-sudoers" > /dev/null

# --- lower layer writes via overlayroot-chroot ---

# Persist script + permissions
sudo overlayroot-chroot cp    "$STAGE/persist-upload.sh" /usr/local/bin/persist-upload.sh
sudo overlayroot-chroot chmod 755                        /usr/local/bin/persist-upload.sh

# Sudoers drop-in
sudo overlayroot-chroot cp    "$STAGE/directory-server-sudoers" /etc/sudoers.d/directory-server
sudo overlayroot-chroot chmod 440                               /etc/sudoers.d/directory-server

# Uploads directory
sudo overlayroot-chroot mkdir -p /home/merrill/building-directory/server/uploads

# Server application files
sudo overlayroot-chroot cp "$STAGE/server.js"         /home/merrill/building-directory/server/server.js
sudo overlayroot-chroot cp "$STAGE/index.html"        /home/merrill/building-directory/server/admin/index.html
sudo overlayroot-chroot cp "$STAGE/admin.js"          /home/merrill/building-directory/server/admin/admin.js
sudo overlayroot-chroot cp "$STAGE/admin.css"         /home/merrill/building-directory/server/admin/admin.css

# Kiosk scripts
sudo overlayroot-chroot cp    "$STAGE/start-kiosk.sh"    /home/merrill/building-directory/scripts/start-kiosk.sh
sudo overlayroot-chroot cp    "$STAGE/kiosk-breakout.py" /home/merrill/building-directory/scripts/kiosk-breakout.py
sudo overlayroot-chroot chmod 755                        /home/merrill/building-directory/scripts/start-kiosk.sh
sudo overlayroot-chroot chmod 755                        /home/merrill/building-directory/scripts/kiosk-breakout.py

# Nginx site config: client_max_body_size 20m + proxy_request_buffering off
# (/var/lib/nginx/body is read-only on overlay; streaming avoids disk buffering)
sudo tee "$STAGE/nginx-directory.conf" > /dev/null << 'NGINXEOF'
server {
    listen 80;
    access_log /run/nginx/access.log;
    server_name _;
    client_max_body_size 20m;

    location / {
        root /home/merrill/building-directory/kiosk;
        index index.html;
        try_files $uri $uri/ =404;
    }

    location /admin {
        alias /home/merrill/building-directory/server/admin;
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

# New lower-layer entries aren't visible to the running overlay kernel until
# its dentry cache is dropped. This makes them appear immediately without reboot.
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
echo "  kernel dentry cache dropped"
ENDSSH

# Step 3: Install python3-evdev if not present (must go through overlayroot-chroot)
echo "==> Ensuring python3-evdev is installed..."
ssh "$VM" "python3 -c 'import evdev' 2>/dev/null && echo '  already installed' || sudo overlayroot-chroot apt-get install -y python3-evdev"

# Step 4: Reload nginx (picks up updated site config) and restart directory server
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
