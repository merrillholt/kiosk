#!/bin/bash

###############################################################################
# Building Directory Kiosk - Installation Script
# For Debian 13 (Trixie)
###############################################################################

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CANONICAL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -d "$CANONICAL_ROOT/scripts" ]; then
    RUNTIME_SCRIPTS_SRC="$CANONICAL_ROOT/scripts"
else
    RUNTIME_SCRIPTS_SRC="$SCRIPT_DIR/scripts"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Print functions
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo "============================================="
    echo "$1"
    echo "============================================="
    echo ""
}

wait_for_http_ok() {
    local url="$1"
    local label="$2"
    local attempts="${3:-15}"
    local delay="${4:-1}"
    local i

    for ((i = 1; i <= attempts; i++)); do
        if curl -fsS "$url" > /dev/null 2>&1; then
            print_info "$label passed"
            return 0
        fi
        sleep "$delay"
    done

    print_warn "$label failed"
    return 1
}

disable_print_stack() {
    local units=(
        cups.service
        cups.socket
        cups.path
        cups-browsed.service
    )
    local present=()
    local unit

    for unit in "${units[@]}"; do
        if systemctl list-unit-files --full --no-legend "$unit" 2>/dev/null | grep -q "^$unit"; then
            present+=("$unit")
        fi
    done

    if [ "${#present[@]}" -eq 0 ]; then
        print_info "No CUPS services installed; skipping print stack disable."
        return 0
    fi

    print_info "Disabling CUPS services to avoid read-only filesystem log spam..."
    sudo systemctl disable --now "${present[@]}" >/dev/null 2>&1 || true
}

disable_overlayroot_noise_services() {
    local units=(
        apt-daily.timer
        apt-daily-upgrade.timer
        logrotate.timer
        man-db.timer
        dpkg-db-backup.timer
        wtmpdb-update-boot.service
    )
    local present=()
    local unit

    for unit in "${units[@]}"; do
        if systemctl list-unit-files --full --no-legend "$unit" 2>/dev/null | grep -q "^$unit"; then
            present+=("$unit")
        fi
    done

    if [ "${#present[@]}" -eq 0 ]; then
        print_info "No overlayroot-noise services found; skipping disable."
        return 0
    fi

    print_info "Disabling timers/services that write to the read-only root on kiosk hosts..."
    sudo systemctl disable --now "${present[@]}" >/dev/null 2>&1 || true
}

disable_pam_wtmpdb() {
    if [ ! -f /etc/pam.d/common-session ]; then
        print_info "common-session not present; skipping pam_wtmpdb disable."
        return 0
    fi

    if ! grep -q 'pam_wtmpdb\.so' /etc/pam.d/common-session 2>/dev/null; then
        print_info "pam_wtmpdb already absent from common-session."
        return 0
    fi

    print_info "Removing pam_wtmpdb from common-session on kiosk hosts..."
    sudo sed -i '/pam_wtmpdb\.so/d' /etc/pam.d/common-session
}

disable_pulseaudio_user_units() {
    print_info "Masking PulseAudio user units on kiosk hosts..."
    sudo mkdir -p /etc/systemd/user
    sudo ln -sfn /dev/null /etc/systemd/user/pulseaudio.service
    sudo ln -sfn /dev/null /etc/systemd/user/pulseaudio.socket
}

ensure_var_log_tmpfs() {
    local fstab_path="/etc/fstab"
    local fstab_line='tmpfs /var/log tmpfs defaults,noatime,mode=0755,size=100m 0 0'

    print_info "Ensuring /var/log is mounted as tmpfs on kiosk hosts..."
    if grep -Eq '^[^#[:space:]]+[[:space:]]+/var/log[[:space:]]+tmpfs[[:space:]]' "$fstab_path" 2>/dev/null; then
        sudo sed -i "s|^[^#[:space:]]\\+[[:space:]]\\+/var/log[[:space:]]\\+tmpfs[[:space:]].*|$fstab_line|" "$fstab_path"
    else
        printf '%s\n' "$fstab_line # overlayroot:fs-virtual" | sudo tee -a "$fstab_path" >/dev/null
    fi
}

ensure_persistent_journal() {
    local fstab_path="/etc/fstab"
    local journal_line='/data/journal /var/log/journal none bind,x-systemd.requires=data.mount,x-systemd.after=data.mount,x-mount.mkdir 0 0'
    local journal_group="root"

    if getent group systemd-journal >/dev/null 2>&1; then
        journal_group="systemd-journal"
    fi

    print_info "Ensuring persistent journald storage on /data/journal..."
    sudo install -d -m 2755 -o root -g "$journal_group" /data/journal
    sudo install -d -m 2755 -o root -g "$journal_group" /var/log/journal
    sudo install -D -m 644 "$RUNTIME_SCRIPTS_SRC/journald-persistent.conf" /etc/systemd/journald.conf.d/persistent.conf

    if grep -Eq '^[^#[:space:]]+[[:space:]]+/var/log/journal[[:space:]]+none[[:space:]]+bind' "$fstab_path" 2>/dev/null; then
        sudo sed -i "s|^[^#[:space:]]\\+[[:space:]]\\+/var/log/journal[[:space:]]\\+none[[:space:]]\\+bind.*|$journal_line|" "$fstab_path"
    else
        printf '%s\n' "$journal_line # persistent-journal" | sudo tee -a "$fstab_path" >/dev/null
    fi

    sudo mountpoint -q /var/log/journal || sudo mount /var/log/journal || true
    sudo systemctl restart systemd-journald || true
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Please do not run this script as root or with sudo"
    exit 1
fi

# Resolve target home directory from the install user account instead of $HOME.
# This avoids path mistakes when users copy/paste root shell commands later.
INSTALL_USER="$USER"
INSTALL_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
if [ -z "$INSTALL_HOME" ]; then
    INSTALL_HOME="$HOME"
fi
INSTALL_DIR="$INSTALL_HOME/building-directory"

# Get installation type
print_header "Building Directory Kiosk Installation"
echo "Select installation type:"
echo "1) Server (manages data and serves kiosk interface)"
echo "2) Kiosk Client (displays directory)"
echo "3) Both Server and Client (standard single-machine deployment)"
echo ""
read -p "Enter your choice (1-3): " INSTALL_TYPE

case $INSTALL_TYPE in
    1)
        INSTALL_MODE="server"
        ;;
    2)
        INSTALL_MODE="client"
        ;;
    3)
        INSTALL_MODE="both"
        ;;
    *)
        print_error "Invalid choice"
        exit 1
        ;;
esac

print_info "Installation mode: $INSTALL_MODE"

# Get server IP for client installations
if [ "$INSTALL_MODE" = "client" ] || [ "$INSTALL_MODE" = "both" ]; then
    if [ "$INSTALL_MODE" = "both" ]; then
        SERVER_IP="localhost"
        print_info "Using localhost as server IP (both mode)"
    else
        read -p "Enter server IP address: " SERVER_IP
        if [ -z "$SERVER_IP" ]; then
            print_error "Server IP cannot be empty"
            exit 1
        fi
    fi
fi

# Update system
print_header "Updating System Packages"
sudo apt update
sudo apt upgrade -y

# Install common dependencies
print_header "Installing Common Dependencies"
sudo apt install -y git curl wget unzip sqlite3 openssl rsync

print_header "Configuring Persistent Boot Logs"
ensure_persistent_journal

# ── Server components ─────────────────────────────────────────────────────────
if [ "$INSTALL_MODE" = "server" ] || [ "$INSTALL_MODE" = "both" ]; then
    print_header "Installing Server Components"

    # Install Node.js (LTS via NodeSource)
    print_info "Installing Node.js..."
    if ! command -v node &> /dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt install -y nodejs
    else
        print_info "Node.js already installed: $(node --version)"
    fi

    # Install Nginx
    print_info "Installing Nginx..."
    sudo apt install -y nginx
    sudo install -D -m 644 "$RUNTIME_SCRIPTS_SRC/nginx-log-tmpfiles.conf" /etc/tmpfiles.d/nginx-log-tmpfiles.conf
    sudo systemd-tmpfiles --create /etc/tmpfiles.d/nginx-log-tmpfiles.conf

    # Create installation directory
    print_info "Creating installation directory: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    # nginx serves files from /home/kiosk/building-directory, so it must be able
    # to traverse /home/kiosk without exposing directory contents.
    sudo chmod 711 "$INSTALL_HOME"

    # Copy server files
    print_info "Copying server files..."
    cp -r server "$INSTALL_DIR/"
    cp -r scripts "$INSTALL_DIR/"
    cp -r kiosk "$INSTALL_DIR/"
    if [ -d kiosk-fleet ]; then
        cp -r kiosk-fleet "$INSTALL_DIR/"
    fi

    # Install Node.js dependencies
    print_info "Installing Node.js dependencies..."
    cd "$INSTALL_DIR/server"
    npm install
    cd - > /dev/null

    # Keep the SQLite database on /data so server writes survive overlayroot.
    print_info "Configuring database storage on /data..."
    sudo install -d -m 775 -o "$INSTALL_USER" -g "$INSTALL_USER" /data/directory
    sudo install -d -m 775 -o "$INSTALL_USER" -g "$INSTALL_USER" /data/backups/building-directory
    if [ -L "$INSTALL_DIR/server/directory.db" ]; then
        print_info "Server database symlink already present."
    else
        if [ -f "$INSTALL_DIR/server/directory.db" ]; then
            if [ ! -f /data/directory/directory.db ]; then
                mv "$INSTALL_DIR/server/directory.db" /data/directory/directory.db
            else
                rm -f "$INSTALL_DIR/server/directory.db"
            fi
        fi
        if [ ! -f /data/directory/directory.db ]; then
            sqlite3 /data/directory/directory.db 'PRAGMA journal_mode=delete;' >/dev/null
        fi
        chown "$INSTALL_USER:$INSTALL_USER" /data/directory/directory.db
        ln -sfn /data/directory/directory.db "$INSTALL_DIR/server/directory.db"
    fi

    # Create database
    print_info "Initializing database..."
    if [ -f "$INSTALL_DIR/scripts/sample-data.sql" ]; then
        read -p "Load sample data? (y/n): " LOAD_SAMPLE
        if [ "$LOAD_SAMPLE" = "y" ]; then
            touch "$INSTALL_DIR/server/.load-sample-data"
        fi
    fi

    # Install privileged persist helper (writes uploads to overlayroot lower layer)
    # Patch the username placeholder before installing so the path is correct
    # regardless of which user ran this script.
    print_info "Installing persist-upload helper..."
    sed "s|/home/merrill/|/home/$USER/|g" server/persist-upload.sh \
        | sudo tee /usr/local/bin/persist-upload.sh > /dev/null
    sudo chmod 755 /usr/local/bin/persist-upload.sh

    # Install deploy helper and client manifest used by the admin Deploy tab.
    print_info "Installing deploy helper..."
    mkdir -p "$INSTALL_DIR/tools" "$INSTALL_DIR/manifest"
    cp tools/deploy-ssh.sh "$INSTALL_DIR/tools/deploy-ssh.sh"
    cp tools/compute-revision.sh "$INSTALL_DIR/tools/compute-revision.sh"
    cp manifest/deploy-client-files.txt "$INSTALL_DIR/manifest/deploy-client-files.txt"
    chmod 755 "$INSTALL_DIR/tools/deploy-ssh.sh" "$INSTALL_DIR/tools/compute-revision.sh"
    echo "$USER ALL=(root) NOPASSWD: /usr/local/bin/persist-upload.sh" \
        | sudo tee /etc/sudoers.d/directory-server > /dev/null
    sudo chmod 440 /etc/sudoers.d/directory-server
    sudo mkdir -p "$INSTALL_DIR/server/uploads"

    # Create systemd service
    print_info "Creating systemd service..."
    sudo bash -c "cat > /etc/systemd/system/directory-server.service" <<EOF
[Unit]
Description=Building Directory Server
After=network.target

[Service]
Type=simple
User=$INSTALL_USER
WorkingDirectory=$INSTALL_DIR/server
ExecStart=/usr/bin/node $INSTALL_DIR/server/server.js
Restart=on-failure
RestartSec=10
SyslogIdentifier=directory-server
Environment=NODE_ENV=production
Environment=KIOSK_ALLOW_DEFAULT_PASSWORD=true
Environment=KIOSK_ADMIN_PASSWORD=kiosk
Environment=KIOSK_SSH_KEY=/data/directory/kiosk_deploy_key

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable directory-server

    print_info "Installing daily backup timer..."
    sed \
        -e "s|@INSTALL_USER@|$INSTALL_USER|g" \
        -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" \
        "$INSTALL_DIR/scripts/directory-backup.service" \
        | sudo tee /etc/systemd/system/directory-backup.service > /dev/null
    sudo chmod 644 /etc/systemd/system/directory-backup.service
    sudo install -D -m 644 "$INSTALL_DIR/scripts/directory-backup.timer" /etc/systemd/system/directory-backup.timer
    sudo systemctl daemon-reload
    sudo systemctl enable directory-backup.timer
    sudo systemctl start directory-backup.timer

    # Optional admin hardening
    ADMIN_AUTH_ENABLED="n"
    ADMIN_AUTH_USER="admin"
    ADMIN_AUTH_FILE="/etc/nginx/.directory-admin.htpasswd"
    ADMIN_ALLOWLIST_ENABLED="n"
    ADMIN_ALLOWLISTS=""
    ADMIN_ALLOWLIST_DIRECTIVES=""

    print_header "Admin Access Hardening (Optional)"
    read -p "Enable HTTP Basic Auth for /admin and write/sensitive /api endpoints? (y/n): " ADMIN_AUTH_ENABLED
    if [ "$ADMIN_AUTH_ENABLED" = "y" ]; then
        read -p "Admin username [admin]: " INPUT_ADMIN_USER
        ADMIN_AUTH_USER="${INPUT_ADMIN_USER:-admin}"
        while true; do
            read -s -p "Admin password: " ADMIN_PASS_1
            echo ""
            read -s -p "Confirm password: " ADMIN_PASS_2
            echo ""
            if [ -z "$ADMIN_PASS_1" ]; then
                print_warn "Password cannot be empty."
            elif [ "$ADMIN_PASS_1" != "$ADMIN_PASS_2" ]; then
                print_warn "Passwords do not match."
            else
                break
            fi
        done
        ADMIN_PASS_HASH="$(openssl passwd -6 "$ADMIN_PASS_1")"
        unset ADMIN_PASS_1 ADMIN_PASS_2
        echo "$ADMIN_AUTH_USER:$ADMIN_PASS_HASH" | sudo tee "$ADMIN_AUTH_FILE" > /dev/null
        sudo chmod 640 "$ADMIN_AUTH_FILE"
        print_info "Basic auth enabled for admin and protected API endpoints."
    fi

    read -p "Restrict /admin and protected APIs to specific IP/CIDR ranges? (y/n): " ADMIN_ALLOWLIST_ENABLED
    if [ "$ADMIN_ALLOWLIST_ENABLED" = "y" ]; then
        read -p "Enter allowed IP/CIDR values (space-separated): " ADMIN_ALLOWLISTS
        if [ -n "$ADMIN_ALLOWLISTS" ]; then
            ADMIN_ALLOWLIST_DIRECTIVES="        allow 127.0.0.1;
        allow ::1;
"
            for CIDR in $ADMIN_ALLOWLISTS; do
                ADMIN_ALLOWLIST_DIRECTIVES="${ADMIN_ALLOWLIST_DIRECTIVES}        allow $CIDR;
"
            done
            ADMIN_ALLOWLIST_DIRECTIVES="${ADMIN_ALLOWLIST_DIRECTIVES}        deny all;
"
            print_info "IP allowlist enabled for admin and protected API endpoints."
        else
            print_warn "No IP/CIDR values entered. Skipping allowlist."
        fi
    fi

    # Configure Nginx
    print_info "Configuring Nginx..."
    if [ "$ADMIN_AUTH_ENABLED" = "y" ]; then
        sudo bash -c "cat > /etc/nginx/sites-available/directory" <<EOF
server {
    listen 80;
    server_name _;
    client_max_body_size 100m;

    location / {
        root $INSTALL_DIR/kiosk;
        index index.html;
        try_files \$uri \$uri/ =404;
    }

    location /admin {
        alias $INSTALL_DIR/server/admin;
        index index.html;
        try_files \$uri \$uri/ /admin/index.html;
${ADMIN_ALLOWLIST_DIRECTIVES}        auth_basic "Directory Admin";
        auth_basic_user_file $ADMIN_AUTH_FILE;
    }

    location ~ ^/api/(kiosks|backup|restore)$ {
${ADMIN_ALLOWLIST_DIRECTIVES}        auth_basic "Directory Admin";
        auth_basic_user_file $ADMIN_AUTH_FILE;
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    location /api {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        limit_except GET HEAD OPTIONS {
${ADMIN_ALLOWLIST_DIRECTIVES}            auth_basic "Directory Admin";
            auth_basic_user_file $ADMIN_AUTH_FILE;
        }
    }

    location /uploads {
        proxy_pass http://127.0.0.1:3000;
        proxy_buffering off;
        proxy_max_temp_file_size 0;
    }
}
EOF
    else
        sudo bash -c "cat > /etc/nginx/sites-available/directory" <<EOF
server {
    listen 80;
    server_name _;
    client_max_body_size 100m;

    location / {
        root $INSTALL_DIR/kiosk;
        index index.html;
        try_files \$uri \$uri/ =404;
    }

    location /admin {
        alias $INSTALL_DIR/server/admin;
        index index.html;
        try_files \$uri \$uri/ /admin/index.html;
${ADMIN_ALLOWLIST_DIRECTIVES}    }

    location ~ ^/api/(kiosks|backup|restore)$ {
${ADMIN_ALLOWLIST_DIRECTIVES}        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    location /api {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    location /uploads {
        proxy_pass http://127.0.0.1:3000;
        proxy_buffering off;
        proxy_max_temp_file_size 0;
    }
}
EOF
    fi

    sudo ln -sf /etc/nginx/sites-available/directory /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t
    sudo systemctl enable nginx
    sudo systemctl restart nginx

    # Start server
    print_info "Starting directory server..."
    sudo systemctl start directory-server

    # Load sample data if requested
    if [ -f "$INSTALL_DIR/server/.load-sample-data" ]; then
        print_info "Loading sample data..."
        sleep 2
        sqlite3 "$INSTALL_DIR/server/directory.db" < "$INSTALL_DIR/scripts/sample-data.sql"
        rm "$INSTALL_DIR/server/.load-sample-data"
    fi

    # Post-install verification
    print_header "Server Verification"
    if sudo systemctl is-active --quiet directory-server; then
        print_info "directory-server service is active"
    else
        print_error "directory-server service is not active"
    fi
    # These checks are informational. They should not abort a "both" install
    # before the client configuration and optional Elo prompt run.
    wait_for_http_ok "http://127.0.0.1:3000/api/data-version" "API health check (/api/data-version)" || true
    wait_for_http_ok "http://127.0.0.1:3000/api/kiosks" "Deploy API check (/api/kiosks)" || true
    wait_for_http_ok "http://127.0.0.1:3000/api/backup.txt" "Backup API check (/api/backup.txt)" || true

    LOCAL_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')

    print_header "Server Installation Complete!"
    echo "Server is running at:"
    echo "  Kiosk Interface: http://$LOCAL_IP/"
    echo "  Admin Interface: http://$LOCAL_IP/admin"
    echo ""
    echo "Service management:"
    echo "  sudo systemctl status directory-server"
    echo "  sudo systemctl restart directory-server"
    echo ""
fi

# ── Kiosk client components ───────────────────────────────────────────────────
if [ "$INSTALL_MODE" = "client" ] || [ "$INSTALL_MODE" = "both" ]; then
    print_header "Installing Kiosk Client Components"

    # cage        — Wayland kiosk compositor (single-app fullscreen)
    # chromium    — kiosk browser
    # wlr-randr   — Wayland output resolution control (runs inside cage session)
    # xfce4       — admin desktop (started when keyboard is plugged in)
    # xserver-xorg + xserver-xorg-input-libinput — X11 for XFCE + touch support
    # overlayroot — read-only filesystem overlay (power-failure safe)
    print_info "Installing kiosk and admin desktop packages..."
    sudo apt install -y \
        cage \
        chromium \
        wlr-randr \
        xfce4 \
        xserver-xorg \
        xserver-xorg-input-libinput \
        overlayroot

    # Create installation directory if not exists
    mkdir -p "$INSTALL_DIR/scripts"
    mkdir -p "$INSTALL_DIR/vendor"

    # Copy kiosk scripts
    print_info "Installing kiosk scripts..."
    cp "$RUNTIME_SCRIPTS_SRC/start-kiosk.sh"    "$INSTALL_DIR/scripts/"
    cp "$RUNTIME_SCRIPTS_SRC/start-kiosk-lib.sh" "$INSTALL_DIR/scripts/"
    cp "$RUNTIME_SCRIPTS_SRC/restart-kiosk.sh"  "$INSTALL_DIR/scripts/"
    cp "$RUNTIME_SCRIPTS_SRC/kiosk-guard"       "$INSTALL_DIR/scripts/"
    cp "$RUNTIME_SCRIPTS_SRC/kiosk-guard.service" "$INSTALL_DIR/scripts/"
    cp "$RUNTIME_SCRIPTS_SRC/install-elo-driver.sh" "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts/start-kiosk.sh"
    chmod +x "$INSTALL_DIR/scripts/start-kiosk-lib.sh"
    chmod +x "$INSTALL_DIR/scripts/restart-kiosk.sh"
    chmod +x "$INSTALL_DIR/scripts/kiosk-guard"
    chmod +x "$INSTALL_DIR/scripts/install-elo-driver.sh"

    if [ -d vendor/elo-mt-usb ]; then
        rm -rf "$INSTALL_DIR/vendor/elo-mt-usb"
        cp -r vendor/elo-mt-usb "$INSTALL_DIR/vendor/"
    fi

    # Update server URL defaults in start-kiosk-lib.sh
    if [ "$INSTALL_MODE" = "both" ]; then
        sed -i "s|KIOSK_SERVER_URL:-http://.*}|KIOSK_SERVER_URL:-http://localhost}|" \
            "$INSTALL_DIR/scripts/start-kiosk-lib.sh"
    else
        sed -i "s|KIOSK_SERVER_URL:-http://.*}|KIOSK_SERVER_URL:-http://$SERVER_IP}|" \
            "$INSTALL_DIR/scripts/start-kiosk-lib.sh"
    fi

    # Install udev rule — fires when a USB keyboard is plugged in
    print_info "Installing keyboard detection udev rule..."
    sudo cp "$RUNTIME_SCRIPTS_SRC/99-kiosk-keyboard.rules" \
        /etc/udev/rules.d/99-kiosk-keyboard.rules
    sudo cp "$RUNTIME_SCRIPTS_SRC/99-elo-usb-power.rules" \
        /etc/udev/rules.d/99-elo-usb-power.rules

    # Install the script that the udev rule calls
    sudo cp "$RUNTIME_SCRIPTS_SRC/kiosk-keyboard-added.sh" \
        /usr/local/bin/kiosk-keyboard-added.sh
    sudo chmod 755 /usr/local/bin/kiosk-keyboard-added.sh

    # Ensure pressing or holding the physical power button powers down.
    sudo mkdir -p /etc/systemd/logind.conf.d
    sudo cp "$RUNTIME_SCRIPTS_SRC/80-kiosk-power-button.conf" \
        /etc/systemd/logind.conf.d/80-kiosk-power-button.conf

    # Disable xfce4-notifyd in kiosk mode (cage Wayland) to avoid
    # notification daemon errors on the display.
    sudo systemctl --global mask xfce4-notifyd.service
    # Sound is not used on kiosk hosts. Mask PulseAudio user units to avoid
    # repeated session startup failures on the read-only home directory.
    disable_pulseaudio_user_units
    # Wired kiosk deployments do not use the onboard Broadcom Wi-Fi device.
    sudo install -D -m 644 "$RUNTIME_SCRIPTS_SRC/kiosk-blacklist-wireless.conf" /etc/modprobe.d/kiosk-blacklist-wireless.conf
    disable_pam_wtmpdb
    ensure_var_log_tmpfs

    sudo udevadm control --reload-rules

    read -p "Install optional Elo legacy touchscreen driver bundle (IntelliTouch/2700)? (y/n): " INSTALL_ELO_DRIVER
    if [ "$INSTALL_ELO_DRIVER" = "y" ]; then
        print_info "Installing optional Elo legacy touchscreen driver..."
        "$PWD/scripts/install-elo-driver.sh"
    else
        print_info "Skipping optional Elo legacy touchscreen driver."
    fi

    # Allow kiosk deploys to run required root commands without a password.
    # Used by the server admin Deploy tab via tools/deploy-ssh.sh --client.
    print_info "Configuring passwordless sudo for kiosk deploy..."
    sudo bash -c "cat > /etc/sudoers.d/kiosk-deploy" <<EOF
$USER ALL=(root) NOPASSWD: /usr/sbin/overlayroot-chroot, /usr/bin/udevadm, /usr/bin/tee, /bin/mkdir, /bin/cp, /bin/rm
EOF
    sudo chmod 440 /etc/sudoers.d/kiosk-deploy

    # Configure getty autologin on tty1 (no display manager needed)
    print_info "Configuring getty autologin..."
    sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
    sudo bash -c "cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER --noclear %I \$TERM
EOF

    print_info "Installing kiosk-guard service..."
    sudo install -D -m 755 "$INSTALL_DIR/scripts/kiosk-guard" /usr/local/sbin/kiosk-guard
    sudo install -D -m 644 "$INSTALL_DIR/scripts/kiosk-guard.service" /etc/systemd/system/kiosk-guard.service
    sudo systemctl enable kiosk-guard.service

    # .bash_profile: kiosk loop with XFCE fallback on keyboard insertion
    print_info "Creating .bash_profile for kiosk autostart..."
    install -D -m 644 "$INSTALL_DIR/scripts/bash_profile" "$HOME/.bash_profile"

    # Seed the per-user Chromium state expected by the Debian wrapper so the
    # first kiosk launch does not die in crashpad initialization on fresh hosts.
    print_info "Seeding Chromium user state..."
    install -d -m 700 \
        "$HOME/.config/chromium/Crash Reports/attachments" \
        "$HOME/.config/chromium/Crash Reports/completed" \
        "$HOME/.config/chromium/Crash Reports/pending" \
        "$HOME/.config/chromium/Crash Reports/new" \
        "$HOME/.pki/nssdb"
    : > "$HOME/.config/chromium/Crash Reports/settings.dat"
    chmod 600 "$HOME/.config/chromium/Crash Reports/settings.dat"
    if command -v certutil >/dev/null 2>&1 && [ ! -f "$HOME/.pki/nssdb/cert9.db" ]; then
        certutil -d sql:"$HOME/.pki/nssdb" -N --empty-password >/dev/null 2>&1 || true
    fi

    # pam_wtmpdb writes to the readonly root and breaks tty1 autologin on kiosk
    # hosts after reboot. Remove it from the common session stack.
    if grep -q 'pam_wtmpdb\.so' /etc/pam.d/common-session 2>/dev/null; then
        sudo sed -i '/pam_wtmpdb\.so/d' /etc/pam.d/common-session
    fi

    # Printing is not part of the kiosk/server runtime. If installed directly or as
    # a dependency (for example through desktop packages), it writes to /var/log/cups
    # on overlayroot hosts and creates avoidable read-only-filesystem error spam.
    disable_print_stack

    disable_overlayroot_noise_services

    sudo systemctl set-default multi-user.target
    sudo systemctl daemon-reload
    sudo systemctl restart kiosk-guard.service

    # Set up overlayroot — makes the filesystem read-only (tmpfs upper layer).
    # Power failures cannot corrupt the OS; uploaded images and settings are
    # written directly to the ext4 lower layer via persist-upload.sh.
    print_info "Configuring overlayroot..."
    echo 'overlayroot="tmpfs"' | sudo tee /etc/overlayroot.conf > /dev/null
    print_warn "Overlayroot is configured. After reboot the filesystem is read-only."
    print_warn "Use tools/deploy-ssh.sh for all future file changes."

    print_header "Kiosk Client Installation Complete!"
    echo "On next boot:"
    echo "  - Kiosk starts automatically (cage + Chromium fullscreen)"
    echo "  - Plug in a USB keyboard to stop the kiosk and open XFCE"
    echo "  - Log out of XFCE to restart the kiosk"
    echo ""
    echo "Server URL: http://${SERVER_IP:-localhost}"
    echo ""

    read -p "Reboot now to activate overlayroot and start kiosk? (y/n): " REBOOT
    if [ "$REBOOT" = "y" ]; then
        print_info "Rebooting in 5 seconds..."
        sleep 5
        sudo reboot
    fi
fi

# Final summary
print_header "Installation Summary"
print_info "Installation directory: $INSTALL_DIR"
print_info "Installation mode: $INSTALL_MODE"
print_info "Installation complete!"
