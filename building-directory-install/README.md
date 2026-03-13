# Building Directory Kiosk System

A complete touchscreen kiosk solution for building directories with centralized management.

## Features

- **Interactive Touchscreen Interface**: Touch-friendly search with on-screen keyboard
- **Three Main Sections**: Companies, Individuals, and Building Information
- **Centralized Management**: Web-based admin interface for easy updates
- **Auto-Sync**: Kiosks automatically update when data changes
- **Offline Capable**: Cached data allows operation during network issues
- **Professional Design**: Modern, responsive UI suitable for commercial environments

## System Requirements

- **Operating System**: Kubuntu 25, Ubuntu 24.04+, or similar Debian-based Linux
- **Hardware**: 
  - Server: Any PC with 2GB RAM, 10GB storage
  - Kiosk Client: Mini PC with touchscreen support
- **Network**: Local network connectivity between server and clients

## Quick Start Installation

### 1. Extract the Package

```bash
unzip building-directory-install.zip
cd building-directory-install
```

### 2. Run Installation Script

```bash
chmod +x install.sh
./install.sh
```

The installer will prompt you to choose:
- **Server** - Installs server components and admin interface
- **Client** - Installs kiosk display software  
- **Both** - Installs everything (for testing)

### 3. Access the System

After installation:

**Server URLs:**
- Kiosk Display: `http://SERVER_IP/`
- Admin Interface: `http://SERVER_IP/admin`

**Default Credentials:** Optional. Server install now offers built-in HTTP Basic Auth setup for `/admin` and protected API endpoints.

## Installation Modes

### Server Installation

On your central server machine:

```bash
./install.sh
# Select option 1 (Server)
```

This installs:
- Node.js server with REST API
- SQLite database
- Admin web interface
- Nginx web server
- Systemd service for auto-start

During server install, you can optionally enable:
- HTTP Basic Auth for `/admin` and write/sensitive `/api` endpoints
- IP/CIDR allowlist for `/admin` and protected API endpoints

### Client Installation  

On each kiosk display machine:

```bash
./install.sh
# Select option 2 (Client)
# Enter server IP address when prompted
```

This installs:
- Chromium browser in kiosk mode
- Auto-start configuration
- Screen management utilities
- **Keyboard breakout to admin desktop**: Plugging in a USB keyboard stops the kiosk and launches XFCE for admin access. Logging out of XFCE restarts the kiosk.
- **Optional Elo legacy driver**: The installer can optionally enable the bundled Elo Linux driver for older IntelliTouch/2700 panels. Leave this disabled for newer HID-native Elo models.

### Testing Installation

For development/testing on a single machine:

```bash
./install.sh
# Select option 3 (Both)
```

## Post-Installation

### Server Management

```bash
# Check server status
sudo systemctl status directory-server

# Restart server
sudo systemctl restart directory-server

# View logs
sudo journalctl -u directory-server -f
```

### Server Verification

```bash
# Service health
sudo systemctl status directory-server --no-pager

# Confirm running code path
PID=$(systemctl show -p MainPID --value directory-server)
sudo readlink -f /proc/$PID/cwd
sudo tr '\0' ' ' < /proc/$PID/cmdline; echo

# API checks
curl -i http://127.0.0.1:3000/api/data-version
curl -i http://127.0.0.1:3000/api/kiosks
curl -I http://127.0.0.1:3000/api/backup

# Public URL checks via nginx
curl -i http://127.0.0.1/api/data-version
curl -i http://127.0.0.1/admin
```

### Kiosk Client Management

```bash
# Manually start kiosk
~/building-directory/scripts/start-kiosk.sh

# Restart kiosk
~/building-directory/scripts/restart-kiosk.sh

# Optional: enable the bundled Elo legacy driver later
~/building-directory/scripts/install-elo-driver.sh
```

### Database Backups

Backups run automatically at 2 AM daily to:
```
~/building-directory-backups/
```

Manual backup:
```bash
~/building-directory/scripts/backup.sh
```

## Directory Structure

```
~/building-directory/
├── server/
│   ├── server.js          # Main server application
│   ├── directory.db       # SQLite database
│   ├── admin/             # Admin interface files
│   └── package.json
├── kiosk/                 # Kiosk display files
│   ├── index.html
│   ├── styles.css
│   └── app.js
└── scripts/               # Utility scripts
    ├── start-kiosk.sh
    ├── restart-kiosk.sh
    ├── install-elo-driver.sh
    └── backup.sh
```

## Using the Admin Interface

1. Open browser to `http://SERVER_IP/admin`
2. Use tabs to manage:
   - **Companies**: Add/edit company listings
   - **Individuals**: Add/edit individual listings  
   - **Building Info**: Update general building information

Changes sync automatically to all kiosks within 60 seconds.

If Basic Auth is enabled during install, your browser will prompt for credentials before accessing `/admin` and protected API operations.

## Troubleshooting

### Server won't start

```bash
# Check listener (expected: 127.0.0.1:3000)
sudo ss -ltnp | grep ':3000'

# Check Node.js installation
node --version

# View error logs
sudo journalctl -u directory-server -n 50
```

### Kiosk not connecting to server

```bash
# Check network connectivity
ping SERVER_IP

# Verify server URL in kiosk script
cat ~/building-directory/scripts/start-kiosk.sh | grep SERVER_URL

# Test server from kiosk
curl http://SERVER_IP/api/companies
```

### Touchscreen not responding

```bash
# Check if Chromium recognizes touch events
# Look for touch device in xinput
xinput list
```

### Legacy Elo Touchscreens

Use the optional Elo driver only for older IntelliTouch / 2700-class displays.
The bundled driver starts `elomtusbd` in `--stdigitizer` mode and is intended
for kiosks where the generic stack reports pointer-style touch behavior.

Enable it when:
- touch input is reported as pointer or mouse clicks
- the display is an older Elo legacy touchscreen

Skip it when:
- the kiosk uses a newer HID-native Elo model
- touch already behaves correctly with the default stack

Manual install after initial setup:

```bash
~/building-directory/scripts/install-elo-driver.sh
sudo systemctl status elo.service --no-pager
```

## Network Configuration

### Finding Server IP

On the server:
```bash
ip addr show | grep inet
```

### Firewall Configuration

If using UFW:
```bash
sudo ufw allow 80/tcp
```

Note: in production, port `3000` is local-only and should not be opened on LAN.

## Customization

### Changing Inactivity Timeout

Edit `/home/user/building-directory/kiosk/app.js`:
```javascript
const CONFIG = {
    INACTIVITY_TIMEOUT: 120000,  // milliseconds (120000 = 2 minutes)
    ...
};
```

### Modifying UI Colors/Styles

Edit `/home/user/building-directory/kiosk/styles.css`

### Changing Update Frequency

Edit `/home/user/building-directory/kiosk/app.js`:
```javascript
const CONFIG = {
    REFRESH_INTERVAL: 60000,  // milliseconds (60000 = 1 minute)
    ...
};
```

## Updating the System

To update files after modifying source:

```bash
# On server
sudo systemctl restart directory-server

# On kiosk
~/building-directory/scripts/restart-kiosk.sh
```

## Uninstallation

### Remove Server

```bash
sudo systemctl stop directory-server
sudo systemctl disable directory-server
sudo rm /etc/systemd/system/directory-server.service
sudo systemctl daemon-reload
sudo rm /etc/nginx/sites-enabled/directory
sudo systemctl restart nginx
rm -rf ~/building-directory
```

### Remove Client

```bash
rm ~/.config/autostart/directory-kiosk.desktop
rm -rf ~/building-directory
```

## Support

For issues or questions:
1. Check this README
2. Review logs: `sudo journalctl -u directory-server`
3. Verify network connectivity
4. Check file permissions

## License

MIT License - Free for commercial and personal use.

## Version

1.0.0 (January 2026)
