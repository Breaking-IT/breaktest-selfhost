#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME=""

usage() {
  cat <<'EOF'
Usage: ./stop.sh [--project-name name]

  --project-name name
                Docker Compose project name to stop
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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

ENV_ARGS=()
if [ -f config.env ]; then
  ENV_ARGS=(--env-file config.env)
  set -a
  # shellcheck disable=SC1091
  source config.env
  set +a
fi

PROJECT_NAME="${PROJECT_NAME:-${BREAKTEST_COMPOSE_PROJECT_NAME:-breaktest}}"

$DOCKER_COMPOSE "${ENV_ARGS[@]}" -f docker-compose.yaml -p "$PROJECT_NAME" down --remove-orphans
