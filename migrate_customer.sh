#!/usr/bin/env bash
# Copy finalized customer results without changing TimescaleDB or customer defaults.
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# == 0 || ${1:-} == --help || ${1:-} == -h ]]; then
  cat <<'HELP'
Usage: ./migrate_customer.sh plan --customer CUSTOMER_ID [--test TEST_ID ...]
       ./migrate_customer.sh copy --customer CUSTOMER_ID [--test TEST_ID ...]
       ./migrate_customer.sh switch --customer CUSTOMER_ID --backend timescaledb|breaktest-db [--test TEST_ID ...]

Copy installs verified bundles and enables selection through the customer setting.
It does not change that setting, original test routing, or TimescaleDB data.
Run plan first. Finalized BreakTest/JMeter tests can include expired raw data; retained summaries are preserved.
Stop retention/deletion of selected source tests while copying.

Uses config.env, version.env and the running backend/BreakTest DB containers.
Requires Docker Compose and permission to use Docker. No host Python is needed.
MIGRATION_WORK_DIR overrides the private work directory (default ./migration-work).
The Compose project is chosen as in start.sh: PROJECT_NAME, else
BREAKTEST_COMPOSE_PROJECT_NAME from config.env, else "breaktest".
HELP
  exit 0
fi
[[ -f config.env && -f version.env ]] || { echo 'Run from an installed self-host bundle with config.env and version.env.' >&2; exit 1; }
# Same project selection as start.sh; a subshell keeps config.env out of this environment.
project=${PROJECT_NAME:-$(set +u; . ./config.env >/dev/null 2>&1; printf '%s' "${BREAKTEST_COMPOSE_PROJECT_NAME:-breaktest}")}
compose=(docker compose --env-file version.env --env-file config.env -f docker-compose.yaml -p "$project")
backend=$("${compose[@]}" ps -q backend)
store=$("${compose[@]}" --profile breaktest-db ps -q breaktest-db)
[[ -n $backend && -n $store && $backend != *$'\n'* && $store != *$'\n'* ]] || {
  echo 'Exactly one running backend and BreakTest DB service are required. Enable/start BreakTest DB first.' >&2; exit 1;
}
work=${MIGRATION_WORK_DIR:-"$PWD/migration-work"}
mkdir -p "$work"
# -m only applies to a newly created directory; work files contain customer data.
chmod 700 "$work" || { echo "Cannot make $work private (chmod 700); choose a directory you own." >&2; exit 1; }
work=$(cd "$work" && pwd -P)
# Rebuilding uses the packaged sources and Docker cache, never private Git access.
docker build -q -t breaktest-customer-migration:local migration >/dev/null
exec docker run --rm -i --network "container:$backend" \
  --volumes-from "$store:rw" \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  --mount "type=bind,src=$work,dst=$work" \
  breaktest-customer-migration:local \
  --backend-container "$backend" --store-container "$store" --work-root "$work" "$@"
