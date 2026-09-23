# Self-host release notes

Historical releases before this release history was introduced may not have notes.

## 26.9.7 — 2026-09-23

### Load-generator updates

- Update the bundled k6 fork to the build based on k6 2.3.0 and the BreakTest runtime to 2026.09.23.
- Retain Chromium 149 for browser tests after repeated ARM64 benchmarks showed substantially higher memory and CPU use with Chromium 152.

### Metrics ingestion improvements

- Reuse gzip decompression buffers after successful ingestion requests to reduce allocation overhead.
- Keep tenant database connections warm between traffic bursts and expire idle tenant pools independently. Active requests and requests waiting for a connection keep their pool available; health checks no longer keep idle pools alive.

### Configuration and upgrade

- Add **PG_PROXY_POOL_IDLE_SEC**, defaulting to **300 seconds**, to control tenant pool retention. Longer retention keeps connections warm but retains idle database connections longer. Existing connection limits are unchanged.
- Finish active tests and run **./full_backup.sh** before **./upgrade.sh**. This release introduces no database schema migrations.

## 26.9.6 — 2026-09-21

### Dashboard improvements

- Reduce repeated chart rendering and legend calculations by merging incoming data and statistics incrementally. Offscreen charts and hidden tabs pause rendering, then catch up without replaying old animations.
- Keep live line charts moving smoothly up to 50,000 points per panel. Automatic resolution changes from 1 second to 2 seconds after ten minutes, while respecting manual selection protection.
- Create custom panels directly from the live-test and test-summary toolbars using the compact **+ Panel** button.

### Accuracy and reliability fixes

- Preserve missing response-time measurements as missing in comparison charts, tables, copied statistics and exported reports. Averages exclude missing samples while retaining genuine zero measurements, including at coarser chart resolutions.
- Isolate WebSocket sends per load generator so a slow connection does not block healthy peers. Allow large independent testware transfers, apply a 30-second delivery timeout, and keep generator health checks from exhausting dashboard database workers.
- Keep realtime database reads off the event loop and prevent delayed refreshes from overwriting newer dashboard metadata.
- Stagger supported JMeter open-model even-arrival schedules across load generators to reduce synchronized starts.
- Show script/data preparation completion separately from generator readiness, and report test-only generator cleanup while result finalization and cleanup run concurrently.

### Release and upgrade experience

- SuperAdmins receive daily notifications when a newer stable release is available, including available changes since the installed version and upgrade instructions. Updates are not installed automatically. Set **BREAKTEST_RELEASE_CHECK_ENABLED=false** to disable the check.
- Publish version-specific changelogs with each new bundle. Release history starts with this release; notes for older releases are not reconstructed.
- Warn before an upgrade interrupts active load generators or unfinished tests started within the last two hours. Older unfinished records alone no longer trigger warnings. Uncertain active generator reports still require confirmation.
- Accept **y**, **Y** and **yes** (case-insensitive) for upgrade confirmation. Unattended upgrades must explicitly set **BT_UPGRADE_ASSUME_YES=1** to accept interruption when warned; otherwise an unanswered warning cancels the upgrade.

### Upgrade requirements

- Schedule a maintenance window, finish or deliberately stop active tests, and run **./full_backup.sh** before **./upgrade.sh**. Preserve configuration and a database backup for recovery.
- The bundled TimescaleDB image and internal database extension migrations advance to **2.30.1**. Allow startup migrations to complete and verify database/backend health after container recreation. Restoring an older application image alone does not reverse database extension upgrades.
- Integrations consuming comparison statistics or named response-time series must accept **null** for missing measurements. Count and rate defaults are unchanged.
- Frontend application and tooling dependencies are updated. Unchanged application images retain their existing version pins in the bundle.
