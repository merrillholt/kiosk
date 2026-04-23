# Standby 192.168.1.81 Status

Goal: capture the deployed standby system's validation history, operating policy,
and remaining reference notes for `192.168.1.81`.

Note: repo code now includes conservative automatic failback logic in
`start-kiosk.sh`, and the initial end-to-end failover/failback validation has
been completed with `.80`, `.81`, and `.82` all live.

## Standby Validation And Policy

1. Direct database sync from production to standby
   - Maintenance mode needed: No.
   - Status: complete.
   - `192.168.1.80` pushes a consistent SQLite backup directly to `192.168.1.81`.
   - The pushed backup is restored into the standby database on `192.168.1.81`.
   - Sync works with the development machine offline.
   - The workflow is automated steady-state behavior, not a manual operator task.

2. Replicate production backup retention to standby
   - Maintenance mode needed: No.
   - Status: not required.
   - `192.168.1.81` keeps the live standby DB only.
   - Replicated backup retention on standby is intentionally not part of the operating model.

3. Standby restore drill
   - Maintenance mode needed: No.
   - Status: complete.
   - A production-generated backup restores successfully on `192.168.1.81`.
   - `directory-server` on `192.168.1.81` starts cleanly after restore.

4. Failover validation
   - Maintenance mode needed: No.
   - [x] Confirm `.80`, `.81`, and `.82` are healthy before starting.
   - [x] Confirm `.81` matches `.80` for company count and `data_version`.
   - [x] Confirm `.81` serves a known uploaded asset such as the configured background image.
   - [x] Shut down `.80` and record the outage start time.
   - [x] Confirm the kiosks on `.81` and `.82` switch to the standby server on `.81` within the current expected failover window.
   - [x] Confirm the clients are actually using `.81`, not only showing cached content.
   - [x] Confirm current data and at least one uploaded asset render correctly while on standby.
   - [x] Restore `.80` and record when it becomes reachable again.
   - [x] Confirm `.81` and `.82` promote back to primary `.80` within the current expected failback window.
   - [x] Record actual failover/failback timings and any incorrect or delayed behavior.
   - Validation summary:
     `.81` failed over in about 37 seconds, `.82` in about 39 seconds, `.82` returned to primary in about 35 seconds after `.80` recovered, and `.81` returned in about 49 seconds. Current data and uploaded assets were confirmed during failover.

5. Power-feed failure scenarios
   - Maintenance mode needed: No.
   - [x] Validate behavior when `192.168.1.80` and `192.168.1.82` are down but `192.168.1.81` remains active.
   - [x] Validate behavior when only `192.168.1.80` is down and kiosks must switch to `192.168.1.81`.
   - [x] Validate automatic failback behavior when `192.168.1.80` returns after an outage.
   - [x] Confirm the long fixed failback intervals are acceptable in practice or adjust them upward if needed.

6. Standby RPO/RTO policy
   - Maintenance mode needed: No.
   - [x] RPO: event-driven sync (on startup + after each admin mutation) is acceptable. No maximum staleness interval required.
   - [x] RTO: ~37-39 second failover window is acceptable.
   - [x] Sync model: event-driven is sufficient; no scheduled periodic sync required.

7. Standby operational policy
   - Maintenance mode needed: No.
   - [x] No manual sync required during normal operation.
   - [x] Sync is event-driven (startup + post-mutation); no scheduled sync needed.
   - [x] Backup retention on standby is not required — manual DB download via admin UI covers the extended-outage scenario.

## Current State

- `192.168.1.81` is installed and reachable over SSH.
- `directory-server` is deployed and healthy on `192.168.1.81`.
- Persistent database storage on `192.168.1.81` is verified.
