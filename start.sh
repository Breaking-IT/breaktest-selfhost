#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=config-helpers.sh
source "$(dirname "$0")/config-helpers.sh"

SHOW_LOGS=false
RESTART_SERVICE=""
PULL_IMAGES=true
PROJECT_NAME=""

usage() {
  cat <<'EOF'
Usage: ./start.sh [-f] [-r service] [--no-pull] [--project-name name]

  -f            Follow logs after starting
  -r service    Recreate one service
  --no-pull     Skip pulling images before start
  --project-name name
                Docker Compose project name, used to isolate containers and volumes
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -f)
      SHOW_LOGS=true
      shift
      ;;
    -r)
      RESTART_SERVICE="${2:-}"
      if [ -z "$RESTART_SERVICE" ]; then
        usage
        exit 1
      fi
      shift 2
      ;;
    --no-pull)
      PULL_IMAGES=false
      shift
      ;;
    --project-name)
      PROJECT_NAME="${2:-}"
      if [ -z "$PROJECT_NAME" ]; then
        usage
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker-compose"
else
  echo "Error: neither 'docker compose' nor 'docker-compose' found" >&2
  exit 1
fi

random_hex() {
  openssl rand -hex "${1:-32}" 2>/dev/null || {
    echo "Error: openssl is required to generate local secrets" >&2
    exit 1
  }
}

credential_key() {
  openssl rand -base64 32 | tr '+/' '-_'
}

set_env_value() {
  local key="$1"
  local value="$2"
  local escaped
  escaped=$(printf '%s' "$value" | sed 's/[&|]/\\&/g')
  if grep -q "^${key}=" config.env; then
    sed -i.bak "s|^${key}=.*|${key}=${escaped}|" config.env
    rm -f config.env.bak
  else
    printf '%s=%s\n' "$key" "$value" >> config.env
  fi
}

check_free_disk_space() {
  local required_gb="${BREAKTEST_MIN_FREE_DISK_GB:-2}"
  local disk_path="."
  local docker_root
  local available_kib
  local required_kib

  case "$required_gb" in
    ''|*[!0-9]*)
      echo "Error: BREAKTEST_MIN_FREE_DISK_GB must be a whole number: $required_gb" >&2
      exit 1
      ;;
  esac
  if [ "$required_gb" -lt 1 ]; then
    echo "Error: BREAKTEST_MIN_FREE_DISK_GB must be at least 1: $required_gb" >&2
    exit 1
  fi

  docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
  if [ -n "$docker_root" ] && [ -d "$docker_root" ]; then
    disk_path="$docker_root"
  fi
  available_kib=$(df -Pk "$disk_path" | awk 'NR == 2 { print $4 }')
  case "$available_kib" in
    ''|*[!0-9]*)
      echo "Error: unable to determine free disk space for $disk_path." >&2
      exit 1
      ;;
  esac
  required_kib=$((required_gb * 1024 * 1024))
  if [ "$available_kib" -lt "$required_kib" ]; then
    echo "Error: only $((available_kib / 1024)) MiB is free on $(df -P "$disk_path" | awk 'NR == 2 { print $6 }')." >&2
    echo "BreakTest needs at least ${required_gb} GiB free before Docker pulls or starts the stack." >&2
    echo "Remove unused images or move Docker's data root, then run ./start.sh again." >&2
    exit 1
  fi
}

wait_for_required_services() {
  local timeout_seconds="${BREAKTEST_STARTUP_HEALTH_TIMEOUT_SECONDS:-300}"
  if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: BREAKTEST_STARTUP_HEALTH_TIMEOUT_SECONDS must be a positive whole number: $timeout_seconds" >&2
    exit 1
  fi
  local deadline=$((SECONDS + timeout_seconds))
  local service container health all_ready
  local services=(mongodb timescaledb pg-proxy traefik backend frontend)
  if profile_contains "${COMPOSE_PROFILES:-}" "grafana"; then
    services+=(grafana)
  fi

  echo "Waiting for database, proxy, Traefik, backend, and frontend health checks..."
  while [ "$SECONDS" -lt "$deadline" ]; do
    all_ready=true
    for service in "${services[@]}"; do
      container=$($DOCKER_COMPOSE "${COMPOSE_ARGS[@]}" ps -q "$service" 2>/dev/null | head -n 1)
      if [ -z "$container" ]; then
        all_ready=false
        continue
      fi
      health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)
      if [ "$health" != "healthy" ]; then
        all_ready=false
      fi
    done
    if [ "$all_ready" = true ]; then
      echo "Required services are healthy."
      return 0
    fi
    sleep 2
  done

  echo "Error: the required services did not become healthy within ${timeout_seconds}s." >&2
  $DOCKER_COMPOSE "${COMPOSE_ARGS[@]}" ps >&2 || true
  for service in "${services[@]}"; do
    echo "--- ${service} logs ---" >&2
    $DOCKER_COMPOSE "${COMPOSE_ARGS[@]}" logs --tail=80 "$service" >&2 || true
  done
  exit 1
}

profile_contains() {
  local profiles=",${1:-},"
  local profile="$2"
  case "$profiles" in
    *,"$profile",*) return 0 ;;
    *) return 1 ;;
  esac
}

append_profile_value() {
  local profiles="${1:-}"
  local profile="$2"
  if [ -z "$profiles" ]; then
    printf '%s' "$profile"
  else
    printf '%s,%s' "$profiles" "$profile"
  fi
}

remove_profile_value() {
  local profiles="${1:-}"
  local remove="$2"
  local result=""
  local old_ifs="$IFS"
  IFS=','
  for profile in $profiles; do
    IFS="$old_ifs"
    profile="$(printf '%s' "$profile" | xargs)"
    if [ -n "$profile" ] && [ "$profile" != "$remove" ]; then
      if [ -z "$result" ]; then
        result="$profile"
      else
        result="$result,$profile"
      fi
    fi
    IFS=','
  done
  IFS="$old_ifs"
  printf '%s' "$result"
}

ensure_config() {
  if [ ! -f config.env ]; then
    if [ -x ./install.sh ]; then
      ./install.sh
    elif [ -f config.env.sample ]; then
      cp config.env.sample config.env
      echo "Created config.env from config.env.sample"
    else
      echo "Error: config.env missing and config.env.sample not found" >&2
      exit 1
    fi
  fi

  if grep -q '^JWT_SECRET_KEY=CHANGE_ME$' config.env; then
    set_env_value JWT_SECRET_KEY "$(random_hex 32)"
  fi
  if grep -q '^MONGO_INITDB_ROOT_PASSWORD=CHANGE_ME$' config.env; then
    set_env_value MONGO_INITDB_ROOT_PASSWORD "$(random_hex 24)"
  fi
  if grep -q '^POSTGRES_PASSWORD=CHANGE_ME$' config.env; then
    set_env_value POSTGRES_PASSWORD "$(random_hex 24)"
  fi
  if grep -q '^CREDENTIAL_ENCRYPTION_KEY=$' config.env; then
    set_env_value CREDENTIAL_ENCRYPTION_KEY "$(credential_key)"
  fi
  if ! grep -q '^BREAKTEST_COMPOSE_PROJECT_NAME=' config.env; then
    set_env_value BREAKTEST_COMPOSE_PROJECT_NAME "breaktest"
  fi
  if grep -q '^HERMES_API_KEY=CHANGE_ME$' config.env || grep -q '^HERMES_API_KEY=$' config.env || ! grep -q '^HERMES_API_KEY=' config.env; then
    set_env_value HERMES_API_KEY "$(random_hex 32)"
  fi

  if [ ! -f version.env ] && ! grep -q '^BREAKTEST_VERSION=..*' config.env; then
    echo "Error: version.env not found and BREAKTEST_VERSION is not set in config.env." >&2
    echo "version.env ships with the bundle and pins the release version. Restore it (git checkout version.env) or re-download the bundle." >&2
    exit 1
  fi

  set -a
  if [ -f version.env ]; then
    # shellcheck disable=SC1091
    source version.env
  fi
  # shellcheck disable=SC1091
  source config.env
  set +a
  bt_apply_image_version_overrides config.env

  if grep -q '^BREAKTEST_VERSION=..*' config.env; then
    echo "Note: BREAKTEST_VERSION override in config.env is active: ${BREAKTEST_VERSION}"
  fi

  if bt_env_truthy AI_ASSISTANT_ENABLED "${AI_ASSISTANT_ENABLED:-false}"; then
    if ! profile_contains "${COMPOSE_PROFILES:-}" "ai-assistant"; then
      COMPOSE_PROFILES="$(append_profile_value "${COMPOSE_PROFILES:-}" "ai-assistant")"
      set_env_value COMPOSE_PROFILES "$COMPOSE_PROFILES"
    fi
  else
    if profile_contains "${COMPOSE_PROFILES:-}" "ai-assistant"; then
      COMPOSE_PROFILES="$(remove_profile_value "${COMPOSE_PROFILES:-}" "ai-assistant")"
      set_env_value COMPOSE_PROFILES "$COMPOSE_PROFILES"
    fi
    # Provider credentials moved into the Hermes Docker volume, and the block
    # that used to auto-enable on their presence is gone. An upgraded install
    # would otherwise just stop running the assistant with no explanation.
    if grep -qE '^[[:space:]]*(ANTHROPIC_API_KEY|OPENAI_REFRESH_TOKEN|OPENAI_ACCESS_TOKEN|AI_MODEL)=..*' config.env 2>/dev/null; then
      echo "Note: config.env still has legacy AI provider settings (ANTHROPIC_API_KEY / OPENAI_* / AI_MODEL)."
      echo "      These are no longer read. Run ./ai-setup.sh to choose a provider and re-enable the assistant."
    fi
  fi

  bt_configure_grafana_profile config.env

  mkdir -p backups
}

prepare_postgres_data_path() {
  local data_path="${POSTGRES_DATA_PATH:-}"
  if [ -z "$data_path" ]; then
    return
  fi
  case "$data_path" in
    /*) ;;
    *)
      echo "Error: POSTGRES_DATA_PATH must be an absolute host path: $data_path" >&2
      exit 1
      ;;
  esac
  if [ -e "$data_path" ] && [ ! -d "$data_path" ]; then
    echo "Error: POSTGRES_DATA_PATH is not a directory: $data_path" >&2
    exit 1
  fi
  if ! mkdir -p -- "$data_path"; then
    echo "Error: could not create POSTGRES_DATA_PATH: $data_path" >&2
    exit 1
  fi
  echo "TimescaleDB data: bind mount $data_path"
}

ensure_config
bt_configure_public_runtime config.env
prepare_postgres_data_path
check_free_disk_space

PROJECT_NAME="${PROJECT_NAME:-${BREAKTEST_COMPOSE_PROJECT_NAME:-breaktest}}"
LOAD_GENERATOR_CONTAINER_NETWORK="${PROJECT_NAME}_breaktest-network"
export LOAD_GENERATOR_CONTAINER_NETWORK
COMPOSE_ARGS=(-f docker-compose.yaml -p "$PROJECT_NAME")
if bt_uses_https_compose; then
  if [ ! -f docker-compose.https.yaml ]; then
    echo "Error: docker-compose.https.yaml is required when BREAKTEST_TLS_MODE=letsencrypt" >&2
    exit 1
  fi
  COMPOSE_ARGS+=(-f docker-compose.https.yaml)
fi
if [ -f version.env ]; then
  # config.env comes last so its values override the bundle-pinned version.env
  COMPOSE_ARGS=(--env-file version.env --env-file config.env "${COMPOSE_ARGS[@]}")
else
  COMPOSE_ARGS=(--env-file config.env "${COMPOSE_ARGS[@]}")
fi

if [ "$PULL_IMAGES" = true ]; then
  $DOCKER_COMPOSE "${COMPOSE_ARGS[@]}" pull
  check_free_disk_space
fi

bt_prepare_loadgenerator
if profile_contains "${COMPOSE_PROFILES:-}" "loadgenerator" && [ "${LOAD_GENERATOR_RUN_MODE:-container}" = "container" ]; then
  COMPOSE_ARGS+=(-f docker-compose.loadgenerator-container-mode.yaml)
fi

UP_ARGS=(up -d)
if [ "$PULL_IMAGES" = false ]; then
  UP_ARGS+=(--pull never)
fi

if [ -n "$RESTART_SERVICE" ]; then
  $DOCKER_COMPOSE "${COMPOSE_ARGS[@]}" "${UP_ARGS[@]}" --no-deps --force-recreate "$RESTART_SERVICE"
else
  $DOCKER_COMPOSE "${COMPOSE_ARGS[@]}" "${UP_ARGS[@]}"
fi

if [ -n "$RESTART_SERVICE" ]; then
  echo "Skipping full-stack health wait for service restart: $RESTART_SERVICE"
else
  wait_for_required_services
fi

if [ "$SHOW_LOGS" = true ]; then
  $DOCKER_COMPOSE "${COMPOSE_ARGS[@]}" logs -f
else
  $DOCKER_COMPOSE "${COMPOSE_ARGS[@]}" ps
  if profile_contains "${COMPOSE_PROFILES:-}" "grafana"; then
    echo "Grafana is available at ${BREAKTEST_PUBLIC_URL%/}/grafana"
  fi
fi
