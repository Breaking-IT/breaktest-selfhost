#!/usr/bin/env bash
# Shared with the source checkout and copied with the self-host release bundle.

bt_confirm_upgrade_interruptions() {
  local project_name="$1"
  local containers backend_id report reply reason

  echo "Checking for active tests in Compose project '$project_name'..."
  if ! containers=$(docker ps -q --filter "label=com.docker.compose.project=${project_name}"); then
    reason="Could not inspect the running containers; active tests could not be checked."
  elif [ -z "$containers" ]; then
    echo "No running project containers to interrupt."
    return 0
  else
    # Use the running image's Python/MongoDB dependencies and configuration,
    # not newly downloaded code or host tools. Scope discovery to this project.
    backend_id=""
    local service candidates
    for service in backend backend-api; do
      if ! candidates=$(docker ps -q \
        --filter "label=com.docker.compose.project=${project_name}" \
        --filter "label=com.docker.compose.service=${service}"); then
        break
      fi
      if [ -n "$candidates" ]; then
        backend_id="${candidates%%$'\n'*}"
        break
      fi
    done
    if [ -z "$backend_id" ]; then
      reason="No running backend is available; active tests could not be checked."
    elif report=$(docker exec -i "$backend_id" python - <<'PY'
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pymongo import MongoClient

try:
    with MongoClient(
        'mongodb',
        username=os.environ['MONGO_INITDB_ROOT_USERNAME'],
        password=os.environ['MONGO_INITDB_ROOT_PASSWORD'],
        authSource='admin',
        serverSelectionTimeoutMS=5000,
        connectTimeoutMS=5000,
        socketTimeoutMS=5000,
    ) as client:
        db = client[os.environ.get('MONGO_DATABASE', 'breakingit')]
        now = datetime.now(timezone.utc)
        active_statuses = {'Running', 'Starting', 'Paused', 'Stopping'}
        warnings = []
        # Generator activity warns regardless of the age of its test run.
        # Retain stale active reports as uncertainty, rather than declaring idle.
        generators = db.loadgenerators.find({'$or': [
            {'status': {'$in': list(active_statuses)}},
            {'active_run_ids.0': {'$exists': True}},
        ]}, {'generator_name': 1, 'status': 1, 'active_run_ids': 1,
             'ws_last_seen': 1, 'lastSeen': 1, 'ws_connection_id': 1})
        for generator in generators:
            seen = generator.get('ws_last_seen') or generator.get('lastSeen')
            if isinstance(seen, datetime) and seen.tzinfo is None:
                seen = seen.replace(tzinfo=timezone.utc)
            fresh = isinstance(seen, datetime) and now - timedelta(minutes=3) <= seen <= now
            status = generator.get('status') or 'Unknown'
            label = 'reported active' if fresh and status != 'Unavailable' else 'activity uncertain (stale/disconnected report)'
            name = json.dumps(str(generator.get('generator_name') or generator['_id']), ensure_ascii=True)
            runs = json.dumps(generator.get('active_run_ids') or [], ensure_ascii=True, default=str)
            warnings.append(f'Generator {name}: {label}; status={json.dumps(status)}; runs={runs}')

        # Also catch recent unfinished runs when an agent restart loses its active
        # run IDs. Old orphaned records alone must not keep upgrades blocked.
        cutoff = now - timedelta(hours=2)
        recent_unfinished = {'endTime': None, '$or': [
            {'commandStartTime': {'$gte': cutoff}},
            {'commandStartTime': None, 'startTime': {'$gte': cutoff}},
        ]}
        for test in db.tests.find(recent_unfinished, {'testName': 1}):
            name = json.dumps(str(test.get('testName') or 'Unnamed test'), ensure_ascii=True)
            warnings.append(f'Test {name} ({test["_id"]}): unfinished run started within the last two hours')
        if warnings:
            print(f'{len(warnings)} active or uncertain generator/test record(s) may be interrupted:')
            for warning in warnings[:20]:
                print(f'  - {warning}')
            if len(warnings) > 20:
                print(f'  ... and {len(warnings) - 20} more')

except Exception:
    print('Unable to read test state from MongoDB.', file=sys.stderr)
    sys.exit(1)
PY
    ); then
      if [ -z "$report" ]; then
        echo "No active tests found."
        return 0
      fi
      reason="$report"
    else
      reason="The active-test check failed; running tests may be interrupted."
    fi
  fi

  printf '\nWARNING: %s\n' "$reason"
  echo "Continuing will stop or recreate platform containers and may interrupt tests."
  if [ "${BT_UPGRADE_ASSUME_YES:-0}" = "1" ]; then
    echo "BT_UPGRADE_ASSUME_YES=1: explicitly accepting possible test interruption."
    return 0
  fi
  reply=""
  if read -r -p "Continue with upgrade? [yes/stop] (default: stop): " reply; then
    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
    esac
  fi
  echo "Upgrade cancelled. No containers were stopped or recreated by the upgrade."
  return 1
}
