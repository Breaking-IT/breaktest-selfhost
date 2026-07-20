#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME=""
UPDATE_BUNDLE=true

usage() {
  cat <<'EOF'
Usage: ./upgrade.sh [--project-name name] [--no-bundle-update]

  --project-name name
                Docker Compose project name to upgrade
  --no-bundle-update
                Skip updating the bundle itself (git pull); only pull and
                restart images at the currently pinned version

Upgrades update the bundle first (compose file, scripts, pinned version in
version.env), then pull the matching images and restart services.
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
    --no-bundle-update)
      UPDATE_BUNDLE=false
      shift
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

if [ ! -f config.env ]; then
  echo "config.env not found. Run ./start.sh first or copy config.env.sample to config.env." >&2
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker-compose"
else
  echo "Error: neither 'docker compose' nor 'docker-compose' found" >&2
  exit 1
fi

pinned_version() {
  if [ -f version.env ]; then
    sed -n 's/^BREAKTEST_VERSION=//p' version.env | head -n 1
  fi
}

current_version="$(pinned_version)"

if [ "$UPDATE_BUNDLE" = true ]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Updating bundle..."
    git pull --ff-only
  else
    echo "Warning: not a git checkout; skipping bundle update. Download the latest bundle to update the compose file and pinned version."
  fi
fi

target_version="$(pinned_version)"

if [ -z "$target_version" ] && ! grep -q '^BREAKTEST_VERSION=..*' config.env; then
  echo "Error: version.env not found and BREAKTEST_VERSION is not set in config.env." >&2
  exit 1
fi

ENV_ARGS=()
if [ -f version.env ]; then
  ENV_ARGS+=(--env-file version.env)
fi
ENV_ARGS+=(--env-file config.env)

set -a
if [ -f version.env ]; then
  # shellcheck disable=SC1091
  source version.env
fi
# shellcheck disable=SC1091
source config.env
set +a

if grep -q '^BREAKTEST_VERSION=..*' config.env; then
  echo "Warning: BREAKTEST_VERSION override in config.env is active: ${BREAKTEST_VERSION}"
  echo "The bundle pins ${target_version:-unknown}; remove the override from config.env to follow bundle releases."
fi

if [ -n "$current_version" ] && [ -n "$target_version" ]; then
  if [ "$current_version" = "$target_version" ]; then
    echo "BreakTest version: $target_version (no version change)"
  else
    echo "Upgrading BreakTest: $current_version -> $target_version"
  fi
fi

PROJECT_NAME="${PROJECT_NAME:-${BREAKTEST_COMPOSE_PROJECT_NAME:-breaktest}}"

$DOCKER_COMPOSE "${ENV_ARGS[@]}" -f docker-compose.yaml -p "$PROJECT_NAME" pull
$DOCKER_COMPOSE "${ENV_ARGS[@]}" -f docker-compose.yaml -p "$PROJECT_NAME" up -d --remove-orphans
$DOCKER_COMPOSE "${ENV_ARGS[@]}" -f docker-compose.yaml -p "$PROJECT_NAME" ps
