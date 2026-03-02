# Server Operations

This document covers the building-directory server lifecycle: install, deploy, auth, runtime verification, and troubleshooting.

## Scope

- Server host setup and operation
- API/auth behavior
- Local deploy workflow (dev machine == deployed machine)
- Service and nginx checks

Related docs:
- Client setup: `docs/Debian 13 Configuration.tex`
- Packaging/deploy pipeline: `docs/08-packaging-and-deploy.md`

## Runtime Architecture

- Node.js Express backend serves API on port `3000` bound to `127.0.0.1` (local only).
- Nginx serves `kiosk/` and `admin/`, proxies `/api` to `127.0.0.1:3000`.
- Nginx proxies `/uploads` to `127.0.0.1:3000` with buffering disabled for large image reliability in protected mode.
- SQLite DB: `server/directory.db`.
- Service name: `directory-server`.

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

## Security Model (Current)

- Kiosk read API routes are IP allowlisted via `KIOSK_ALLOWED_IPS`.
- Admin API access requires session auth:
  - `POST /api/auth/login`
  - `POST /api/auth/logout`
  - `GET /api/auth/me`
- Admin UI logout behavior:
  - Clicking `Logout` in `/admin` clears session and redirects to `/` (kiosk client page).
- Default password fallback: `kiosk` (override with `KIOSK_ADMIN_PASSWORD`).

Important:
- Set `KIOSK_ADMIN_PASSWORD` in production.
- Keep nginx and firewall restricted to trusted networks.

## Initial Server Install

Use installer entry point:
- `building-directory-install/install.sh`
- Choose mode: `1) Server` or `3) Both`

Installer performs:
- Copies `server/`, `scripts/`, `kiosk/` (and `kiosk-fleet/` when present)
- Installs Node.js dependencies
- Installs and enables `directory-server` service
- Configures nginx reverse proxy

## Day-2 Deploy (Local Machine)

When this machine is both development and deployed runtime:

- Server-only deploy (default):
  - `tools/deploy-local.sh`
  - `make deploy-local`
- Full deploy (server + kiosk + scripts):
  - `tools/deploy-local.sh --full`
  - `make deploy-local-full`
- Preview actions:
  - `tools/deploy-local.sh --dry-run`

Deploy behavior:
1. Syncs manifest-managed files to `/home/security/building-directory`
2. Runs `npm ci --omit=dev` in deployed server dir
3. Prints restart instruction (manual restart required):
   - `sudo systemctl restart directory-server`
   - or fallback start script if no systemd service
4. Runs health checks:
   - `/api/auth/me`
   - `/api/data-version`

## Day-2 Deploy (Remote Server over SSH)

When development and server deployment are on different machines:

- Server-only deploy:
  - `tools/deploy-ssh.sh`
  - `make deploy-ssh`
- Full deploy (server + kiosk + scripts):
  - `tools/deploy-ssh.sh --full`
  - `make deploy-ssh-full`
- Preview actions:
  - `tools/deploy-ssh.sh --dry-run`
- Target a different host:
  - `tools/deploy-ssh.sh --host kiosk@192.168.1.80`
- Include database promotion:
  - `tools/deploy-ssh.sh --host kiosk@192.168.1.80 --with-db --db-source /home/security/building-directory/server/directory.db`

Remote deploy behavior:
1. Syncs manifest-managed files over SSH to remote deploy root.
2. Runs remote `npm ci --omit=dev` (or `npm install --omit=dev`).
3. Attempts remote `sudo systemctl restart directory-server`.
4. Runs remote health checks:
   - `/api/auth/me`
   - `/api/data-version`

If non-interactive sudo is unavailable remotely, run:
```bash
sudo systemctl restart directory-server
```
on the target host after deploy.

Requirement:
- Target host should have `directory-server` systemd unit installed and enabled.
- DB note: `directory.db` is not copied unless `--with-db --db-source ...` is provided.

Prerequisite:
- `rsync` must exist on both local and target host.
- On a target in maintenance/writable mode, install with:
```bash
sudo apt-get update && sudo apt-get install -y rsync
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

Production nginx proxy requirements:
- Use `proxy_pass http://127.0.0.1:3000;` (avoid `localhost` to prevent IPv6 `::1` mismatches).
- In `location /uploads`, set:
  - `proxy_buffering off;`
  - `proxy_max_temp_file_size 0;`
This avoids writes to `/var/lib/nginx/proxy` in read-only overlay mode.

Check site config paths:
- Should reference `/home/security/building-directory/...`
- Not `/root/building-directory/...`

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
curl -i http://192.168.1.131/admin
```

## Environment Variables

Common server vars:
- `PORT` (default `3000`)
- `KIOSK_ADMIN_PASSWORD`
- `KIOSK_ALLOWED_IPS`
- `KIOSK_SERVER_URL`
- `KIOSK_CLIENTS`
- `KIOSK_SSH_KEY`
- `KIOSK_UPLOADS_LOWER` (optional override for uploaded background image directory)

## Admin Functions (Current Behavior)

### Background image upload/gallery

- Admin upload endpoint: `POST /api/background-image` (auth required).
- Gallery endpoint: `GET /api/background-images` (auth required).
- Upload persistence helper:
  - `/usr/local/bin/persist-upload.sh`
- Runtime upload directory selection:
  - Uses `KIOSK_UPLOADS_LOWER` if set.
  - Else uses overlay lower path when present.
  - Else falls back to local `server/uploads` (maintenance mode / overlay disabled).

### Backup/restore

- Recommended admin backup download:
  - `GET /api/backup.txt`
  - Returns SQL text dump as `directory-backup.txt`.
- Additional endpoint retained:
  - `GET /api/backup.sql` returns SQL dump as `.sql`.
- Restore endpoint:
  - `POST /api/restore`
  - Accepts `.txt`, `.sql`, `.sqlite`, `.db`.
- Restore semantics:
  - Replaces current database with uploaded content.
  - Returns DB row counts for `companies` and `individuals`.

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
ss -ltnp | rg ':3000\b'
```

### Admin URL fails but nginx is up

1. Validate nginx config path roots/aliases
2. Confirm `/api` proxy to `http://127.0.0.1:3000`
3. Confirm `/uploads` has `proxy_buffering off` and `proxy_max_temp_file_size 0`
4. Reload nginx after changes

### IP allowlist blocks expected kiosk reads

1. Confirm source IP observed by server (`req.ip` / proxy setup)
2. Update `KIOSK_ALLOWED_IPS`
3. Restart service

### Auth login fails

1. Confirm `KIOSK_ADMIN_PASSWORD` value in service environment
2. Verify cookie/session behavior in browser
3. Check `/api/auth/me`
