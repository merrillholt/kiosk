# Client Test Suite

This suite covers the `.82` client-only kiosk path separately from the server
integration tests.

## Available Tests

### 1. Client unit tests

Fast local tests for kiosk startup selection and recovery decision logic:

```bash
tools/client-unit-test.sh
```

Covers:

- primary reachable -> launch primary
- primary down, standby reachable -> launch standby
- both down -> launch offline page
- offline -> recover to primary
- offline -> recover to standby
- standby -> promote back to primary
- primary -> fail away after threshold
- standby -> re-evaluate when standby fails
- config-driven timing math

### 2. Client integration tests

SSH-based checks against a real client kiosk host:

```bash
tools/client-test.sh --host kiosk@192.168.1.82
```

Covers:

- deployed startup script present
- offline page present
- expected primary/standby URL patching
- overlayroot active
- `getty@tty1`, `kiosk-guard`, and `cage` healthy
- Chromium command present
- startup log includes a launch decision

### 3. Fleet health checks

Operational host health checks:

```bash
kiosk-fleet/kioskctl status
```

This remains useful for release readiness and unexpected failed units.

## Manual Acceptance Tests

### Normal boot

1. Reboot `.82`.
2. Confirm the display loads the live directory from `.80`.

### Primary outage with no standby

1. Make `.80` unreachable from `.82`.
2. Confirm the kiosk shows the local unavailable page.

### Recovery to primary

1. Restore `.80`.
2. Wait for the recovery watcher to detect it.
3. Confirm `.82` returns to the live directory automatically.

### Standby path

After `.81` is deployed:

1. Make `.80` unreachable.
2. Confirm `.82` switches to `.81`.
3. Restore `.80`.
4. Confirm `.82` promotes back to primary automatically.

### Touchscreen

1. Plug in a USB keyboard and exit the kiosk session.
2. Run `sudo evtest`.
3. Confirm the Elo device reports touch coordinates.
4. Unplug the keyboard and confirm the kiosk session restarts.
