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
