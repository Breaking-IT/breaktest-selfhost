#!/usr/bin/env bash
# Shared source/self-host preflight. Arguments after project are the Compose command.

bt_mongodb_state() {
  docker exec "$1" mongosh --quiet --eval '
    const a = db.getSiblingDB("admin");
    if (!a.auth(process.env.MONGO_INITDB_ROOT_USERNAME, process.env.MONGO_INITDB_ROOT_PASSWORD)) throw new Error("MongoDB authentication failed");
    const hello = a.runCommand({hello: 1});
    if (hello.setName || hello.msg === "isdbgrid") throw new Error("Automatic staging supports standalone MongoDB only");
    const r = a.runCommand({getParameter: 1, featureCompatibilityVersion: 1});
    if (!r.ok) throw new Error(JSON.stringify(r));
    const f = r.featureCompatibilityVersion;
    if (f.targetVersion || f.previousVersion) throw new Error("Finish the in-progress FCV transition first");
    print(db.version() + "|" + f.version);
  '
}

bt_wait_mongodb_state() {
  local attempt state
  for attempt in $(seq 1 30); do
    if state=$(bt_mongodb_state "$1" 2>/dev/null); then
      printf '%s\n' "$state"
      return 0
    fi
    sleep 1
  done
  bt_mongodb_state "$1" # Surface the final diagnostic; never treat failure as a fresh database.
  return 1
}

# The last verified "server|FCV", stored with the data so it survives `compose down`.
BT_MONGODB_STATE_FILE=/data/db/.breaktest-mongodb-state

bt_write_mongodb_marker() {
  docker exec "$1" sh -c 'printf "%s\n" "$1" > "$2.tmp" && mv "$2.tmp" "$2"' \
    sh "$2" "$BT_MONGODB_STATE_FILE"
}

# Read the marker from a volume without starting mongod; prints nothing when absent.
bt_read_mongodb_marker() {
  local run_args=(run --rm --entrypoint cat -v "$1:/data/db:ro")
  if [ "${PULL_IMAGES:-true}" = false ]; then
    run_args+=(--pull never)
  fi
  docker "${run_args[@]}" "$2" "$BT_MONGODB_STATE_FILE" 2>/dev/null || true
}

# After a successful start, record the running state so `stop.sh` (compose down)
# followed by a start can still be verified. Never fails the start.
bt_record_mongodb_upgrade_state() {
  shift
  local container state
  container=$("$@" ps -q mongodb 2>/dev/null) || container=""
  case "$container" in
    ''|*$'\n'*) ;;
    *) state=$(bt_wait_mongodb_state "$container" 2>/dev/null) &&
         bt_write_mongodb_marker "$container" "$state" && return 0 ;;
  esac
  echo 'Warning: could not record the MongoDB upgrade state.' >&2
  return 0
}

bt_prepare_mongodb_upgrade() {
  local project="$1"
  shift
  local target container volumes state version fcv marker
  local stage_args=(up -d --no-deps --wait --wait-timeout 120)
  if [ "${PULL_IMAGES:-true}" = false ]; then
    stage_args+=(--pull never)
  fi
  target=$("$@" config --images mongodb) || return 1
  case "$target" in
    mongo:9.0.*) ;;
    mongo:8.3.*) return 0 ;;
    *) echo "Unsupported MongoDB upgrade target: $target" >&2; return 1 ;;
  esac
  container=$("$@" ps -aq mongodb) || return 1
  if [ -z "$container" ]; then
    volumes=$(docker volume ls -q --filter "label=com.docker.compose.project=$project" \
      --filter 'label=com.docker.compose.volume=mongodb_data') || return 1
    # Also detect the default named volume if it was created without Compose labels.
    if [ -z "$volumes" ] && docker volume inspect "${project}_mongodb_data" >/dev/null 2>&1; then
      volumes="${project}_mongodb_data"
    fi
    if [ -n "$volumes" ]; then
      case "$volumes" in *$'\n'*) echo 'Expected one MongoDB data volume.' >&2; return 1 ;; esac
      # The marker only identifies binaries to try; its FCV may be stale.
      # Recreate the service with those binaries, then use the live checks below.
      marker=$(bt_read_mongodb_marker "$volumes" "$target")
      if [[ "$marker" =~ ^(8\.3\.[0-9]+|9\.0\.[0-9]+)\|(8\.3|9\.0)$ ]]; then
        version="${marker%|*}"
        echo "MongoDB upgrade preflight: recovering server $version to verify live FCV on volume $volumes."
        local recovery_target
        recovery_target=$(MONGODB_VERSION="$version" "$@" config --images mongodb) || return 1
        if [ "$recovery_target" != "mongo:$version" ]; then
          echo "MongoDB recovery requires Compose to honor MONGODB_VERSION=$version; got $recovery_target." >&2
          return 1
        fi
        MONGODB_VERSION="$version" "$@" "${stage_args[@]}" mongodb || return 1
        container=$("$@" ps -aq mongodb) || return 1
        if [ -z "$container" ]; then
          echo 'MongoDB recovery did not create a container.' >&2
          return 1
        fi
      else
        echo "MongoDB data exists without its container${marker:+ (last verified: $marker)}. Start it with its previous MongoDB version first, then retry the staged upgrade." >&2
        return 1
      fi
    else
      echo "Fresh MongoDB installation: $target (no existing data volume)."
      return 0
    fi
  fi
  case "$container" in *$'\n'*) echo 'Expected one standalone MongoDB container.' >&2; return 1 ;; esac
  # Starting the existing container retains its original binaries and volume.
  docker start "$container" >/dev/null || return 1
  state=$(bt_wait_mongodb_state "$container") || return 1
  bt_write_mongodb_marker "$container" "$state" || return 1
  IFS='|' read -r version fcv <<< "$state"
  echo "MongoDB upgrade preflight: server $version, FCV $fcv; target $target."
  case "$version|$fcv" in
    9.0.*\|8.3|9.0.*\|9.0) return 0 ;;
    8.3.*\|8.3) return 0 ;;
    8.2.*\|8.2|8.3.*\|8.2) ;;
    *) echo "Unsupported MongoDB upgrade state: $state. Complete the supported intermediate upgrade first." >&2; return 1 ;;
  esac
  case "$version" in
    8.2.*)
      echo 'Starting intermediate MongoDB 8.3.9 on the existing volume...'
      MONGODB_VERSION=8.3.9 "$@" "${stage_args[@]}" mongodb || return 1
      container=$("$@" ps -aq mongodb) || return 1
      state=$(bt_wait_mongodb_state "$container") || return 1
      case "$state" in 8.3.*\|8.2) ;; *) echo "Unexpected intermediate state: $state" >&2; return 1 ;; esac
      ;;
  esac
  echo 'Setting MongoDB FCV to 8.3 before replacing the binaries...'
  docker exec "$container" mongosh --quiet --eval '
    const a = db.getSiblingDB("admin");
    if (!a.auth(process.env.MONGO_INITDB_ROOT_USERNAME, process.env.MONGO_INITDB_ROOT_PASSWORD)) throw new Error("MongoDB authentication failed");
    const r = a.runCommand({setFeatureCompatibilityVersion: "8.3", confirm: true});
    if (!r.ok) throw new Error(JSON.stringify(r));
  ' || return 1
  state=$(bt_mongodb_state "$container") || return 1
  case "$state" in
    8.3.*\|8.3)
      bt_write_mongodb_marker "$container" "$state" || return 1
      echo "Verified $state. Ready to start $target; FCV 9.0 remains opt-in." ;;
    *) echo "FCV preparation did not complete: $state" >&2; return 1 ;;
  esac
}
