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

## Local Deploy

Syncs the repo source tree into the local runtime at `/home/security/building-directory`:

- `tools/deploy-local.sh` — server-only manifest (default)
- `tools/deploy-local.sh --full` — full manifest (server + kiosk + scripts)
- `tools/deploy-local.sh --dry-run` — preview actions
- `make deploy-local` and `make deploy-local-full` as shortcuts

Important:
- `tools/deploy-local.sh` does not restart `directory-server`.
- It prints the manual restart step: `sudo systemctl restart directory-server`
- Use `--full` before testing kiosk-script or kiosk-session behavior from the local admin UI.

## Remote Deploy (SSH to Production)

Deploys from this machine to a production host over SSH. **Requires a clean git working tree** before deploying to protected IPs (`192.168.1.80`, `.81`, `.82`).

- `tools/deploy-ssh.sh` — server-only manifest to `kiosk@192.168.1.80` (default)
- `tools/deploy-ssh.sh --server` — explicit server-only deploy
- `tools/deploy-ssh.sh --client` — client/kiosk runtime deploy only
- `tools/deploy-ssh.sh --full` — full manifest (server + kiosk + scripts)
- `tools/deploy-ssh.sh --dry-run` — preview sync actions only
- `tools/deploy-ssh.sh --host <user@ip>` — target a specific host
- `tools/deploy-ssh.sh --no-restart` — skip service restart/health checks
- `tools/deploy-ssh.sh --with-db --db-source <path>` — also deploy a SQLite DB file
- `make deploy-ssh` and `make deploy-ssh-full` as shortcuts

Notes:

- Script uses manifest-driven `rsync` over SSH.
- `rsync` must be installed on both local and remote hosts.
- If remote host is currently in maintenance/writable mode, install prerequisite with:
  - `sudo apt-get update && sudo apt-get install -y rsync`
- **Overlay mode** (normal production): writes files directly to the persistent lower
  layer under `/media/root-ro` and reboots the host afterward to restore a clean
  overlayroot state.
- **Maintenance/writable mode**: syncs directly and runs `npm ci --omit=dev` in `server/`.
- In overlay mode, dependency install is skipped by default (`OVERLAY_INSTALL_DEPS=0`).
- Deploy scripts install/update `/usr/local/bin/persist-upload.sh` on target host.
- Script attempts non-interactive `sudo systemctl restart directory-server`.
- Client/full deploy patches primary/standby URLs into `scripts/start-kiosk-lib.sh`.
- Overlay deploys reboot the host; non-overlay client deploys restart the kiosk session.
- Remote host must have `directory-server` service installed and enabled.
- Remote host must have nginx installed and configured (port 80).
- If remote sudo requires a password, restart must be done manually on the remote host.
- Database is not copied by default; use `--with-db --db-source <path>` when promoting data.
- Client deploy also enforces client-only host cleanup:
  - removes any `directory-backup` units from the host
  - installs `scripts/kiosk-blacklist-wireless.conf`
  - masks `pulseaudio.service` and `pulseaudio.socket` in `/etc/systemd/user`

Current default kiosk browser URLs:
- primary: `http://192.168.1.80`
- standby: `http://192.168.1.81`

## Admin-Related Deployment Notes

- If kiosk UI image assets are changed (e.g. building info logo), use full deploy:
  - `tools/deploy-ssh.sh --full --host <user@ip>`
- Server-only deploy updates admin/API logic, including:
  - auth/session behavior
  - backup/restore endpoints
  - background upload handling
- The admin Deploy tab uses `tools/deploy-ssh.sh --client` for kiosk runtime deployment; it is
  not the same as a full application deploy from `tools/deploy-ssh.sh --full`.

## Fleet Script Convenience Wrapper

- `scripts/kioskctl` is a thin wrapper that executes `kiosk-fleet/kioskctl`.
- This lets operators run fleet commands from the `scripts/` path while keeping fleet
  tooling source under `kiosk-fleet/`.
