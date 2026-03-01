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

- Node.js Express backend serves API on port `3000`.
- Nginx serves `kiosk/` and `admin/`, proxies `/api` to `localhost:3000`.
- SQLite DB: `server/directory.db`.
- Service name: `directory-server`.

## Security Model (Current)

- Kiosk read API routes are IP allowlisted via `KIOSK_ALLOWED_IPS`.
- Admin API access requires session auth:
  - `POST /api/auth/login`
  - `POST /api/auth/logout`
  - `GET /api/auth/me`
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
3. Restarts `directory-server` (or fallback start script if no service)
4. Runs health checks:
   - `/api/auth/me`
   - `/api/data-version`

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

## Troubleshooting

### Server not reachable on port 3000

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
2. Confirm `/api` proxy to `http://localhost:3000`
3. Reload nginx after changes

### IP allowlist blocks expected kiosk reads

1. Confirm source IP observed by server (`req.ip` / proxy setup)
2. Update `KIOSK_ALLOWED_IPS`
3. Restart service

### Auth login fails

1. Confirm `KIOSK_ADMIN_PASSWORD` value in service environment
2. Verify cookie/session behavior in browser
3. Check `/api/auth/me`
