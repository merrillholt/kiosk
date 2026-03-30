# Building Directory Install Package

This package installs the current Debian 13 kiosk/server system.

## Start Here

1. Extract the package.
2. Open a terminal in `building-directory-install/`.
3. Run:

```bash
chmod +x install.sh
./install.sh
```

The installer supports:
- `1) Server`
- `2) Client`
- `3) Both`

## Primary Documentation

The packaged PDFs in `docs/` are the authoritative packaged docs:
- `building-directory-admin-guide.pdf`
- `building-directory-development-guide.pdf`

The most important individual references are:
- `docs/10-new-host-installation.pdf`
- `docs/08-packaging-and-deploy.pdf`
- `docs/09-server-operations.pdf`
- `docs/07-touchscreen-setup.pdf`

## Current Platform Assumptions

- Debian 13
- overlayroot-enabled kiosk/server hosts
- deploy/update workflow based on `tools/deploy-ssh.sh`

## After Installation

- Server/admin traffic is served by nginx on port 80.
- The Node server runs as `directory-server` on `127.0.0.1:3000`.
- Kiosk clients use the installed `start-kiosk.sh` / `kiosk-guard` flow.

Useful checks:

```bash
sudo systemctl status directory-server --no-pager
sudo systemctl status nginx --no-pager
sudo systemctl status kiosk-guard --no-pager
```

For full install and operational detail, use the PDFs in `docs/` rather than
legacy text files or archived helper scripts.
