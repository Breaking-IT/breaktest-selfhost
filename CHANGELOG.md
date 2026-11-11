# Self-host release notes

Historical releases before this release history was introduced may not have notes.

## 26.11.2 — 2026-11-11

### Test execution and reliability
- Replace the Python backend and load-generator control agent with native Rust services, retaining the existing controller protocol and Compose service names.
- Keep generator workloads running through controller reconnects, replay completion evidence after reconnect/restart, and keep explicit kill commands responsive during slow stops. Improve container-monitor recovery and Chromium startup when inherited home directories are not writable.
- Recover interrupted starts, scheduled firings and result trims. Avoid duplicate finalization when a stop request races with generator completion, stop k6 browser runs gracefully, and include the first partial second when finalizing TimescaleDB results, including subsecond tests.

### Results and charts
- Show pause/resume annotations at the latest measured Vuser count at or before each event. Preserve resume pins during live updates and wait for historical samples when needed. Render manual annotations once instead of overlapping duplicate pins.
- Load comparison sections independently and prevent stale requests from replacing newer selections. Preserve the requested resolution for generator charts.
- Add trimming and browser error screenshots for native BreakTest DB results, with restart cleanup for interrupted storage operations.

### Self-host results migration
- Ship `./migrate_customer.sh plan|copy|switch` in the public bundle to copy eligible finalized BreakTest/JMeter tests from TimescaleDB into BreakTest DB. The Docker helper uses the running deployment configuration; host Python and a private source checkout are not required.
- Preserve retained aggregates, finalized summaries and percentiles even when raw data has expired. Show confirmed detail-data gaps in test summaries; deleted samples are not reconstructed. Copying preserves the original TimescaleDB data and routing, and existing verified bundles are not overwritten.
- Support `BREAKTEST_DB_DATA_PATH` for an existing absolute host directory, consistently across storage, backend, backup, restore and migration. Leaving it blank retains the named-volume default.

### Upgrade and compatibility notes
- Back up before upgrading and use the complete updated self-host bundle. Installations older than v26.10.3 must upgrade through v26.11.1 first; installations from v26.10.3 onward can upgrade directly. The backend now applies schema migrations at startup.
- The backend image remains `breaktest-backend`, now with a Rust runtime. Upgrade remote generator images to receive the new agent and k6 writer. Preserve existing data volumes and the generator `/files` mount used for completion recovery.
- Run one active backend controller per installation. Additional replicas wait for the controller lease rather than serving traffic. PDF export fonts, spacing and pagination can differ. Cloud cleanup now requires a verifiable matching provider account for an allocation.
- Migration requires the updated backend, frontend and BreakTest DB images. It does not support running/unfinalized tests, k6/browser tests, or legacy tests without run-scoped generator monitoring. Pause retention/deletion for selected tests and budget disk for exports, staging and copied results.
- Imported retained-history bundles use format v3. Existing v1/v2 bundles remain readable, but older readers cannot read v3: switch historical reads back to TimescaleDB before rolling back. Raw clearing, trimming and offline optimize-copy are currently unavailable for imported v3 bundles.
- Changing `BREAKTEST_DB_DATA_PATH` does not move data automatically: copy and verify existing results, preserve ownership, and recreate both backend and storage with the new setting. Keep the original data for rollback.

## 26.11.1 — 2026-11-06

### BreakTest DB and live charts
- BreakTest DB encodes checkpoints in the background so ingestion and live queries can continue while results are written. Live charts use pre-aggregated error counts and JVM metrics and fetch virtual-user totals directly.
- Opening or reconnecting to a live dashboard now loads history alongside current data. New live updates and late corrections take precedence over older snapshots. Long tests can use two-minute and five-minute chart intervals.

### Scenarios and load generators
- Uploading a BreakTest plan now guides you through updating file references, importing profiles, and importing scenarios. You can add missing profile variables while preserving edited values, and imported scenarios use the profile copies you select.
- Edit workload settings, iteration behavior, and k6 options in the scenario editor. The console preserves selections for generators whose names contain spaces or commas.
- Manual generator setup now defaults to process mode and offers container mode. Bulk removal lets you remove failed generator records separately from their cloud resources.

### Upgrade notes
- BreakTest DB now defaults to one ingestion lane per generator, down from three, to reduce watermark traffic across large fleets. Remove an explicit `BREAKTEST_DB_LANES` setting to use the new default, or keep an override of 1–4 lanes.

## 26.11.0 — 2026-11-04

### BreakTest DB
- Add an optional results database alongside TimescaleDB for BreakTest/JMeter-fork, k6 and k6 browser performance tests. Select the results backend per customer; running tests keep the backend they started with.
- Store compressed results, one-second aggregates, percentiles and generator hardware statistics in portable per-test directories. Completed bundles can be copied and queried without a SQL import.
- Support live graphs, test summaries, request/transaction analysis, comparisons, trends, reports and SLO evaluation. Incomplete or unconfirmed ingestion is reported explicitly instead of assuming a complete successful test.
- Include BreakTest DB results in full and customer backups and restore. Add copy-only migration of completed TimescaleDB tests, preserving the original data and allowing verified copies to follow the customer's backend preference.
- Apply raw-request and error retention to completed native BreakTest DB tests, respecting exclusions. Clear selected data without recompressing retained streams; refuse clears when there is insufficient disk space for the staged copy.

### Live tests and generators
- Improve ingestion and live-query concurrency for large remote-generator fleets, reduce telemetry overhead, and remove fixed per-test source/cardinality limits while retaining memory, disk and network safeguards.
- Keep live chart updates independent of late historical data. Stop chart polling during sealing while continuing to show finalization progress.
- Improve generator shutdown, queued-result draining and finish acknowledgments; fix a BreakTest class-loader stall and writer teardown deadlock.
- Provision test-only generator groups in parallel with shared-resource coordination. Improve Fargate role repair/retry and security-group setup, and use the customer's Azure subscription for VM identity.

### Charts and diagnostics
- Fix synthetic-monitoring chart hover freezes and stale response updates. Show the slowest 50 series initially while keeping all series selectable.
- Fix empty BreakTest DB raw-mode request, location and generator-error graphs. Preserve exact raw response-time points and subsecond rate detail.
- Treat unavailable TCP connect measurements as unavailable rather than negative times, and exclude them from averages.
- Log individual database-maintenance findings and required actions at startup.

### Upgrade notes
- TimescaleDB remains the default; enabling BreakTest DB does not migrate existing customer data. Set `BREAKTEST_DB_ENABLED=true` to enable it (default `false`). Startup generates and persists the admin token; three ingestion lanes per generator are the default.
- Upgrades translate the former `BREAKTEST_DB_APPLICATION_PREVIEW` flag automatically. Preserve the generated admin token and the `breaktest_results` volume. Older experimental `CUSTOM_STORAGE_*` configurations and volumes require a separate manual migration.
- Upgrade remote load-generator images before using BreakTest DB; generators must advertise the matching writer capability. Existing cloud machine images are not rebuilt by this release.
- Synthetic monitoring and external Grafana SQL dashboards continue to use TimescaleDB. BreakTest DB does not support k6 browser screenshot storage.
- BreakTest DB uses checkpoint-based relaxed durability: a crash can lose data received after the last checkpoint. Coverage reporting identifies unconfirmed data.
- Clearing retained streams temporarily needs space for the remaining compressed data plus 1 GiB. Back up before upgrading and keep adequate disk space.

## 26.10.3 — 2026-10-26

### Database storage
- Compress historical request aggregates, synthetic monitoring aggregates, and shared monitoring data for both new and existing installations. Recent data stays writable: request aggregates use a two-hour compression window, synthetic aggregates 30 days, and shared monitoring seven days.
- Reclaim leftover empty storage from compressed chunks in background database maintenance. Cleanup preserves live data and skips busy chunks; disk usage may decrease gradually after startup.

### Profiles
- Clone a profile, including its variables, file references, and imported JMeter elements, into an editable copy.
- Offer embedded profile and scenario imports when uploading a new version of a file already used by existing scenarios or profiles.

### Deployment and recovery
- Preserve stopped containers so MongoDB recovery can reuse the previous server version, and verify that startup actually runs the requested MongoDB image.
- Improve recovery after containers have been removed. Legacy volumes without a saved version can be recovered using the documented MONGODB_RECOVERY_VERSION setting with their known previous server version.
- Improve active-test detection during upgrades and graceful service shutdown.
- Update the load generator to 2026.10.26.

### Upgrading
Back up the installation and finish active tests before running the updated self-host upgrade script. Database compression configuration is applied automatically at backend startup; historical compression and storage cleanup can take additional time and disk I/O. Existing custom compression policies are preserved. Use the updated self-host scripts for the MongoDB recovery improvements.

## 26.10.2 — 2026-10-22

### Metrics ingestion and load generators

- Replace the Go PostgreSQL proxy with a Rust implementation that reduces CPU use in ingestion benchmarks and keeps multipart metric batches atomic, including when requests are canceled or connections fail.
- Enable zstd compression by default for JMeter and k6 metrics, with gzip fallback. JMeter retains compressed queued batches and compact metadata to reduce memory use while waiting for uploads.
- Update the load-generator engine to **2026.10.21** and the JMeter TimescaleDB listener to **1.1.5**.

### Scenarios and storage reporting

- Reject missing or disabled workload references before saving a scenario and show actionable validation errors. Preserve synthetic-monitoring intervals and think-time settings when editing other fields.
- Include continuous aggregates, ordinary tables, indexes and database overhead in storage reporting for a more complete view of disk usage.

### Upgrading

- Finish active tests and run **./full_backup.sh** before upgrading. Update the backend, proxy and load generators together during a maintenance window.
- Updated self-host launchers target **MongoDB 9.0.4** and stage supported standalone installations through MongoDB 8.3.9 and feature compatibility version (FCV) 8.3 when needed. Migration 17 also prepares FCV 8.3. Existing upgraded databases remain at FCV 8.3; enabling FCV 9 is a separate, explicit step after validation. Explicit MongoDB version pins are respected.
- For an older self-host bundle, after taking a backup, use `git pull --ff-only && ./upgrade.sh --no-bundle-update` so the updated launcher performs the upgrade. Use the launchers rather than direct Docker Compose commands. Replica sets and sharded deployments require a separately planned upgrade. See the [MongoDB upgrade and recovery instructions](https://github.com/Breaking-IT/breaktest-selfhost/blob/main/README.md) before upgrading; changing an image tag alone is not a safe database rollback.
- Custom clients sending zstd metric batches must use a window of at most **256 KiB**, or use gzip. The bundled JMeter and k6 clients already meet this limit.

## 26.10.1 — 2026-10-16

### Runtime updates

- Update the BreakTest engine in load generators from **2026.10.06** to **2026.10.16**.
- Update the self-host bundle to **Grafana 13.2.4** and **Traefik 3.7.15**.
- Reduce backend and load-generator container layer overhead while retaining non-root execution and writable test and cache directories.

### Upgrading

- Finish active tests and run **./full_backup.sh** before **./upgrade.sh**. Update load generators to use the new BreakTest engine.
- No new database migrations or configuration changes are required by this release.

## 26.10.0 — 2026-10-13

### Scheduled tests

- Schedule scenarios once or daily, weekly and monthly in a selected time zone. Preview upcoming runs, run a schedule immediately, and inspect its history from Setup → Schedules or create a schedule from the Console.
- Configure overlap and busy-generator policies and send start, finish, failure and SLO notifications through existing notification channels. Completion emails include run metrics, SLO results and transaction summaries.
- Scheduled starts recheck the owner's access and license. Runs beyond the lateness allowance are recorded as missed instead of starting a backlog after an outage. The default allowance is 15 minutes.

### BreakTest scenarios and reusable profiles

- Import scenarios and profiles from sectioned BreakTest plans. Re-uploading a plan identifies unchanged items and offers overwrite or copy for changed items.
- Compose scenarios from ordered workload rows, including repeated use of a script with different load settings and profiles. Generated plans use the platform's scenarios and selected profiles while retaining the plan's Shared Profile.
- Create project profiles containing variables, CSV files with split/shuffle settings, and supporting files for BreakTest, JMeter and k6 scenarios. A scenario's own variables and files take precedence. The project default is preselected only for new scenarios; existing scenarios without a profile retain their behavior.
- Preserve profile references during file updates, scenario copies and customer backup/restore, and show the profile used in the Console and test summary.

### Customer licensing and administration

- SuperAdmins can choose the installation license or a customer's own breaktest.io license for customer users, and set customer limits for virtual users, generators, daily test starts and synthetic-monitoring runs. Customer Admins can manage their customer's license when required.
- Grant test-day budgets with optional UTC availability dates. The first accepted load test opens a 24-hour window; later starts in that window do not consume another day. Synthetic monitoring has a separate allowance. Existing customers default to the installation license, with no new provider caps until configured.
- Keep login, existing-customer access, results and test preparation available when licensing is restricted. Starting tests and monitors still requires authorization; without service-provider entitlement, only the default customer can run tests. Interactive SuperAdmin starts use installation limits and bypass customer budgets.
- Improve customer settings and usage displays. Prevent repeated customer/external-database form submissions, trim new customer names and display creation failures.

### Load generators and ingestion

- Select cloud regions on a world map with provider markers, a dropdown fallback and improved touch scrolling. Guide users through region and compute selection in generator setup.
- Update load generators to BreakTest 2026.10.06 and Java 27. Image builds download custom k6 release `breakingit-20261013T131608Z` for Linux amd64 or arm64; local k6 binaries are no longer required to build images.
- Reduce PostgreSQL ingestion overhead with an optimized gzip decoder and larger COPY chunks. Strip debugging information from the pg-proxy container binary.

### Platform diagnostics

- Add an operator-only Grafana dashboard for backend traces, API latency, database operations and test-start diagnostics in deployments with Tempo configured. Repository Compose deployments can enable it with `OPENTELEMETRY_ENABLED=true`; the self-host bundle does not include a Tempo service.

### Upgrade requirements and limitations

- Finish active tests and run **./full_backup.sh** before **./upgrade.sh**. Upgrade the backend and load generators together for sectioned plans and profiles; sectioned plans require BreakTest 2026.09.30 or newer.
- The bundle updates TimescaleDB from **2.30.1 to 2.30.2**, remaining on **PostgreSQL 18**, and Grafana to **13.2.3**. Startup migrations update shared/template and internal customer TimescaleDB extensions. Back up databases before allowing these migrations to run.
- Custom image builds need access to **https://www.breakingit.nl/files/** for runtime downloads, including k6. Pulling published images does not require downloading these binaries separately.
- Sequential workloads execute independently on each generator, without a cross-generator barrier. Expression-based thread counts are not divided across generators, and virtual-user accounting sums workload rows even when they execute sequentially.
- For existing repository deployments with tracing enabled, restart Tempo and Grafana to load the updated tracing configuration. The dashboard is for platform operators and is not provisioned into customer organizations.

## 26.9.9 — 2026-09-27

### Synthetic monitoring

- Support BreakTest/JMeter scenario archives with their main plan and supporting files. Fix legacy ZIP-based JMX downloads that failed with UTF-8 decoding errors, and reject missing or invalid main files with clearer errors.
- Pick up updated file selections on the next dispatch and refresh generated plans after interval, duration, thread-group, DNS override or custom-variable changes. Restore missing dependencies and remove obsolete cached files when switching selections.
- Apply synthetic-monitoring duration limits, metrics listeners and DNS overrides to archived plans.

### Backup and restore

- Back up up to **100 selected tests** in one ZIP and restore them into the selected project. Existing single-test archives remain supported. Progress now reports exported data volume and separate archive/download progress.
- Validate restore archive paths, test folders and metric tables before extraction, and stream metrics directly into PostgreSQL without executing archive-supplied paths. Restrict job status, results and downloads to the initiating editor/admin and customer.
- Report metric export, import and finalization failures instead of silently reporting success. Failed metric imports roll back per test; if a multi-test restore stops, its status identifies completed tests and the failed test number. Earlier completed tests remain restored.
- Preserve the original test when its ID already exists in another customer or project by creating a new test ID and remapping imported metrics. Repeated restores replace aggregate rows instead of duplicating them.
- Stream restore uploads to disk. Restores accept at most **100 tests**, **1,200 ZIP entries**, and **10 GiB** each for the uploaded archive and its expanded ZIP entries. Archives still need to match the target metrics schema.

### Cloud generator setup and self-hosting

- Simplify provider selection and use compact themed dropdowns with aligned CPU, memory and price columns. Sort by clicking price headers, show spot discounts including Azure, and retain selected unit prices and the total hourly estimate for all generators.
- Reduce steady-state MongoDB health checks from every **10 seconds to 60 seconds**, while checking every **5 seconds during startup** and using **3 failure retries**. This reduces mongosh launches by roughly 83%; unhealthy detection takes longer.

### Upgrade requirements

- Finish active tests and run **./full_backup.sh** before **./upgrade.sh**. Upgrade the backend and load-generator containers together to receive archive support and settings-based cache refresh; recreate containers to apply the health-check changes.
- This release adds no database schema migrations. Metrics imports are transactional per test, but metadata updates and subsequent finalization are not one distributed transaction. Inspect failed restore status before retrying a partially completed archive.
- Synthetic-monitoring intervals still do not start overlapping runs on the same generator. A run that lasts longer than its interval can delay the next execution.

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
