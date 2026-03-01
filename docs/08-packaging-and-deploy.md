# Packaging And Deploy

## Goal

Keep one canonical source tree at the project root (`server/`, `kiosk/`, `scripts/`, `kiosk-fleet/`) and generate installer payloads from it.

## Files

- `manifest/install-files.txt`: canonical file list copied into installer payloads.
- `tools/check-install-drift.sh`: verifies `building-directory-install/` matches canonical files.
- `tools/package-install.sh`: builds `dist/install/building-directory-install/` and optional zip.

## Workflow

1. Edit files only in root source directories.
2. Run `tools/check-install-drift.sh` to see drift status.
3. Run `tools/package-install.sh` to generate installer output from canonical sources.
4. Validate install from `dist/install/building-directory-install/`.

## Notes

- `building-directory-install/` remains as template/base installer content.
- Canonical app files in the manifest overwrite matching files in the packaged output.
- `dist/` is generated output and should not be edited manually.

## Local Deploy (Dev == Server)

When this machine is both development and deployed runtime, use:

- `tools/deploy-local.sh` (default: server-only manifest) to sync server files into `/home/security/building-directory`, update server dependencies, restart the service/process, and run health checks.
- `tools/deploy-local.sh --full` to deploy full manifest (server + kiosk + scripts).
- `tools/deploy-local.sh --dry-run` to preview actions.
- `make deploy-local` and `make deploy-local-full` as shortcuts.

## Remote Deploy (SSH Push to Server Node)

For deploying from this development machine to a separate server host:

- `tools/deploy-ssh.sh` deploys server-only manifest files to remote `DEPLOY_ROOT` (default host: `kiosk@192.168.1.80`).
- `tools/deploy-ssh.sh --full` deploys the full manifest (server + kiosk + scripts).
- `tools/deploy-ssh.sh --dry-run` previews sync actions only.
- `tools/deploy-ssh.sh --host <user@ip>` targets a specific host.
- `tools/deploy-ssh.sh --no-restart` skips service restart/health checks.
- `tools/deploy-ssh.sh --with-db --db-source <path>` also deploys a SQLite DB file.
- `make deploy-ssh` and `make deploy-ssh-full` are shortcuts.

Notes:

- Script uses manifest-driven `rsync` over SSH.
- `rsync` must be installed on both local and remote hosts.
- If remote host is currently in maintenance/writable mode, install prerequisite with:
  - `sudo apt-get update && sudo apt-get install -y rsync`
- Script runs remote `npm ci --omit=dev` (or `npm install --omit=dev`) in `server/`.
- Deploy scripts install/update `/usr/local/bin/persist-upload.sh` on target host.
- Script attempts non-interactive `sudo systemctl restart directory-server`.
- Remote host should already have `directory-server` service installed/enabled.
- For standard URL access on port 80, remote host should have nginx installed/configured.
- If remote sudo requires a password, restart must be done manually on remote host.
- Database is not copied by default; use `--with-db --db-source <path>` when promoting data.

## Admin-Related Deployment Notes

- If kiosk UI image assets are changed (for example building info logo), use full deploy:
  - `tools/deploy-ssh.sh --full --host <user@ip>`
- Server-only deploy updates admin/API logic, including:
  - auth/session behavior
  - backup/restore endpoints
  - background upload handling

## Fleet Script Convenience Wrapper

- `scripts/kioskctl` is a thin wrapper that executes `kiosk-fleet/kioskctl`.
- This lets operators run fleet commands from the `scripts/` path while keeping fleet tooling source under `kiosk-fleet/`.
