#!/bin/bash

set -Eeuo pipefail

if [[ -f config.env ]]; then
    # shellcheck disable=SC1091
    source config.env
fi

BACKUP_PATH=${BACKUP_PATH:-./backups}
MONGO_USER=${MONGO_INITDB_ROOT_USERNAME:-admin}
MONGO_PASS=${MONGO_INITDB_ROOT_PASSWORD:-}
MONGO_DB=${MONGO_DATABASE:-breakingit}
POSTGRES_USER=${POSTGRES_USER:-admin}
POSTGRES_PASS=${POSTGRES_PASSWORD:-}
POSTGRES_HOST=${POSTGRES_HOST:-timescaledb}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_CONTAINER=${POSTGRES_CONTAINER:-timescaledb}
MONGO_CONTAINER=${MONGO_CONTAINER:-mongodb}
BACKEND_CONTAINER=${BACKEND_CONTAINER:-backend}
MONITORING_DB_NAME=${MONITORING_DB_NAME:-breaktest_monitoring}
# Keep all existing local backups when upgrading from a config.env that did
# not have this setting. Fresh generated/sample configs set an explicit
# retention count.
LOCAL_BACKUP_RETENTION_COUNT=${LOCAL_BACKUP_RETENTION_COUNT:-0}
MAX_PARALLEL=${MAX_PARALLEL:-3}
BACKUP_INSTALLATION_NAME=${BACKUP_INSTALLATION_NAME:-}

if ! [[ $LOCAL_BACKUP_RETENTION_COUNT =~ ^[0-9]+$ ]]; then
    printf '%s\n' 'ERROR: LOCAL_BACKUP_RETENTION_COUNT must be a non-negative integer' >&2
    exit 1
fi

if [[ ${HETZNER_STORAGE_ENABLED:-false} == true && -n $BACKUP_INSTALLATION_NAME ]]; then
    [[ $BACKUP_INSTALLATION_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || { printf '%s\n' 'ERROR: BACKUP_INSTALLATION_NAME must contain only letters, numbers, dots, underscores, and hyphens, and start with a letter or number' >&2; exit 1; }
    ((${#BACKUP_INSTALLATION_NAME} <= 64)) \
        || { printf '%s\n' 'ERROR: BACKUP_INSTALLATION_NAME must be at most 64 characters' >&2; exit 1; }
fi

mkdir -p "$BACKUP_PATH"
BACKUP_PATH=$(cd "$BACKUP_PATH" && pwd -P)
LOG_FILE="$BACKUP_PATH/backup.log"

log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

die() {
    printf '%s\n' "ERROR: $*" | tee -a "$LOG_FILE" >&2
    exit 1
}

resolve_compose_container() {
    local service=$1
    local container_id

    container_id=$("${DOCKER_COMPOSE[@]}" "${COMPOSE_ARGS[@]}" ps -q "$service" 2>/dev/null | head -n 1)
    [[ -n $container_id ]] || die "Could not find running Compose service: $service"
    printf '%s' "$container_id"
}

if [[ -n ${BREAKTEST_COMPOSE_PROJECT_NAME:-} ]]; then
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE=(docker compose)
    elif docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE=(docker-compose)
    else
        die "Neither 'docker compose' nor 'docker-compose' is available"
    fi
    COMPOSE_ARGS=(-p "$BREAKTEST_COMPOSE_PROJECT_NAME")
    [[ ! -f version.env ]] || COMPOSE_ARGS+=(--env-file version.env)
    [[ ! -f config.env ]] || COMPOSE_ARGS+=(--env-file config.env)
    POSTGRES_CONTAINER=$(resolve_compose_container "$POSTGRES_CONTAINER")
    MONGO_CONTAINER=$(resolve_compose_container "$MONGO_CONTAINER")
    BACKEND_CONTAINER=$(resolve_compose_container "$BACKEND_CONTAINER")
else
    DOCKER_COMPOSE=()
    COMPOSE_ARGS=()
fi

TIMESTAMP=${BACKUP_TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}
BACKUP_BASENAME="full_backup_${TIMESTAMP}"
BACKUP_DIR="$BACKUP_PATH/$BACKUP_BASENAME"
PARTIAL_TARBALL="$BACKUP_PATH/${BACKUP_BASENAME}.tar.partial"
FINAL_TARBALL="$BACKUP_PATH/${BACKUP_BASENAME}.tar"
LATEST_LINK="$BACKUP_PATH/full_backup_latest.tar"
LATEST_TEMP="$BACKUP_PATH/.full_backup_latest.tar.$$"
LOCK_FILE="$BACKUP_PATH/.full_backup.lock"
LOCK_DIR="$BACKUP_PATH/.full_backup.lock.d"
LOCK_MODE=
RUN_SUCCESS=0

cleanup() {
    local exit_code=$?

    if (( RUN_SUCCESS == 0 )); then
        [[ -z ${BACKUP_DIR:-} || ! -e $BACKUP_DIR ]] || rm -rf "$BACKUP_DIR"
        [[ -z ${PARTIAL_TARBALL:-} || ! -e $PARTIAL_TARBALL ]] || rm -f "$PARTIAL_TARBALL"
        [[ -z ${LATEST_TEMP:-} || ! -e $LATEST_TEMP ]] || rm -f "$LATEST_TEMP"
    fi

    if [[ $LOCK_MODE == mkdir ]]; then
        [[ ! -d $LOCK_DIR ]] || rmdir "$LOCK_DIR" 2>/dev/null || true
    fi

    return "$exit_code"
}

acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            printf '%s\n' 'Another backup is already running' >&2
            exit 1
        fi
        LOCK_MODE=flock
    else
        # macOS does not ship flock; mkdir provides the same atomic fallback.
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s\n' 'Another backup is already running' >&2
            exit 1
        fi
        LOCK_MODE=mkdir
    fi
}

acquire_lock
trap cleanup EXIT

# Only remove timestamp-shaped partial archives older than 48 hours.
find "$BACKUP_PATH" -maxdepth 1 -type f \
    -name 'full_backup_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].tar.partial' \
    -mmin +2880 -delete

if ! mkdir "$BACKUP_DIR"; then
    die "backup directory already exists: $BACKUP_DIR"
fi

log "Starting full backup: $TIMESTAMP"

validate_postgres_tools() {
    docker exec "$POSTGRES_CONTAINER" pg_dump --version >/dev/null 2>&1 \
        || die 'pg_dump is not available in the PostgreSQL container'
    docker exec "$POSTGRES_CONTAINER" pg_restore --version >/dev/null 2>&1 \
        || die 'pg_restore is not available in the PostgreSQL container'
}

backup_grafana() {
    local volume_name=$1
    local output_file="$BACKUP_DIR/grafana_data.tar.gz"

    log 'Backing up Grafana volume'
    if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
        log "WARNING: Grafana volume not found: $volume_name; skipping Grafana backup"
        return 0
    fi
    docker run --rm -v "$volume_name":/source:ro alpine:latest \
        tar czf - -C /source . >"$output_file" 2>/dev/null \
        || die 'Grafana backup failed'
    [[ -s $output_file ]] || die 'Grafana backup is empty'
}

backup_mongodb() {
    local output_file="$BACKUP_DIR/mongodb_export.archive.gz"

    log 'Backing up MongoDB'
    [[ -n $MONGO_PASS ]] || die 'MongoDB password is not configured'
    docker exec "$MONGO_CONTAINER" mongodump \
        --authenticationDatabase admin \
        --username "$MONGO_USER" \
        --password "$MONGO_PASS" \
        --db "$MONGO_DB" \
        --archive --gzip >"$output_file" 2>/dev/null \
        || die 'MongoDB backup failed'
    [[ -s $output_file ]] || die 'MongoDB backup is empty'
}

backup_database() {
    local dbname=$1
    local dump_file="$BACKUP_DIR/${dbname}_backup.dump"

    log "Backing up database: $dbname"
    if ! docker exec -e PGPASSWORD="$POSTGRES_PASS" "$POSTGRES_CONTAINER" pg_dump \
        -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" \
        -d "$dbname" -F c >"$dump_file" 2>/dev/null; then
        rm -f "$dump_file"
        log "pg_dump failed: $dbname"
        return 1
    fi
    if [[ ! -s $dump_file ]]; then
        rm -f "$dump_file"
        log "Database dump is empty: $dbname"
        return 1
    fi
    if ! docker exec -i "$POSTGRES_CONTAINER" pg_restore --list \
        <"$dump_file" >/dev/null 2>&1; then
        rm -f "$dump_file"
        log "pg_restore validation failed: $dbname"
        return 1
    fi
}

append_database_dump() {
    local dbname=$1
    local dump_file="$BACKUP_DIR/${dbname}_backup.dump"
    local archive_member="$BACKUP_BASENAME/${dbname}_backup.dump"

    [[ -s $dump_file ]] || die "database dump is missing or empty: $dbname"
    tar --append --file="$PARTIAL_TARBALL" -C "$BACKUP_PATH" \
        "$archive_member" >/dev/null 2>&1 \
        || die "failed to append database dump: $dbname"
    rm -f "$dump_file" || die "failed to remove temporary database dump: $dbname"
}

get_dynamic_db_list() {
    docker exec -i \
        -e MONGO_INITDB_ROOT_USERNAME="$MONGO_USER" \
        -e MONGO_INITDB_ROOT_PASSWORD="$MONGO_PASS" \
        -e MONGO_DATABASE="$MONGO_DB" \
        "$BACKEND_CONTAINER" python3 - 2>/dev/null <<'PYTHON'
import json
import os
from pymongo import MongoClient

mongo_user = os.environ.get("MONGO_INITDB_ROOT_USERNAME", "admin")
mongo_pass = os.environ.get("MONGO_INITDB_ROOT_PASSWORD", "")
mongo_db = os.environ.get("MONGO_DATABASE", "breakingit")

client = MongoClient(
    f"mongodb://{mongo_user}:{mongo_pass}@mongodb:27017/?authSource=admin",
    serverSelectionTimeoutMS=10000,
)
client.admin.command("ping")
db = client[mongo_db]
customer_dbs = []
for customer in db.customers.find({}, {"name": 1, "_id": 1}):
    customer_id = str(customer["_id"])
    customer_name = customer.get("name", "")
    tsdb = db.timescaledb.find_one({"customer_id": customer_id, "default": True}) or \
           db.timescaledb.find_one({"customer_id": customer_id})
    dbname = tsdb.get("database") if tsdb else customer_name.lower()
    if dbname:
        customer_dbs.append({
            "dbname": dbname,
            "customer_name": customer_name,
            "customer_id": customer_id,
        })
print(json.dumps(customer_dbs))
PYTHON
}

parse_db_list() {
    local raw_list=$1
    local line dbname

    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line ]] && continue
        if [[ $line == *'|'* ]]; then
            IFS='|' read -r dbname _ _ <<<"$line"
        else
            # A whitespace-separated DB_LIST is convenient for simple callers.
            for dbname in $line; do
                register_database "$dbname"
            done
            continue
        fi
        register_database "$dbname"
    done <<<"$raw_list"
}

register_database() {
    local dbname=$1
    local existing

    [[ -n $dbname ]] || return 0
    [[ $dbname != */* ]] || die "invalid database name: $dbname"
    if ((${#DB_NAMES[@]} > 0)); then
        for existing in "${DB_NAMES[@]}"; do
            if [[ $existing == "$dbname" ]]; then
                log "WARNING: duplicate database in DB_LIST: $dbname; skipping duplicate"
                return 0
            fi
        done
    fi
    DB_NAMES+=("$dbname")
}

ensure_database() {
    local dbname=$1
    local existing

    if ((${#DB_NAMES[@]} > 0)); then
        for existing in "${DB_NAMES[@]}"; do
            [[ $existing != "$dbname" ]] || return 0
        done
    fi
    register_database "$dbname"
}

verify_member_once() {
    local archive=$1
    local member=$2
    local count

    count=$(tar -tf "$archive" 2>/dev/null | awk -F/ -v member="$member" \
        '$NF == member { count++ } END { print count + 0 }') \
        || die "cannot inspect tar archive while checking $member"
    [[ $count -eq 1 ]] || die "expected exactly one tar member named $member, found $count"
}

run_retention() {
    local current_target=''
    local candidate base kept=0
    local -a candidates=()
    local sorted_candidates=''

    if (( LOCAL_BACKUP_RETENTION_COUNT == 0 )); then
        log 'Local backup retention is disabled; keeping all timestamped backups.'
        return 0
    fi

    if [[ -L $LATEST_LINK ]]; then
        current_target=$(readlink "$LATEST_LINK")
    fi

    for candidate in "$BACKUP_PATH"/full_backup_*.tar; do
        [[ -f $candidate && ! -L $candidate ]] || continue
        base=$(basename "$candidate")
        [[ $base =~ ^full_backup_[0-9]{8}_[0-9]{6}\.tar$ ]] || continue
        candidates+=("$base")
    done

    if ((${#candidates[@]} > 0)); then
        sorted_candidates=$(printf '%s\n' "${candidates[@]}" | sort -r)
    fi

    while IFS= read -r base || [[ -n $base ]]; do
        [[ -n $base ]] || continue
        if (( kept < LOCAL_BACKUP_RETENTION_COUNT )); then
            kept=$((kept + 1))
            continue
        fi
        [[ $base != "$current_target" ]] || continue
        log "Removing old local backup: $base"
        rm -f "$BACKUP_PATH/$base" || die "failed to remove old backup: $base"
    done <<<"$sorted_candidates"
}

COMPOSE_PROJECT_NAME=${BREAKTEST_COMPOSE_PROJECT_NAME:-$(basename "$(pwd -P)")}
validate_postgres_tools
backup_grafana "${COMPOSE_PROJECT_NAME}_grafana_data"
backup_mongodb

tar -cf "$PARTIAL_TARBALL" -C "$BACKUP_PATH" "$BACKUP_BASENAME" \
    >/dev/null 2>&1 || die 'failed to create partial tar archive'

DB_NAMES=()
if [[ ${DB_LIST+x} == x ]]; then
    parse_db_list "$DB_LIST"
else
    CUSTOMER_DBS=$(get_dynamic_db_list) \
        || die 'failed to retrieve customer database list from MongoDB'
    DB_LIST=$(printf '%s' "$CUSTOMER_DBS" | docker exec -i "$BACKEND_CONTAINER" python3 -c '
import json, sys
for item in json.load(sys.stdin):
    print("{}|{}|{}".format(item["dbname"], item.get("customer_name", ""), item.get("customer_id", "")))
') || die 'failed to parse customer database list'
    parse_db_list "$DB_LIST"
    register_database postgres
fi

# The shared monitoring database is not part of the customer list, but it is
# part of the installation backup and must be included explicitly.
ensure_database "$MONITORING_DB_NAME"

DB_FAILURE=0
DB_PIDS=()
if ((${#DB_NAMES[@]} > 0)); then
    for dbname in "${DB_NAMES[@]}"; do
        backup_database "$dbname" &
        DB_PIDS+=("$!")

        while ((${#DB_PIDS[@]} >= MAX_PARALLEL)); do
            if ! wait "${DB_PIDS[0]}"; then
                DB_FAILURE=1
            fi
            DB_PIDS=("${DB_PIDS[@]:1}")
        done
    done

    for db_index in "${!DB_PIDS[@]}"; do
        if ! wait "${DB_PIDS[$db_index]}"; then
            DB_FAILURE=1
        fi
    done
fi

((DB_FAILURE == 0)) || die 'one or more database backups failed'

if ((${#DB_NAMES[@]} > 0)); then
    for dbname in "${DB_NAMES[@]}"; do
        append_database_dump "$dbname"
    done
fi

if [[ -s "$BACKUP_DIR/grafana_data.tar.gz" ]]; then
    verify_member_once "$PARTIAL_TARBALL" 'grafana_data.tar.gz'
fi
verify_member_once "$PARTIAL_TARBALL" 'mongodb_export.archive.gz'
if ((${#DB_NAMES[@]} > 0)); then
    for dbname in "${DB_NAMES[@]}"; do
        verify_member_once "$PARTIAL_TARBALL" "${dbname}_backup.dump"
    done
fi

# This is the final structural check before the archive becomes publishable.
tar -tf "$PARTIAL_TARBALL" >/dev/null 2>&1 \
    || die 'partial tar archive is corrupt'

mv -f "$PARTIAL_TARBALL" "$FINAL_TARBALL" \
    || die 'failed to publish timestamped backup archive'

if [[ ${HETZNER_STORAGE_ENABLED:-false} == true ]]; then
    [[ -n ${HETZNER_STORAGE_HOST:-} && -n ${HETZNER_STORAGE_USER:-} ]] \
        || die 'Hetzner storage host and user must be configured'
    HETZNER_STORAGE_PATH=${HETZNER_STORAGE_PATH:-backups}
    HETZNER_STORAGE_SSH_PORT=${HETZNER_STORAGE_SSH_PORT:-23}
    if [[ -n $BACKUP_INSTALLATION_NAME ]]; then
        REMOTE_BACKUP_PATH="${HETZNER_STORAGE_PATH%/}/$BACKUP_INSTALLATION_NAME"
    else
        # Preserve the pre-installation-name location for existing configs.
        REMOTE_BACKUP_PATH="${HETZNER_STORAGE_PATH%/}"
        log 'WARNING: BACKUP_INSTALLATION_NAME is unset; using the legacy Hetzner backup path.'
    fi

    if [[ -n ${HETZNER_STORAGE_SSH_KEY:-} ]]; then
        RSYNC_SSH_CMD="ssh -p $HETZNER_STORAGE_SSH_PORT -i $HETZNER_STORAGE_SSH_KEY"
        ssh -p "$HETZNER_STORAGE_SSH_PORT" -i "$HETZNER_STORAGE_SSH_KEY" \
            "$HETZNER_STORAGE_USER@$HETZNER_STORAGE_HOST" \
            "mkdir -p \"$REMOTE_BACKUP_PATH\"" >/dev/null 2>&1 \
            || die 'failed to create Hetzner backup directory'
    else
        RSYNC_SSH_CMD="ssh -p $HETZNER_STORAGE_SSH_PORT"
        ssh -p "$HETZNER_STORAGE_SSH_PORT" \
            "$HETZNER_STORAGE_USER@$HETZNER_STORAGE_HOST" \
            "mkdir -p \"$REMOTE_BACKUP_PATH\"" >/dev/null 2>&1 \
            || die 'failed to create Hetzner backup directory'
    fi

    rsync -a -e "$RSYNC_SSH_CMD" "$FINAL_TARBALL" \
        "$HETZNER_STORAGE_USER@$HETZNER_STORAGE_HOST:$REMOTE_BACKUP_PATH/" \
        >/dev/null 2>&1 || die 'failed to upload backup to Hetzner Storage Box'
fi

ln -s "$(basename "$FINAL_TARBALL")" "$LATEST_TEMP" \
    || die 'failed to create temporary latest symlink'
if ! mv -Tf "$LATEST_TEMP" "$LATEST_LINK" >/dev/null 2>&1; then
    # BSD mv has no -T; its -f rename is still atomic for this exact target.
    mv -f "$LATEST_TEMP" "$LATEST_LINK" \
        || die 'failed to atomically update latest symlink'
fi

run_retention
rm -rf "$BACKUP_DIR"
RUN_SUCCESS=1
log "Backup completed successfully: $FINAL_TARBALL"
