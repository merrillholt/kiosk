#!/bin/bash

###############################################################################
# Building Directory Kiosk - Installation Script
# For Kubuntu 25 (or similar Ubuntu-based distributions)
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
echo "3) Both Server and Client (for testing)"
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

# Install server components
if [ "$INSTALL_MODE" = "server" ] || [ "$INSTALL_MODE" = "both" ]; then
    print_header "Installing Server Components"
    
    # Install Node.js
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
    
    # Create database
    print_info "Initializing database..."
    if [ -f "$INSTALL_DIR/scripts/sample-data.sql" ]; then
        read -p "Load sample data? (y/n): " LOAD_SAMPLE
        if [ "$LOAD_SAMPLE" = "y" ]; then
            # Database will be created on first server start
            touch "$INSTALL_DIR/server/.load-sample-data"
        fi
    fi
    
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

    # Kiosk interface
    location / {
        root $INSTALL_DIR/kiosk;
        index index.html;
        try_files \$uri \$uri/ =404;
    }

    # Admin interface
    location /admin {
        alias $INSTALL_DIR/server/admin;
        index index.html;
        try_files \$uri \$uri/ /admin/index.html;
    }

    # API proxy
    location /api {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
    
    sudo ln -sf /etc/nginx/sites-available/directory /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t
    sudo systemctl restart nginx
    
    # Setup backup cron job
    print_info "Setting up daily backups..."
    chmod +x "$INSTALL_DIR/scripts/backup.sh"
    (crontab -l 2>/dev/null | grep -v backup.sh; echo "0 2 * * * $INSTALL_DIR/scripts/backup.sh") | crontab -
    
    # Start server
    print_info "Starting directory server..."
    sudo systemctl start directory-server
    sleep 3
    
    # Check if sample data should be loaded
    if [ -f "$INSTALL_DIR/server/.load-sample-data" ]; then
        print_info "Loading sample data..."
        sleep 2
        sqlite3 "$INSTALL_DIR/server/directory.db" < "$INSTALL_DIR/scripts/sample-data.sql"
        rm "$INSTALL_DIR/server/.load-sample-data"
    fi
    
    # Get server IP
    LOCAL_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
    
    print_header "Server Installation Complete!"
    echo "Server is running at:"
    echo "  - Kiosk Interface: http://$LOCAL_IP/"
    echo "  - Admin Interface: http://$LOCAL_IP/admin"
    echo ""
    echo "Service management commands:"
    echo "  sudo systemctl status directory-server"
    echo "  sudo systemctl restart directory-server"
    echo "  sudo systemctl stop directory-server"
    echo ""
fi

# Install client components
if [ "$INSTALL_MODE" = "client" ] || [ "$INSTALL_MODE" = "both" ]; then
    print_header "Installing Kiosk Client Components"
    
    # Install Chromium and cage (Wayland kiosk compositor)
    print_info "Installing Chromium and cage..."
    sudo apt install -y chromium cage

    # Create installation directory if not exists
    mkdir -p "$INSTALL_DIR/scripts"

    # Copy kiosk scripts
    print_info "Installing kiosk scripts..."
    cp scripts/start-kiosk.sh "$INSTALL_DIR/scripts/"
    cp scripts/restart-kiosk.sh "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts/start-kiosk.sh"
    chmod +x "$INSTALL_DIR/scripts/restart-kiosk.sh"

    # Update server URL in script
    if [ "$INSTALL_MODE" = "both" ]; then
        sed -i "s|SERVER_URL=.*|SERVER_URL=\"http://localhost\"|" "$INSTALL_DIR/scripts/start-kiosk.sh"
    else
        sed -i "s|SERVER_URL=.*|SERVER_URL=\"http://$SERVER_IP\"|" "$INSTALL_DIR/scripts/start-kiosk.sh"
    fi

    # Configure getty autologin on tty1 (no display manager needed)
    print_info "Configuring getty autologin..."
    sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
    sudo bash -c "cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER --noclear %I \$TERM
EOF

    # Create .bash_profile to launch kiosk on tty1
    print_info "Creating .bash_profile for kiosk autostart..."
    cat > "$HOME/.bash_profile" <<EOF
# Auto-start kiosk on tty1
# XDG_VTNR is set by PAM/logind to the VT number (1 = tty1)
if [[ "\${XDG_VTNR}" == "1" ]]; then
    exec $INSTALL_DIR/scripts/start-kiosk.sh
fi
EOF

    sudo systemctl set-default multi-user.target
    sudo systemctl daemon-reload

    print_header "Kiosk Client Installation Complete!"
    echo "Kiosk will start automatically on boot via getty autologin."
    echo "Server URL: http://${SERVER_IP:-localhost}"
    echo ""
    echo "Manual start: $INSTALL_DIR/scripts/start-kiosk.sh"
    echo "Restart kiosk: $INSTALL_DIR/scripts/restart-kiosk.sh"
    echo ""

    read -p "Reboot now to start kiosk? (y/n): " REBOOT
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
echo ""
print_info "For documentation, see: $INSTALL_DIR/docs/"
echo ""
print_info "Installation complete!"
