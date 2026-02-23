# Hardware Requirements

## Target Hardware

This application is designed for deployment on mini PCs such as the Qotom Q305P or similar fanless industrial computers.

### Reference Hardware: Qotom Q305P

| Spec | Value | Assessment |
|------|-------|------------|
| CPU | Intel Celeron 3205U | Adequate for web kiosk |
| RAM | 4GB (max 8GB) | Sufficient for Chromium kiosk mode |
| Storage | 32GB SSD | Tight but workable |
| Design | Fanless | Excellent for 24/7 reliability |
| Ports | COM ports, USB, Ethernet | Suitable for kiosk peripherals |

### Why This Hardware Works

**Pros:**
- Fanless design = silent operation, no moving parts to fail
- Low power consumption
- Compact form factor for mounting behind displays
- COM ports available if serial peripherals are needed
- Industrial-grade reliability

**Storage Considerations:**

With 32GB storage, space is limited. A minimal Linux install + Chromium + the application uses approximately 8-12GB, leaving headroom. Recommendations:

- Use a lightweight distro (Debian minimal or Ubuntu Server minimal)
- Disable swap or use zram
- Configure log rotation aggressively
- Use read-only filesystem to prevent log/temp file accumulation

### Recommended Display

- Touchscreen monitor (capacitive recommended over resistive)
- 1920x1080 or 1280x720 resolution
- HDMI or DisplayPort input
- VESA mount for kiosk enclosure

### Network Requirements

- Ethernet connection (recommended for reliability)
- WiFi possible but not recommended for permanent installation
- Static IP or DHCP reservation recommended

## Scaling to Multiple Kiosks

The application supports a server + multiple client architecture:

```
┌─────────────┐     ┌─────────────┐
│  Kiosk 1    │────▶│             │
├─────────────┤     │   Server    │
│  Kiosk 2    │────▶│  (Node.js)  │
├─────────────┤     │   + SQLite  │
│  Kiosk 3    │────▶│             │
└─────────────┘     └─────────────┘
```

Options:
1. **Dedicated server** - One machine runs the server, others are display-only
2. **Server on kiosk** - One kiosk runs both server and display, others connect to it
3. **All-in-one** - Each kiosk runs independently (for testing or isolated deployments)
