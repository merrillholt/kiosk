# Production Independence TODO

Goal: make production on `192.168.1.80` run and recover correctly even if the development machine is deleted, rebuilt, or unavailable.

## Priority 1: Production Data Durability

- Maintenance mode needed: Yes, for correcting persistent `overlayroot.conf` on current production hosts.
- Status on `192.168.1.80`: complete. `overlayroot.conf` corrected to `overlayroot="tmpfs:swap=1,recurse=0"`, `/data` mounts directly as ext4 in normal mode, the live server DB path is `/data/directory/directory.db`, and reboot persistence was validated.

## Priority 2: Production-Local Backup And Restore

- Maintenance mode needed: No.
- Status: complete. Scripts deployed to `192.168.1.80` and round-trip validated. Backups stored on `/data/backups/building-directory/`. Restore procedure via `scripts/restore-db.sh` confirmed working directly on production.

## Priority 3: Direct Standby Sync From Production

- Maintenance mode needed: No.
- Status: complete. `192.168.1.80` now performs direct standby reconciliation to `192.168.1.81` without the development machine in the middle.
- Sync scope: SQLite database plus uploaded assets under `server/uploads/` such as the configured background image.
- Trigger model: startup reconciliation, long-interval periodic recheck, and debounced async sync after admin-side DB mutations.
- Overlayroot behavior: standby writes go to the lower layer and the standby reboots afterward instead of attempting an in-place remount back to read-only.
- Validation: `.81` now matches `.80` for company count and serves the synced background image from its local server.

## Priority 4: Rebuild-Safe Development Reattachment

- Maintenance mode needed: No.
- Status: complete. Preflight checks were added to `tools/sync-primary-db.sh`, the rebuild sequence is documented in `docs/dev-reattachment.md`, the GitHub clone/pull workflow is documented in `docs/04-development-environment.md`, and a clean-clone validation from GitHub was completed successfully.

## Priority 5: Deployment And Recovery Decoupling

- Maintenance mode needed: Generally no, except where persistent host-level config must be changed on a kiosk.
- Status: complete. `scripts/production-ops.sh` deployed and all commands validated on `192.168.1.80`: `status`, `restart-server`, `restart-kiosk`, `backup`, `restore`.

## Priority 6: Documentation Updates

- Maintenance mode needed: No.
- Status: complete. All three docs updated to reflect current production state. Dev rebuild procedure documented in `docs/dev-reattachment.md`.

## Validation Checklist

- Production server continues serving kiosk/admin traffic with the development machine offline.
- Production admin edits survive reboot.
- Production backups can be created and restored without the development machine.
- Standby database sync works without the development machine.
- A fresh development machine can clone the repo, deploy locally, and sync from production safely.

## Current Fleet Status

- `192.168.1.80`: primary server and kiosk, healthy on the current tree.
- `192.168.1.81`: standby server and kiosk, healthy on the current tree. Fresh-host Chromium startup required seeding the per-user Chromium crash-report and NSS state in the kiosk home.
- `192.168.1.82`: client-only kiosk, healthy on the current tree and now on final hardware. It retains the `.82`-specific Elo touch calibration override required for that host's display path.
