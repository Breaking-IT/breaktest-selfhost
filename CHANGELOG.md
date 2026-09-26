# Self-host release notes

Historical releases before this release history was introduced may not have notes.

## 26.9.8 — 2026-09-26

### Scenario editing and runtime updates

- Add a guided k6 scenario editor with executor selection, stages, validation and exported action-function selection. Raw options remain available for JavaScript expressions and unsupported configurations. Correct combined load-profile chart stacking and preserve script comments and strings when locating the options to replace.
- Update the bundled BreakTest engine to **2026.09.25**, refresh the Linux k6 binaries and include metrics listener **1.1.4**. Use native BreakTest transaction metadata to associate samplers with their immediate transaction while preserving sampler labels; Apache JMeter retains its legacy handling.
- Support random-arrival flags and fractional durations in open-model schedule editing and distribution. Use zero-rate phases for distributed startup offsets, and keep closed-model execution mode synchronized with the selected scenario profile.
- Enable error screenshots by default for newly created browser performance and synthetic-monitoring scenarios. Existing settings and explicit opt-outs are preserved.

### Reliability and live dashboards

- Validate uploaded test plans before creating runs or provisioning load generators, with actionable errors for unreadable files, invalid JMX and missing archive entrypoints. Correct scenario references when replacing plain JMX files with bundles or back again, preserving workload and CSV settings.
- Reset the console after failed starts so another attempt or another live run can be opened. Remove failed-run URLs, including failures on runs opened from a link.
- Fix gaps, oversized initial bars and stale totals in live error charts. Keep sparse bars moving smoothly, preserve animations when values are unchanged, and constrain brush selections to the visible time range.
- Refresh the notification badge on user activity at most hourly, and update it immediately after notification changes without allowing older requests to restore a stale count. The launch button responds to interaction without continuous idle animation.
- Show actionable guidance when AWS lacks capacity for the selected instance type or region.

### Database maintenance and self-hosting

- Preserve synthetic-monitoring aggregate refresh jobs across backend restarts and scenario updates. Add background checks for missing or stale aggregates, failed maintenance jobs, index issues and compression backlog.
- Restore eligible missing refresh and compression policies. Refresh skipped synthetic-monitoring history automatically only when its span is at most one day; larger gaps, missing schema definitions and index repairs require operator maintenance. Existing paused jobs are preserved.
- Add a SuperAdmin-only **GET /api/admin/database-health** endpoint for the latest maintenance reports. Checks run after startup by default; **DATABASE_HEALTH_ENABLED=false** disables reconciliation and **DATABASE_HEALTH_INTERVAL_SECONDS** enables periodic checks (default **0**, startup only).
- Enable compression for eligible frontend and API text responses in self-host deployments. Keep frontend routing available during backend restarts by defining each router's compression middleware on its own container.
- Fix self-host configuration helper compatibility with macOS Bash 3.2.

### Upgrade requirements

- Finish active tests and run **./full_backup.sh** before **./upgrade.sh**. Recreate the application and load-generator containers through the normal upgrade process to receive the runtime and routing changes.
- This release adds no database schema migrations. Background reconciliation can restore maintenance policies and refresh small historical gaps; inspect database-health reports after upgrading. Larger historical gaps are reported and are not automatically backfilled.

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
