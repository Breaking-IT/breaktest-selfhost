# Copy TimescaleDB results to BreakTest DB

From the self-host installation directory:

```sh
./migrate_customer.sh plan --customer CUSTOMER_ID
./migrate_customer.sh copy --customer CUSTOMER_ID --test TEST_ID
# After checking one test, omit --test to copy all eligible finalized tests.
./migrate_customer.sh copy --customer CUSTOMER_ID
```

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

A rerun verifies the installed bundle and skips copying it again. Existing bundles
are never overwritten. If a copy fails after publication but before registration,
a retry validates the existing bundle against a new source snapshot before adopting
it. One invocation runs at a time per work directory.

## Data safety and scope

All source PostgreSQL connections default to read-only and exports additionally use
read-only repeatable-read transactions. No retention, maintenance or source refresh
is triggered. Pause source retention/deletion and other mutations for selected tests
while copying. Do not delete either copy while you need reversible selection.
This is not dual-write, deletion synchronization or a full application backup.

Finalized BreakTest/JMeter tests with a supported schema can be copied even when
raw requests, errors, or other raw streams have partially or fully expired. The
copier preserves the exact retained `requests_aggregated_1s`,
`requests_run_aggregated`, `transactions_run_aggregated`, and `tests_aggregated`
rows in the same read-only transaction as the remaining raw rows. It does not
refresh continuous aggregates or regenerate percentiles from incomplete samples.
A test with no rows at all in the source (neither raw nor retained) is skipped
and not recorded as migrated; naming it with `--test` fails instead.
Summary-only tests require valid start/end timestamps. Running, unfinalized and
k6/browser runs remain unsupported. Tests with generators but no run-scoped agent monitoring also
require a separate legacy conversion. A customer must have exactly one source
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

Raw-clear, trim and offline optimize-copy operations on imported v3 bundles are currently rejected so
that they cannot invalidate the authoritative retained snapshot. Copy/switch and
rollback remain non-destructive; original TimescaleDB rows and metadata are not
changed. Backup/restore and directory publication preserve the snapshot.

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
completed work attempts after verification. The tool never cleans up source data.

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
