# Development Environment

## Overview

The development machine is the `security` user's workstation at `/home/security/Public-Kiosk`. Development and local testing happen directly on this machine. Changes are deployed to the production kiosk hardware via SSH.

## Local Runtime

The deployed runtime on this machine lives at `/home/security/building-directory`. It is kept in sync with the repo via `tools/deploy-local.sh`.

```
Repo source:     /home/security/Public-Kiosk/
Deployed runtime: /home/security/building-directory/
```

## Development Workflow

```
┌─────────────────────────────────────────────────────────────┐
│                     Development Cycle                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. Edit files in /home/security/Public-Kiosk               │
│              ↓                                               │
│  2. Deploy locally: tools/deploy-local.sh                   │
│              ↓                                               │
│  3. Restart service: sudo systemctl restart directory-server │
│              ↓                                               │
│  4. Test via browser at http://127.0.0.1/admin              │
│              ↓                                               │
│  5. Deploy to production: tools/deploy-ssh.sh               │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Quick Setup (After Fresh Clone)

```bash
# 1. Deploy local runtime from repo
cd /home/security/Public-Kiosk
./tools/deploy-local.sh --full

# 2. Restart service
sudo systemctl restart directory-server

# 3. Pull authoritative database from production
./tools/sync-primary-db.sh --skip-standby

# 4. Verify
curl -i http://127.0.0.1/api/data-version
```

See `docs/dev-reattachment.md` for the full rebuild sequence.

## Network Access

```
Local service  → http://127.0.0.1/admin
Production     → ssh kiosk@192.168.1.80
Standby        → 192.168.1.81 (not yet deployed)
```

## Key Differences: Dev Machine vs Kiosk Hardware

| Aspect | Dev Machine | Kiosk Hardware |
|--------|-------------|----------------|
| Watchdog | Software only (`softdog`) | Hardware (`/dev/watchdog`) |
| Display | Desktop | Direct to touchscreen |
| Filesystem | Read-write | Read-only overlay |
| Database | `/home/security/building-directory/server/directory.db` | `/data/directory/directory.db` |

## Testing Checklist

Before deploying to hardware, verify locally:

- [ ] Kiosk display loads correctly
- [ ] Search functionality works
- [ ] Admin interface accessible at `/admin`
- [ ] Data persists after service restart
- [ ] Health checks pass: `/api/auth/me`, `/api/data-version`
