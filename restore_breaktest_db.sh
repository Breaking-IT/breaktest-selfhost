#!/bin/bash
# Restore BreakTest DB results from a full_backup.sh archive into the BreakTest DB volume.
# Runs that already exist are kept; a different bundle under the same id is
# reported and never overwritten. Restore MongoDB from the same archive too, so
# the test documents that reference these results exist.
#
# Usage: ./restore_breaktest_db.sh backups/full_backup_YYYYmmdd_HHMMSS.tar
set -Eeuo pipefail
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage: $0 <full_backup archive>"
ARCHIVE=$1
[[ -f $ARCHIVE ]] || die "archive not found: $ARCHIVE"
if [[ -f config.env ]]; then
    # shellcheck disable=SC1091
    source config.env
fi
# Same project and volume naming as full_backup.sh.
COMPOSE_PROJECT_NAME=${BREAKTEST_COMPOSE_PROJECT_NAME:-$(basename "$(pwd -P)")}
VOLUME="${BREAKTEST_DB_VOLUME_NAME:-${COMPOSE_PROJECT_NAME}_breaktest_results}"
# The restore runs the backend image's --restore-breaktest-db. Use the image
# this installation runs: a self-host bundle pins it in version.env (registry
# from config.env; BREAKTEST_VERSION in config.env overrides every image, as
# in start.sh). A source checkout uses its locally built image.
if [[ -f version.env ]]; then
    set -a
    # shellcheck disable=SC1091
    source version.env
    if [[ -f config.env ]]; then
        # shellcheck disable=SC1091
        source config.env
    fi
    set +a
    backend_version=${BREAKTEST_BACKEND_VERSION:-${BREAKTEST_VERSION:-}}
    if [[ -f config.env ]] && grep -q '^BREAKTEST_VERSION=..*' config.env; then
        backend_version=$BREAKTEST_VERSION
    fi
    [[ -n $backend_version ]] || die 'version.env pins no backend version'
    DEFAULT_IMAGE="${BREAKTEST_IMAGE_REGISTRY:-breakingit}/breaktest-backend:${backend_version}"
else
    DEFAULT_IMAGE="breaktest-backend:${BREAKTEST_IMAGE_TAG:-latest}"
fi
IMAGE=${BREAKTEST_BACKEND_IMAGE:-$DEFAULT_IMAGE}

member=$(tar -tf "$ARCHIVE" | grep '/breaktest_db_data\.tar$' || true)
[[ -n $member ]] || die 'this backup contains no BreakTest DB data'
[[ $(printf '%s\n' "$member" | wc -l) -eq 1 ]] || die 'archive has more than one BreakTest DB member'

WORK=$(mktemp -d "${TMPDIR:-/tmp}/breaktest-db-restore.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
tar -xf "$ARCHIVE" -C "$WORK" "$member"
mkdir "$WORK/runs"
tar -xf "$WORK/$member" -C "$WORK/runs"
chmod -R a+rX "$WORK"

if [[ -n ${BREAKTEST_DB_DATA_PATH:-} ]]; then
    [[ $BREAKTEST_DB_DATA_PATH == /* && $BREAKTEST_DB_DATA_PATH != / && $BREAKTEST_DB_DATA_PATH != *:* && -d $BREAKTEST_DB_DATA_PATH ]] \
        || die 'BREAKTEST_DB_DATA_PATH must be an existing absolute dedicated directory'
    VOLUME=$BREAKTEST_DB_DATA_PATH
else
    docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null
fi
# The store runs as 1000:1000; a volume created here starts out owned by root.
docker run --rm -v "$VOLUME":/data alpine:latest chown 1000:1000 /data
# Uses the restore code shipped in the backend image (see IMAGE above). The
# store discovers published directories itself.
docker run --rm --user 1000:1000 --entrypoint /breaktest-backend-api \
    -v "$VOLUME":/data -v "$WORK/runs":/backup:ro "$IMAGE" \
    --restore-breaktest-db /backup /data
printf 'BreakTest DB restore completed into %s\n' "$VOLUME"
