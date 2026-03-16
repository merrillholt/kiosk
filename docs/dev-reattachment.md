# Development Reattachment

Goal: rebuild a development machine from a fresh clone and reattach it to the authoritative production state on `192.168.1.80` without modifying production.

## Preconditions

- The repo has been cloned or pulled to `/home/security/Public-Kiosk`.
- `192.168.1.80` is reachable over SSH.
- The production server on `192.168.1.80` remains the source of truth for runtime data.

## Rebuild Sequence

1. Deploy the local runtime tree
   - Run `./tools/deploy-local.sh --full`
   - This recreates `/home/security/building-directory` from the current repo.

2. Install the persist helper if `deploy-local.sh` could not do it automatically
   - Run `sudo install -m 755 /home/security/building-directory/server/persist-upload.sh /usr/local/bin/persist-upload.sh`

3. Restart the local service
   - Run `sudo systemctl restart directory-server`

4. Verify the local service is healthy
   - Check `/api/auth/me`
   - Check `/api/data-version`

5. Pull the authoritative database from production
   - Run `./tools/sync-primary-db.sh --skip-standby`
   - This restores the production database from `192.168.1.80` into the local development runtime DB.

6. Verify the local data matches production expectations
   - Spot-check known records
   - Verify `data_version`

## Notes

- This flow is intentionally one-way: production to development.
- It should not alter production state.
- If `/home/security/building-directory` or its DB file is missing, `tools/sync-primary-db.sh` now fails with a clear preflight error instructing you to run `./tools/deploy-local.sh --full` first.
