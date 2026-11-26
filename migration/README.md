# Copy TimescaleDB results to BreakTest DB

From the self-host installation directory:

```sh
./migrate_customer.sh plan --customer CUSTOMER_ID
./migrate_customer.sh copy --customer CUSTOMER_ID --test TEST_ID
# Copy everything the customer has: tests with their generator monitoring, then Synthetic Monitoring.
./migrate_customer.sh copy --customer CUSTOMER_ID --all
# The same without converting shared generator monitoring; stops at the first test that fails.
./migrate_customer.sh copy --customer CUSTOMER_ID
# Copy all customers with a TimescaleDB configuration. Reuse after interruption.
./migrate_customer.sh copy --customer all
```

`--all` is the whole-customer copy with `--copy-legacy-monitoring` and
`--continue-on-error`: a test that cannot be copied is reported and the rest of the
customer, including Synthetic Monitoring, is still copied. The command exits
nonzero if any test failed. It works with `--customer all` and does not activate
Synthetic Monitoring; add `--activate` for that. Running, unfinalized and empty
tests are skipped as in any copy.

Every TimescaleDB test that is left out is listed with its reason, and the
summary line counts them. A test that is still running is only reported. A
finished test that can never be copied, for example one without a stored
summary, makes `--all` exit nonzero.

Use `./migrate_customer.sh update-sm --customer CUSTOMER_ID` for a monitoring-only catch-up.
The customer ID is in the customer edit URL. `--test` is repeatable. `plan` checks
metadata only; `copy` validates source schema, retained rows and completeness.

The wrapper reads `config.env`/`version.env` through Compose to locate the running
backend and BreakTest DB. It uses those containers' resolved settings, network,
admin token, exact storage image and `/data` volume. Start the deployment with
BreakTest DB enabled first. Config changes must be applied to the running services
before migration. `COMPOSE_PROJECT_NAME` can select another Compose project.

Docker Compose and Docker permissions are required. The first invocation builds
a small Python/Docker-CLI helper image using public Docker and Python packages.
Subsequent invocations reuse its cached layers. No host Python, private Git access,
Git tags or backend application source is required. The Docker socket gives this
operator tool administrative Docker access; it is not exposed as an application API.
Credentials stay inside the helper and are not printed or placed in command arguments.

## Selection and rollback

Copy publishes a new sealed bundle, verifies it through the running reader and
registers it in MongoDB. Original test routing, MongoDB summaries, customer settings
and TimescaleDB rows are preserved. After copying, change the customer's Results
storage setting to **BreakTest DB** and reload the result page. Change it back to
**TimescaleDB** to read the original copy. Active runs retain their original writer.

The optional `switch` command changes migrated test routing explicitly. Normally
use the customer setting instead:

```sh
./migrate_customer.sh switch --customer CUSTOMER_ID --test TEST_ID --backend breaktest-db
./migrate_customer.sh switch --customer CUSTOMER_ID --test TEST_ID --backend timescaledb
```

A rerun checks the installed bundle identity and skips verified tests that are
already available to the application. Use `--reverify-existing` to recheck every
stored row in a verified copy. If a copy fails after publication but before
registration, a retry validates the existing bundle against a fresh source
snapshot before adopting it. One invocation runs at a time per work directory.

With `--customer all`, the tool discovers existing customers with TimescaleDB
configured, processes them in customer ID order, and copies one test at a time.
It reports individual failures, continues with the remaining tests and customers,
and exits nonzero if any copy fails. Use
`--continue-on-error` for the same behavior with one customer. Use `--test`
with a single customer.

Earlier copiers used the PostgreSQL session time zone to encode retained
one-second bucket timestamps. Copies made with a nonzero UTC offset at the
PostgreSQL epoch (January 1, 2000) can therefore show shifted aggregate charts.
Keep affected tests on TimescaleDB until their bundles have been rebuilt from
the source with the corrected copier. Reverification of an existing bundle
checks its integrity and preserves its original timestamps.

## Data safety and scope

Customer schema migration 50 adds the `jvm_samples` hypertable. New TimescaleDB JMeter writers send one row per load generator per tick. Older writers continue writing individual measurements to `runtime_metrics`. Use `runtime_metrics_read` for SQL queries across both layouts. The copier reads that view when present and can also copy pre-50 databases. Fingerprints and progress counts refer to individual measurements. Upgrade the backend and BreakTest DB readers before deploying the new JMeter and migration writers.

For `copy`, all source PostgreSQL connections default to read-only and exports additionally use
read-only repeatable-read transactions. No retention, maintenance or source refresh
is triggered. Pause source retention/deletion and other mutations for selected tests
while copying. Do not delete either copy while you need reversible selection.
This is not dual-write, deletion synchronization or a full application backup.

Finalized BreakTest, JMeter and k6 tests with a supported schema can be copied even when
raw requests, errors, or other raw streams have partially or fully expired. The
copier preserves the exact retained `requests_aggregated_1s`,
`requests_run_aggregated`, `transactions_run_aggregated`, and `tests_aggregated`
rows in the same read-only transaction as the remaining raw rows. It does not
refresh continuous aggregates or regenerate percentiles from incomplete samples.
A test with no rows at all in the source (neither raw nor retained) is skipped
and not recorded as migrated; naming it with `--test` fails instead.
Summary-only tests require valid start/end timestamps. Running and unfinalized tests are skipped. Current k6 HTTP and browser runs use the same
request streams. If a run also has rows in the obsolete `k6_browser_requests` table,
copy refuses that run to avoid publishing incomplete results. If a test has no run-scoped agent monitoring,
the copier checks the shared monitoring database for samples during the test.
Use `--copy-legacy-monitoring` to copy shared samples for the recorded generators
within each test's time window. The converted series uses the hardware specs
recorded in those samples. The copier rejects ambiguous generator mappings and
refuses to merge a shared stream with an existing run-scoped stream.
A customer must have exactly one source
TimescaleDB configuration. Source host/port and optional admin credentials come
from that record, falling back to deployment settings. Shared hardware metadata
uses the deployment's monitoring database.

Requests, transactions, errors including bodies, virtual users, runtime metrics and
generator metrics are verified with independent row fingerprints. Portable hardware
and generator display metadata are captured at migration time. Rows already removed
from the source cannot be recovered by this tool. Missing/partial raw request,
error and transaction counts are compared with finalized summaries; streams
without a known original count are marked unknown (or missing when empty). More
raw requests than the finalized summary aborts the copy; more errors or
transactions than their summary marks that stream unknown. The selected test's
summary page lists the streams with a confirmed gap or inconsistency; streams
that are only unknown for lack of an original count are not listed. Detailed charts
show only remaining raw rows; retained summaries and aggregate charts keep their
source values, including missing aggregate rows if those have also expired.

**Image upgrade required:** this uses immutable bundle v3 with a checksummed,
streamed retained SQL snapshot. Both staging and application BreakTest DB readers
must advertise `retained_timescaledb_v1`. Deploy the backend, frontend and storage
images containing this change before copying; overlaying migration scripts on an
older RC is insufficient. Older readers reject these bundles instead of silently
rebuilding incomplete summaries. Existing v1/v2 bundles remain readable. Switch
reads back to TimescaleDB before rolling back to images without v3 support.

### Compact historical JVM data

After applying schema 50, the backend's native workers compact historical JVM
data in the background. The worker scans configured TimescaleDB customer
databases one at a time, selects finalized JMeter runs, and commits one minute
at a time. It starts a new sweep five minutes after the previous one finishes.
Restarting the backend resumes from the remaining named measurements.

To run the backfill explicitly for one customer, use the command below.
Omitting `--test` selects all eligible finalized JMeter tests for that customer.

```sh
./migrate_customer.sh compact-jvm --customer CUSTOMER_ID [--test TEST_ID]
```

Each run moves its standard named JVM measurements into `jvm_samples` in one-minute transactions. Reads through `runtime_metrics_read` include committed results in either format. Rerunning after interruption picks up the remaining named measurements. Duplicate measurements retain their multiplicity, and nonstandard metrics, units and explicit null values remain in the named table. This command writes to TimescaleDB. The ordinary `copy` operation still uses a read-only source.

For a historical sealed BreakTest DB bundle, the offline JVM rewrite creates a verified bundle in a new directory. Supply the directory containing `bundle.json` and a destination on a filesystem with room for the rewritten copy.

```sh
breaktest-db optimize-copy /path/to/old/data /path/to/new/data jvm 1
```

The JVM rewrite copies other encoded streams and retained SQL snapshots and verifies the source and destination fingerprints. It publishes the output directory after verification. Existing routed runs keep their original bundle identity. Use the new bundle for a new publication or restore. Replacing a live directory behind a reader or a verified migration record can invalidate its recorded bundle identity.

Raw-clear, trim and general payload rewrites remain restricted for imported v3 bundles so they preserve the authoritative retained snapshot.

## Work files

By default, private work files are retained in `./migration-work`. For a larger disk:

```sh
MIGRATION_WORK_DIR=/data/migration-work ./migrate_customer.sh copy --customer CUSTOMER_ID --test TEST_ID
```

Use an existing writable directory on the Docker host. It is mounted at the same
absolute path in the helper and temporary encoder containers. Standard local Docker
is supported; remote Docker contexts are not. The target results volume is mounted
directly, including Docker Desktop named volumes. Never substitute an empty host
directory for the deployed results volume.

Budget disk for compressed source exports, temporary encoded bundles and the
published copy while keeping TimescaleDB. Work files contain customer data and may
be root-owned; inspect them with appropriate operator permissions. Remove only
completed work attempts after verification. The copy operation leaves the source data intact.

## Maintainer notes

`copy_customer.py` is the canonical implementation; the source-tree entry point
under `breaktest-db/migration` delegates here. `bundles.py` and `hardware.py` were
extracted from the final Python backend. They are standalone migration helpers,
not runtime imports from that backend. `wire-schema.json` mirrors the storage wire
schema; a packaging test prevents drift. The whole directory ships through the
existing self-host release bundle sync.

When `BREAKTEST_DB_DATA_PATH` is set, migration uses that running bind mount through
`--volumes-from`, exactly as it does for a named volume. Recreate both backend and
storage after changing this setting. Migration refuses a mismatch between the
backend's configured path and the running store's `/data` mount.

### Synthetic Monitoring

A whole-customer `copy` copies finalized load tests first, then Synthetic Monitoring
from a read-only TimescaleDB snapshot. This also applies to each customer in
`--customer all`. A `--test` filter copies only the selected load tests.
For a customer whose load tests were already migrated, run
`./migrate_customer.sh update-sm --customer CUSTOMER_ID` to copy only monitoring.

Copying preserves the current routing. For a monitoring cutover, pause the
customer's schedules, drain its producers and add `--activate` to either
whole-customer command. The copy refreshes an older unactivated snapshot if the
source has changed. Activation requires the last imported UTC hour to have
closed. Resume the schedules after activation. Repeating a copy skips verified
monitoring already serving native writes. Load-test routing remains independent.

Activation is one-way for everything recorded after it. The TimescaleDB
monitoring tables are only read, never changed, so the data up to activation
stays there. Executions recorded after activation exist only in BreakTest DB
and no command copies them back. Take a full backup before activating, and keep
the TimescaleDB monitoring tables for as long as you may want to return.

To return a customer to TimescaleDB, pause its schedules, drain its producers
and clear the selection in MongoDB:

```
db.customers.updateOne({_id: ObjectId("CUSTOMER_ID")}, {$unset: {syntheticMonitoringStorageBackend: ""}})
```

Then resume the schedules. Reads and new executions use TimescaleDB again, and
the executions recorded natively since activation are no longer shown. The
native dataset stays in `.monitoring/CUSTOMER_ID` under the BreakTest DB data
path. A later copy refuses to replace it because it holds native writes, so
activating again requires removing that directory first, which discards those
executions for good. Saved Synthetic Monitoring retention periods have no
effect while the customer uses TimescaleDB.

The copy accepts older TimescaleDB monitoring schemas: a column the source
table lacks is copied as null and reported. A monitoring table the copy does
not know is refused by name, because copying the rest would leave its data
behind.

BreakTest DB writes BTC3 column blocks using the same compression, bounded
segments, indexed time ranges and column checksums as load-test results.
The monitoring catalog publishes new segments, rollups, execution state and
retry receipts together. A continuous monitor spans any number of UTC days.
Each day's samples and error details have separate segments. Older hourly
states are sealed into monthly files, retaining the original occupied hours.
Screenshots are deduplicated by hash. The native trend query reads hourly
streams for all requested scenarios and reads retained error details only for
partial boundary hours. Other existing SQL dashboard and alert contracts use
DataFusion for in-memory calculation over native columns.

Data Management has separate Synthetic Monitoring raw and error retention
periods. Zero keeps the corresponding detail indefinitely. Maintenance expires
only complete UTC days and verifies the retained hourly sample count before
removing detail. Execution records and hourly data are retained. Expiring an error also releases its screenshot once no remaining error or execution references the image.
A sealed segment may contain multiple native files after the 128 MiB rollover.

A full native backup captures the catalog and the exact immutable segments it references. `full_backup.sh` writes that archive with the Python in the installed BreakTest DB image, so it needs no registry access. Set `BREAKTEST_DB_BACKUP_IMAGE` to use another image that provides `python3`.
