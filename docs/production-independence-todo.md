# Production Independence TODO

Goal: make production on `192.168.1.80` run and recover correctly even if the development machine is deleted, rebuilt, or unavailable.

## Priority 1: Production Data Durability

- Maintenance mode needed: Yes, for correcting persistent `overlayroot.conf` on current production hosts.
- Status on `192.168.1.80`: completed. `overlayroot.conf` corrected to `overlayroot="tmpfs:swap=1,recurse=0"`, `/data` now mounts directly as ext4 in normal mode, and a reboot persistence test passed.
- Move the production SQLite database off the ephemeral overlay path or bind it to a persistent location.
- Verify that admin changes made on `192.168.1.80` survive reboot without any development-machine involvement.
- Document the authoritative production database path and backup location.
- Test a full power-cycle on `192.168.1.80` after admin edits and confirm data remains intact.

## Priority 2: Production-Local Backup And Restore

- Maintenance mode needed: No.
- Status: production-local backup and restore scripts added in the repo; still needs deployment to `192.168.1.80` and a round-trip validation there.
- Add a production-local backup workflow on `192.168.1.80` that does not require the development machine.
- Decide where production backups live on `192.168.1.80` or attached persistent storage.
- Add a documented restore procedure that can be executed directly on `192.168.1.80`.
- Verify backup/restore with a real round-trip test on production or a production-equivalent machine.

## Priority 3: Direct Standby Sync From Production

- Maintenance mode needed: No.
- Deferred until `192.168.1.81` is deployed and reachable. Standby-dependent work is tracked separately in `docs/standby-81-todo.md`.
- Remove the requirement that the development machine sit in the middle of production -> standby database replication.
- Add or adapt a tool so `192.168.1.80` can push a consistent SQLite backup directly to `192.168.1.81`.
- Confirm the standby sync process works when the development machine is offline.
- Decide whether standby sync is manual, scheduled, or both.

## Priority 4: Rebuild-Safe Development Reattachment

- Maintenance mode needed: No.
- Status: preflight checks added to `tools/sync-primary-db.sh`; rebuild sequence documented in `docs/dev-reattachment.md`. Still needs a full clean-machine validation.
- Define the exact rebuild procedure for a fresh development machine after `git pull` or fresh clone.
- Add preflight checks to any sync tool that currently assumes `/home/security/building-directory` already exists.
- Ensure the development machine can rehydrate from production state after rebuild without altering production.
- Test the full rebuild flow on a clean environment.

## Priority 5: Deployment And Recovery Decoupling

- Maintenance mode needed: Generally no, except where persistent host-level config must be changed on a kiosk.
- Status: production-side operations entrypoint added as `scripts/production-ops.sh`; still needs deployment to `192.168.1.80` and validation there.
- Review every operational workflow that currently assumes `/home/security/Public-Kiosk` on the development machine.
- Separate “production runtime operation” from “development build/deploy workstation” responsibilities.
- Ensure kiosk recovery steps on `192.168.1.80` do not depend on tools existing only on the development machine.
- Confirm production can continue operating normally if the development machine is powered off indefinitely.

## Priority 6: Documentation Updates

- Maintenance mode needed: No.
- Update `docs/03-read-only-filesystem.md` to match the real persistence model.
- Update `docs/08-packaging-and-deploy.md` for current deploy behavior and production/development separation.
- Update `docs/09-server-operations.md` with the correct production-first operating model.
- Add a dedicated “production continuity / dev rebuild” document.

## Validation Checklist

- Production server continues serving kiosk/admin traffic with the development machine offline.
- Production admin edits survive reboot.
- Production backups can be created and restored without the development machine.
- Standby database sync works without the development machine.
- A fresh development machine can clone the repo, deploy locally, and sync from production safely.
