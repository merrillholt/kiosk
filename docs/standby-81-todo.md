# Standby 192.168.1.81 TODO

Goal: track work that only becomes actionable after `192.168.1.81` is deployed, reachable, and serving as the standby system.

## Standby-Dependent Items

1. Direct database sync from production to standby
   - Maintenance mode needed: No.
   - Make `192.168.1.80` push a consistent SQLite backup directly to `192.168.1.81`.
   - Restore the pushed backup into the standby database on `192.168.1.81`.
   - Verify the sync works with the development machine offline.
   - Design this as an automated steady-state workflow, not a manual operator task.

2. Replicate production backup retention to standby
   - Maintenance mode needed: No.
   - Decide whether `192.168.1.81` should keep only the live standby DB or also retain backup history copied from `192.168.1.80`.
   - If backup retention is desired, store replicated backups on persistent storage on `192.168.1.81`.
   - Define retention rules so standby backup storage does not grow without bound.

3. Standby restore drill
   - Maintenance mode needed: No.
   - Verify that a production-generated backup can be restored successfully on `192.168.1.81`.
   - Confirm `directory-server` on `192.168.1.81` starts cleanly after restore.

4. Failover validation
   - Maintenance mode needed: No.
   - Confirm kiosks can reach `http://192.168.1.81` when `192.168.1.80` is unavailable.
   - Verify kiosk behavior during primary failure and recovery.
   - Confirm the standby data matches the latest synced production state.

5. Power-feed failure scenarios
   - Maintenance mode needed: No.
   - Validate behavior when `192.168.1.80` and `192.168.1.82` are down but `192.168.1.81` remains active.
   - Validate behavior when only `192.168.1.80` is down and kiosks must switch to `192.168.1.81`.
   - Validate failback behavior when `192.168.1.80` returns after an outage.

6. Standby RPO/RTO policy
   - Maintenance mode needed: No.
   - Define how stale the standby database is allowed to be before failover is considered unacceptable.
   - Define how quickly kiosks should switch from `192.168.1.80` to `192.168.1.81`.
   - Prefer scheduled automated sync over manual sync.
   - Decide whether sync frequency must be scheduled, event-driven, or both.

7. Standby operational policy
   - Maintenance mode needed: No.
   - Keep system-level administration minimal after installation.
   - Do not require manual sync from `192.168.1.80` to `192.168.1.81` during normal operation.
   - Decide whether automated sync from `192.168.1.80` to `192.168.1.81` is scheduled, event-driven, or both.
   - Decide whether standby backups are promoted, rotated, or pruned independently of production.

## Activation Criteria

Start this list only after:
- `192.168.1.81` is installed and reachable over SSH.
- `directory-server` is deployed and healthy on `192.168.1.81`.
- Persistent database storage on `192.168.1.81` is verified.
