# Building Directory Documentation

Documentation for the building directory kiosk application.

## Contents

| Document | Description |
|----------|-------------|
| [01-hardware-requirements.md](01-hardware-requirements.md) | Target hardware specs and considerations |
| [02-linux-distro-selection.md](02-linux-distro-selection.md) | Comparison of Linux distributions for kiosk use |
| [03-read-only-filesystem.md](03-read-only-filesystem.md) | Why and how to use a read-only root filesystem |
| [04-development-environment.md](04-development-environment.md) | VirtualBox VM setup for development |
| [05-architecture-overview.md](05-architecture-overview.md) | System architecture and data flow |
| [06-desktop-environment.md](06-desktop-environment.md) | Why no DE, minimal X11 setup |
| [07-touchscreen-setup.md](07-touchscreen-setup.md) | Touch connections, drivers, calibration |

## Quick Links

- **Installation:** See `building-directory-install/install.sh`
- **Read-only setup:** See `building-directory-install/readonly/`
- **Deployment guide:** See `building-directory-install/readonly/DEPLOYMENT.md`

## Target Configuration

- **Hardware:** Qotom Q305P or similar fanless mini PC
- **OS:** Debian 13 (Trixie) minimal
- **Storage:** 32GB SSD with read-only root + persistent /data partition
- **Development:** VirtualBox VM `kiosk-dev` at `192.168.1.127`, project shared at `/mnt/Public-Kiosk`
- **Project directory (host):** `/home/security/Public-Kiosk`
