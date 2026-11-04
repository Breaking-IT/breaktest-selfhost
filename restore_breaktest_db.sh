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
IMAGE=${BREAKTEST_BACKEND_IMAGE:-breaktest-backend:${BREAKTEST_IMAGE_TAG:-latest}}

member=$(tar -tf "$ARCHIVE" | grep '/breaktest_db_data\.tar$' || true)
[[ -n $member ]] || die 'this backup contains no BreakTest DB data'
[[ $(printf '%s\n' "$member" | wc -l) -eq 1 ]] || die 'archive has more than one BreakTest DB member'

WORK=$(mktemp -d "${TMPDIR:-/tmp}/breaktest-db-restore.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
tar -xf "$ARCHIVE" -C "$WORK" "$member"
mkdir "$WORK/runs"
tar -xf "$WORK/$member" -C "$WORK/runs"
chmod -R a+rX "$WORK"

docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null
# The store runs as 1000:1000; a volume created here starts out owned by root.
docker run --rm -v "$VOLUME":/data alpine:latest chown 1000:1000 /data
# Uses the restore code shipped in the backend image, so it also works from a
# self-host bundle. The store discovers published directories itself.
docker run --rm --user 1000:1000 --workdir /app -e PYTHONPATH=/app --entrypoint python \
    -v "$VOLUME":/data -v "$WORK/runs":/backup:ro "$IMAGE" -c '
import json, sys
from pathlib import Path
from helpers.breaktest_db_bundles import restore_runs
result = restore_runs(Path("/backup"), Path("/data"))
print(json.dumps({key: len(value) for key, value in result.items()} | {"conflict_ids": result["conflicts"]}))
sys.exit(1 if result["conflicts"] else 0)
'
printf 'BreakTest DB restore completed into volume %s\n' "$VOLUME"
