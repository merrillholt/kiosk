#!/bin/bash

###############################################################################
# Building Directory Kiosk - Installation Script
# For Debian 13 (Trixie)
###############################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Installation directory
INSTALL_DIR="$HOME/building-directory"

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

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Please do not run this script as root or with sudo"
    exit 1
fi

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
sudo apt install -y git curl wget unzip sqlite3

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

    # Create installation directory
    print_info "Creating installation directory: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    # Copy server files
    print_info "Copying server files..."
    cp -r server "$INSTALL_DIR/"
    cp -r scripts "$INSTALL_DIR/"
    cp -r kiosk "$INSTALL_DIR/"

    # Install Node.js dependencies
    print_info "Installing Node.js dependencies..."
    cd "$INSTALL_DIR/server"
    npm install
    cd - > /dev/null

    # Create database
    print_info "Initializing database..."
    if [ -f "$INSTALL_DIR/scripts/sample-data.sql" ]; then
        read -p "Load sample data? (y/n): " LOAD_SAMPLE
        if [ "$LOAD_SAMPLE" = "y" ]; then
            touch "$INSTALL_DIR/server/.load-sample-data"
        fi
    fi

    # Install privileged persist helper (writes uploads to overlayroot lower layer)
    print_info "Installing persist-upload helper..."
    sudo cp server/persist-upload.sh /usr/local/bin/persist-upload.sh
    sudo chmod 755 /usr/local/bin/persist-upload.sh
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
User=$USER
WorkingDirectory=$INSTALL_DIR/server
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=directory-server
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable directory-server

    # Configure Nginx
    print_info "Configuring Nginx..."
    sudo bash -c "cat > /etc/nginx/sites-available/directory" <<EOF
server {
    listen 80;
    server_name _;
    client_max_body_size 20m;

    location / {
        root $INSTALL_DIR/kiosk;
        index index.html;
        try_files \$uri \$uri/ =404;
    }

    location /admin {
        alias $INSTALL_DIR/server/admin;
        index index.html;
        try_files \$uri \$uri/ /admin/index.html;
    }

    location /api {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    location /uploads {
        proxy_pass http://localhost:3000;
    }
}
EOF

    sudo ln -sf /etc/nginx/sites-available/directory /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t
    sudo systemctl enable nginx
    sudo systemctl restart nginx

    # Start server
    print_info "Starting directory server..."
    sudo systemctl start directory-server
    sleep 3

    # Load sample data if requested
    if [ -f "$INSTALL_DIR/server/.load-sample-data" ]; then
        print_info "Loading sample data..."
        sleep 2
        sqlite3 "$INSTALL_DIR/server/directory.db" < "$INSTALL_DIR/scripts/sample-data.sql"
        rm "$INSTALL_DIR/server/.load-sample-data"
    fi

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

    # Copy kiosk scripts
    print_info "Installing kiosk scripts..."
    cp scripts/start-kiosk.sh    "$INSTALL_DIR/scripts/"
    cp scripts/restart-kiosk.sh  "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts/start-kiosk.sh"
    chmod +x "$INSTALL_DIR/scripts/restart-kiosk.sh"

    # Update server URL in start-kiosk.sh
    if [ "$INSTALL_MODE" = "both" ]; then
        sed -i "s|SERVER_URL=.*|SERVER_URL=\"http://localhost\"|" \
            "$INSTALL_DIR/scripts/start-kiosk.sh"
    else
        sed -i "s|SERVER_URL=.*|SERVER_URL=\"http://$SERVER_IP\"|" \
            "$INSTALL_DIR/scripts/start-kiosk.sh"
    fi

    # Install udev rule — fires when a USB keyboard is plugged in
    print_info "Installing keyboard detection udev rule..."
    sudo cp scripts/99-kiosk-keyboard.rules \
        /etc/udev/rules.d/99-kiosk-keyboard.rules

    # Install the script that the udev rule calls
    sudo cp scripts/kiosk-keyboard-added.sh \
        /usr/local/bin/kiosk-keyboard-added.sh
    sudo chmod 755 /usr/local/bin/kiosk-keyboard-added.sh

    sudo udevadm control --reload-rules

    # Configure getty autologin on tty1 (no display manager needed)
    print_info "Configuring getty autologin..."
    sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
    sudo bash -c "cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER --noclear %I \$TERM
EOF

    # .bash_profile: kiosk loop with XFCE fallback on keyboard insertion
    print_info "Creating .bash_profile for kiosk autostart..."
    cat > "$HOME/.bash_profile" <<EOF
# Auto-start kiosk on tty1.
# Use $(tty) rather than XDG_VTNR — agetty --autologin does not
# reliably set XDG_VTNR via PAM.
if [[ "\$(tty 2>/dev/null)" == "/dev/tty1" ]]; then
    export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
    mkdir -p "\${XDG_RUNTIME_DIR}"
    chmod 700 "\${XDG_RUNTIME_DIR}"

    # Loop: restart kiosk automatically after a crash or manual restart.
    # When a USB keyboard is plugged in, udev writes /tmp/kiosk-exit and
    # kills cage. The loop then starts XFCE on the touchscreen for admin
    # access. When the admin logs out of XFCE the kiosk restarts.
    while true; do
        rm -f /tmp/kiosk-exit
        $INSTALL_DIR/scripts/start-kiosk.sh
        if [[ -f /tmp/kiosk-exit ]]; then
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
EOF

    sudo systemctl set-default multi-user.target
    sudo systemctl daemon-reload

    # Set up overlayroot — makes the filesystem read-only (tmpfs upper layer).
    # Power failures cannot corrupt the OS; uploaded images and settings are
    # written directly to the ext4 lower layer via persist-upload.sh.
    print_info "Configuring overlayroot..."
    echo 'overlayroot="tmpfs"' | sudo tee /etc/overlayroot.conf > /dev/null
    print_warn "Overlayroot is configured. After reboot the filesystem is read-only."
    print_warn "Use deploy.sh for all future file changes."

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
