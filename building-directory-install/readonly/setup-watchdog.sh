#!/bin/bash
###############################################################################
# Hardware Watchdog Setup
# Automatically reboots the kiosk if it becomes unresponsive
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (sudo)"
    exit 1
fi

echo ""
echo "============================================="
echo "  Hardware Watchdog Setup"
echo "============================================="
echo ""

# Check for hardware watchdog
print_info "Checking for hardware watchdog..."
if [ -e /dev/watchdog ]; then
    print_info "Hardware watchdog found: /dev/watchdog"
else
    print_warn "No hardware watchdog detected"
    echo "The software watchdog will still work but cannot recover from kernel hangs."
fi

# Install watchdog package
print_info "Installing watchdog package..."
apt update
apt install -y watchdog

# Configure watchdog
print_info "Configuring watchdog..."
cat > /etc/watchdog.conf << 'EOF'
# Hardware watchdog device
watchdog-device = /dev/watchdog

# Ping interval (seconds)
interval = 10

# If load average exceeds this, reboot
max-load-1 = 24

# If memory falls below this (pages), reboot
min-memory = 1

# Monitor these files - if they don't change, reboot
#file = /var/log/syslog
#change = 300

# Monitor these processes - restart them if they die
pidfile = /var/run/nginx.pid

# Test binary that must succeed
#test-binary = /usr/local/bin/watchdog-test.sh

# Reboot on any error
realtime = yes
priority = 1

# Log watchdog events
log-dir = /var/log/watchdog

# Temperature monitoring (if available)
#temperature-sensor = /sys/class/thermal/thermal_zone0/temp
#max-temperature = 80

# Allocate memory for watchdog (prevents OOM killing watchdog)
allocatable-memory = 1

# Network ping test (reboot if network is unreachable)
#ping = 192.168.1.1
#ping = 8.8.8.8
EOF

# Create watchdog test script for kiosk health
print_info "Creating kiosk health check..."
cat > /usr/local/bin/kiosk-health-check.sh << 'EOF'
#!/bin/bash
# Health check script for watchdog
# Exit 0 = healthy, Exit non-zero = unhealthy (triggers reboot)

# Check if X server is running
if ! pgrep -x "Xorg" > /dev/null && ! pgrep -x "X" > /dev/null; then
    echo "X server not running"
    exit 1
fi

# Check if chromium is running (kiosk browser)
if ! pgrep -f "chromium" > /dev/null; then
    echo "Chromium not running"
    exit 1
fi

# Check if directory server is responding
if ! curl -sf http://localhost:3000/api/data-version > /dev/null 2>&1; then
    echo "Directory server not responding"
    exit 1
fi

# All checks passed
exit 0
EOF
chmod +x /usr/local/bin/kiosk-health-check.sh

# Enable watchdog to use test script
cat >> /etc/watchdog.conf << 'EOF'

# Kiosk health check
test-binary = /usr/local/bin/kiosk-health-check.sh
test-timeout = 30
EOF

# Enable and start watchdog
print_info "Enabling watchdog service..."
systemctl enable watchdog
systemctl start watchdog

# Create process monitor service (restarts crashed services without full reboot)
print_info "Creating process monitor service..."
cat > /etc/systemd/system/kiosk-monitor.service << 'EOF'
[Unit]
Description=Kiosk Process Monitor
After=graphical.target

[Service]
Type=simple
ExecStart=/usr/local/bin/kiosk-monitor.sh
Restart=always
RestartSec=10

[Install]
WantedBy=graphical.target
EOF

cat > /usr/local/bin/kiosk-monitor.sh << 'EOF'
#!/bin/bash
# Monitor and restart kiosk components if they crash

KIOSK_USER="kiosk"  # Change to your kiosk username
CHECK_INTERVAL=30

while true; do
    sleep $CHECK_INTERVAL

    # Check if chromium is running, restart if not
    if ! pgrep -f "chromium.*--kiosk" > /dev/null; then
        logger -t kiosk-monitor "Chromium not running, restarting..."
        su - $KIOSK_USER -c "DISPLAY=:0 /home/$KIOSK_USER/building-directory/scripts/start-kiosk.sh &"
        sleep 10
    fi

    # Check if directory server is running
    if ! systemctl is-active --quiet directory-server; then
        logger -t kiosk-monitor "Directory server not running, restarting..."
        systemctl restart directory-server
        sleep 5
    fi
done
EOF
chmod +x /usr/local/bin/kiosk-monitor.sh

systemctl daemon-reload
systemctl enable kiosk-monitor.service
systemctl start kiosk-monitor.service

echo ""
echo "============================================="
echo "  Watchdog Setup Complete"
echo "============================================="
echo ""
echo "The system will now automatically recover from:"
echo "  - X server crashes"
echo "  - Chromium crashes"
echo "  - Directory server crashes"
echo "  - System hangs (via hardware watchdog)"
echo ""
echo "Check watchdog status:"
echo "  systemctl status watchdog"
echo "  systemctl status kiosk-monitor"
echo ""
