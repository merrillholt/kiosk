# Server Operations

This document covers the building-directory server lifecycle: install, deploy, auth, runtime verification, and troubleshooting.

## Scope

- Server host setup and operation
- API/auth behavior
- Deploy workflow
- Service and nginx checks

Related docs:
- Client setup: `docs/10-new-host-installation.md`, `docs/06-desktop-environment.md`, `docs/07-touchscreen-setup.md`
- Packaging/deploy pipeline: `docs/08-packaging-and-deploy.md`
- Read-only filesystem: `docs/03-read-only-filesystem.md`

## Runtime Architecture

- Node.js Express backend serves API on port `3000` bound to `127.0.0.1` (local only).
- Nginx serves `kiosk/` and `admin/`, proxies `/api` and `/uploads` to `127.0.0.1:3000`.
- Nginx `client_max_body_size` is `100m` to accommodate DB restore uploads.
- Nginx proxies `/uploads` with `proxy_buffering off` and `proxy_max_temp_file_size 0`
  to avoid writes to `/var/lib/nginx/proxy` in overlay mode.
- SQLite DB: `server/directory.db` is a symlink to `/data/directory/directory.db`.
- Service name: `directory-server`.
- Application root on production: `/home/kiosk/building-directory/`

## Production Operations

Use `scripts/production-ops.sh` for day-to-day production tasks on the server host:

```bash
scripts/production-ops.sh status           # Health and storage state
scripts/production-ops.sh restart-server   # Restart directory-server service
scripts/production-ops.sh restart-kiosk    # Restart cage + chromium session
scripts/production-ops.sh backup           # Run local DB backup
scripts/production-ops.sh restore <file>   # Restore DB from local backup file
```

## Nginx Requirement

Production-style access expects nginx on port `80`:
- `http://<server-ip>/`
- `http://<server-ip>/admin`

If nginx is missing on a target host:
```bash
sudo apt-get update
sudo apt-get install -y nginx
```

If application files are under `/home/kiosk/...`, nginx must be able to
traverse `/home/kiosk`:
```bash
sudo chmod 711 /home/kiosk
```
This keeps home directory contents non-readable while allowing path traversal.

## Security Model

- Kiosk read API routes are IP allowlisted via `KIOSK_ALLOWED_IPS`.
- Admin API access requires session auth:
  - `POST /api/auth/login`
  - `POST /api/auth/logout`
  - `GET /api/auth/me`
- Admin UI logout clears session and redirects to `/` (kiosk client page).
- Admin password is `kiosk` — systems are physically secured; this is intentional.
- Keep nginx and firewall restricted to trusted networks.

### kiosk user sudo access

The `kiosk` user has passwordless sudo for all commands via `/etc/sudoers.d/kiosk-nopasswd`:

```
kiosk ALL=(ALL) NOPASSWD:ALL
```

This is required for:
- `deploy-ssh.sh` running `overlayroot-chroot` and `systemctl` remotely without a password
- `production-ops.sh` running `systemctl restart` and backup/restore operations
- `kiosk-guard` restarting the cage session

This grant is intentional. The kiosk user account has no password login (SSH key
only from the dev machine) and the hosts are on a physically isolated LAN.

## Initial Server Install

Use installer entry point:
- `building-directory-install/install.sh`
- Choose mode: `1) Server` or `3) Both`

Installer performs:
- Copies `server/`, `scripts/`, and `kiosk/`
- Installs Node.js dependencies
- Installs and enables `directory-server` service
- Configures nginx reverse proxy

## Day-2 Deploy (from Development Machine)

All deploys originate from the development machine at `/home/security/Public-Kiosk`.
A **clean git working tree is required** before deploying to protected IPs (`.80`, `.81`, `.82`).

- Server-only deploy (most common):
  - `tools/deploy-ssh.sh`
  - `make deploy-ssh`
- Full deploy (server + kiosk + scripts):
  - `tools/deploy-ssh.sh --full`
  - `make deploy-ssh-full`
- Preview actions:
  - `tools/deploy-ssh.sh --dry-run`
- Target a specific host:
  - `tools/deploy-ssh.sh --host kiosk@192.168.1.80`
- Include database promotion:
  - `tools/deploy-ssh.sh --with-db --db-source /home/security/building-directory/server/directory.db`

Remote deploy behavior:
1. Verifies clean git working tree (for protected IPs).
2. Syncs manifest-managed files over SSH to remote deploy root.
3. In overlay mode, writes to the lower layer via `overlayroot-chroot` (persistent without reboot).
4. In maintenance/writable mode, runs remote `npm ci --omit=dev`.
5. Writes the computed deployed revision to remote `REVISION`.
6. On `--full`, patches `scripts/start-kiosk.sh` with primary/standby URLs.
7. Attempts remote `sudo systemctl restart directory-server`.
8. Runs remote health checks: `/api/auth/me`, `/api/data-version`.
9. On `--full`, waits briefly and restarts the kiosk session.

If non-interactive sudo is unavailable remotely, restart manually on the target:
```bash
sudo systemctl restart directory-server
```

## Day-2 Deploy (Local Machine)

When testing changes locally before pushing to production:

- Server-only deploy:
  - `tools/deploy-local.sh`
  - `make deploy-local`
- Full deploy:
  - `tools/deploy-local.sh --full`
  - `make deploy-local-full`
- Preview:
  - `tools/deploy-local.sh --dry-run`

`deploy-local.sh` does not restart the service automatically — run:
```bash
sudo systemctl restart directory-server
```

## Service Operations

Check status:
```bash
systemctl is-active directory-server
systemctl status directory-server --no-pager
```

Restart:
```bash
sudo systemctl restart directory-server
# or via production-ops.sh:
scripts/production-ops.sh restart-server
```

Logs:
```bash
journalctl -u directory-server -n 100 --no-pager
journalctl -u directory-server -f
```

## Nginx Operations

Validate and reload:
```bash
sudo nginx -t
sudo systemctl reload nginx
```

Production nginx requirements:
- `client_max_body_size 100m` (accommodates DB restore uploads up to 100MB)
- Use `proxy_pass http://127.0.0.1:3000;` (not `localhost` — avoids IPv6 `::1` mismatches)
- In `location /uploads`:
  - `proxy_buffering off;`
  - `proxy_max_temp_file_size 0;`
- Site config root paths should reference `/home/kiosk/building-directory/...`

## Health Checks

Direct backend:
```bash
curl -i http://127.0.0.1:3000/api/auth/me
curl -i http://127.0.0.1:3000/api/data-version
```

Via nginx:
```bash
curl -i http://127.0.0.1/api/auth/me
curl -i http://127.0.0.1/admin
```

LAN check:
```bash
curl -i http://192.168.1.80/admin
```

## Environment Variables

Common server vars (set in `/etc/systemd/system/directory-server.service`):
- `PORT` (default `3000`)
- `KIOSK_ADMIN_PASSWORD` (default `kiosk`)
- `KIOSK_ALLOW_DEFAULT_PASSWORD` (set `true` to suppress startup warning)
- `KIOSK_ALLOWED_IPS`
- `KIOSK_SERVER_URL`
- `KIOSK_SERVER_URL_STANDBY`
- `KIOSK_CLIENTS`
- `KIOSK_SSH_KEY`
- `KIOSK_DB`
- `KIOSK_UPLOADS_LOWER` (optional override for uploaded background image directory)

## Admin Functions

### Background image upload/gallery

- Admin upload endpoint: `POST /api/background-image` (auth required).
- Gallery endpoint: `GET /api/background-images` (auth required).
- Upload persistence helper: `/usr/local/bin/persist-upload.sh`
- Runtime upload directory selection:
  - Uses `KIOSK_UPLOADS_LOWER` if set.
  - Else uses overlay lower path when present.
  - Else falls back to local `server/uploads` (maintenance mode / overlay disabled).

### Backup/restore

- Recommended admin backup download:
  - `GET /api/backup.txt` — returns SQL text dump as `directory-backup.txt`
- Restore endpoint:
  - `POST /api/restore` — accepts `.txt`, `.sql`, `.sqlite`, `.db` (max 100MB)
  - Returns DB row counts for `companies` and `individuals`
- Production-local scripts (run directly on server host):
  - `scripts/backup.sh` — creates timestamped backup in `/data/backups/building-directory/`, 60-day retention
  - `scripts/restore-db.sh <file>` — validates, stops service, restores, restarts
  - `scripts/production-ops.sh backup|restore` — wrapper for the above

## Troubleshooting

### Server not reachable on port 3000

Port `3000` is intentionally local-only in production.

1. Check service:
```bash
systemctl is-active directory-server
```
2. Check logs:
```bash
journalctl -u directory-server -n 80 --no-pager
```
3. Check listener:
```bash
ss -ltnp | grep ':3000'
```

### Admin URL fails but nginx is up

1. Validate nginx config: `sudo nginx -t`
2. Confirm `/api` proxy to `http://127.0.0.1:3000`
3. Confirm `/uploads` has `proxy_buffering off` and `proxy_max_temp_file_size 0`
4. Confirm `client_max_body_size 100m`
5. Reload nginx after changes

### IP allowlist blocks expected kiosk reads

1. Confirm source IP observed by server (`req.ip` / proxy setup)
2. Update `KIOSK_ALLOWED_IPS` in service environment
3. Restart service

### Auth login fails

1. Confirm `KIOSK_ADMIN_PASSWORD` value in service environment
2. Verify cookie/session behavior in browser
3. Check `/api/auth/me`
