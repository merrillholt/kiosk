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
+-------------------------------------------------------------+
|                     Development Cycle                       |
+-------------------------------------------------------------+
|                                                             |
|  1. Edit files in /home/security/Public-Kiosk               |
|              v                                              |
|  2. Deploy locally: tools/deploy-local.sh                   |
|              v                                              |
|  3. Restart service: sudo systemctl restart directory-server|
|              v                                              |
|  4. Test via browser at http://127.0.0.1/admin              |
|              v                                              |
|  5. Deploy to production: tools/deploy-ssh.sh               |
|                                                             |
+-------------------------------------------------------------+
```

## Quick Setup (After Fresh Clone)

```bash
# 1. Clone the repo and enter it
git clone git@github.com:merrillholt/kiosk.git /home/security/Public-Kiosk
cd /home/security/Public-Kiosk

# 2. Regenerate the install tree and packaged docs
./tools/sync-install-tree.sh

# 3. Deploy local runtime from repo
./tools/deploy-local.sh --full

# 4. Restart service
sudo systemctl restart directory-server

# 5. Pull authoritative database from production
./tools/sync-primary-db.sh --skip-standby

# 6. Verify
curl -i http://127.0.0.1/api/data-version
./scripts/kioskctl --no-color status
```

See `docs/dev-reattachment.md` for the full rebuild sequence.

## Update Existing Dev Checkout

```bash
# 1. Update the local checkout
cd /home/security/Public-Kiosk
git pull --ff-only

# 2. Regenerate the install tree and packaged docs
./tools/sync-install-tree.sh
./tools/check-install-drift.sh

# 3. Refresh the local runtime
./tools/deploy-local.sh --full
sudo systemctl restart directory-server

# 4. Refresh local data from production when needed
./tools/sync-primary-db.sh --skip-standby

# 5. Verify
curl -i http://127.0.0.1/api/data-version
./scripts/kioskctl --no-color status
```

## Network Access

```
Local service  → http://127.0.0.1/admin
Production     → ssh kiosk@192.168.1.80
Standby        → ssh kiosk@192.168.1.81
Client-only    → ssh kiosk@192.168.1.82
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
