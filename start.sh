#!/usr/bin/env bash
set -euo pipefail

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

env_truthy() {
  case "$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
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

  if grep -q '^BREAKTEST_VERSION=..*' config.env; then
    echo "Note: BREAKTEST_VERSION override in config.env is active: ${BREAKTEST_VERSION}"
  fi

  if [ -n "${ANTHROPIC_API_KEY:-}" ] || { [ -n "${OPENAI_ACCESS_TOKEN:-}" ] && [ -n "${OPENAI_REFRESH_TOKEN:-}" ]; }; then
    if ! env_truthy "${AI_ASSISTANT_ENABLED:-false}"; then
      set_env_value AI_ASSISTANT_ENABLED "true"
      AI_ASSISTANT_ENABLED="true"
    fi
    if ! profile_contains "${COMPOSE_PROFILES:-}" "ai-assistant"; then
      COMPOSE_PROFILES="$(append_profile_value "${COMPOSE_PROFILES:-}" "ai-assistant")"
      set_env_value COMPOSE_PROFILES "$COMPOSE_PROFILES"
    fi
  else
    if env_truthy "${AI_ASSISTANT_ENABLED:-false}"; then
      set_env_value AI_ASSISTANT_ENABLED "false"
      AI_ASSISTANT_ENABLED="false"
    fi
    if profile_contains "${COMPOSE_PROFILES:-}" "ai-assistant"; then
      COMPOSE_PROFILES="$(remove_profile_value "${COMPOSE_PROFILES:-}" "ai-assistant")"
      set_env_value COMPOSE_PROFILES "$COMPOSE_PROFILES"
      echo "Warning: AI assistant profile disabled because no AI provider credentials are configured."
    fi
  fi

  mkdir -p backups
  if profile_contains "${COMPOSE_PROFILES:-}" "loadgenerator"; then
    mkdir -p loadgenerator/files
  fi
  if [ -z "${BREAKTEST_LICENSE_KEY:-}" ]; then
    echo "Warning: BREAKTEST_LICENSE_KEY is empty. BreakTest will start, but licensed actions will be blocked until a license key is configured."
  fi
}

ensure_config

PROJECT_NAME="${PROJECT_NAME:-${BREAKTEST_COMPOSE_PROJECT_NAME:-breaktest}}"
COMPOSE_ARGS=(-f docker-compose.yaml -p "$PROJECT_NAME")
if [ -f version.env ]; then
  # config.env comes last so its values override the bundle-pinned version.env
  COMPOSE_ARGS=(--env-file version.env --env-file config.env "${COMPOSE_ARGS[@]}")
else
  COMPOSE_ARGS=(--env-file config.env "${COMPOSE_ARGS[@]}")
fi

if [ "$PULL_IMAGES" = true ]; then
  $DOCKER_COMPOSE "${COMPOSE_ARGS[@]}" pull
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

if [ "$SHOW_LOGS" = true ]; then
  $DOCKER_COMPOSE "${COMPOSE_ARGS[@]}" logs -f
else
  $DOCKER_COMPOSE "${COMPOSE_ARGS[@]}" ps
fi
