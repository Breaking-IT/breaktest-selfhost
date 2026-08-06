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

collect_project_images() {
  local project_name="$1"
  local container_ids

  container_ids=$(docker ps -aq --filter "label=com.docker.compose.project=${project_name}")
  if [ -z "$container_ids" ]; then
    return 0
  fi

  # Config.Image is the configured tag; Image is the immutable image ID.
  docker inspect --format '{{.Config.Image}}|{{.Image}}' $container_ids | sort -u
}

cleanup_superseded_project_images() {
  local project_name="$1"
  local old_images="$2"
  local current_images current_ids all_container_ids referenced_ids
  local image_ref image_id resolved_id removal_target
  local removed_count=0
  local skipped_count=0

  if [ -z "$old_images" ]; then
    echo "No previous project images found; skipping image cleanup."
    return 0
  fi

  current_images=$(collect_project_images "$project_name")
  current_ids=$(printf '%s\n' "$current_images" | awk -F'|' 'NF >= 2 { print $2 }')
  all_container_ids=$(docker ps -aq)
  referenced_ids=""
  if [ -n "$all_container_ids" ]; then
    referenced_ids=$(docker inspect --format '{{.Image}}' $all_container_ids | sort -u)
  fi

  while IFS='|' read -r image_ref image_id; do
    if [ -z "$image_ref" ] || [ -z "$image_id" ]; then
      continue
    fi

    if printf '%s\n' "$current_ids" | grep -Fqx -- "$image_id"; then
      continue
    fi

    if printf '%s\n' "$referenced_ids" | grep -Fqx -- "$image_id"; then
      echo "Kept $image_ref ($image_id); it is referenced by another container."
      skipped_count=$((skipped_count + 1))
      continue
    fi

    # Versioned tags still resolve to the old image. Mutable tags may already
    # point to the replacement, in which case the immutable old ID is removed.
    resolved_id=$(docker image inspect "$image_ref" --format '{{.Id}}' 2>/dev/null || true)
    if [ "$resolved_id" = "$image_id" ]; then
      removal_target="$image_ref"
    else
      removal_target="$image_id"
    fi

    if docker image rm "$removal_target" >/dev/null; then
      echo "Removed superseded image $image_ref ($image_id)"
      removed_count=$((removed_count + 1))
    else
      echo "Kept $image_ref ($image_id); it is still referenced by another tag."
      skipped_count=$((skipped_count + 1))
    fi
  done <<< "$old_images"

  echo "Superseded image cleanup: ${removed_count} removed, ${skipped_count} kept."
}

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

prepare_postgres_data_path

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

COMPOSE_FILES=(-f docker-compose.yaml)
case "$(printf '%s' "${ENABLE_SSL:-false}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on)
    if [ ! -f docker-compose.https.yaml ]; then
      echo "Error: docker-compose.https.yaml is required when ENABLE_SSL=true" >&2
      exit 1
    fi
    COMPOSE_FILES+=(-f docker-compose.https.yaml)
    ;;
esac

OLD_PROJECT_IMAGES=$(collect_project_images "$PROJECT_NAME")

$DOCKER_COMPOSE "${ENV_ARGS[@]}" "${COMPOSE_FILES[@]}" -p "$PROJECT_NAME" pull
$DOCKER_COMPOSE "${ENV_ARGS[@]}" "${COMPOSE_FILES[@]}" -p "$PROJECT_NAME" up -d --remove-orphans
$DOCKER_COMPOSE "${ENV_ARGS[@]}" "${COMPOSE_FILES[@]}" -p "$PROJECT_NAME" ps

# Retain the old images if pull/start fails so operators can roll back. Once
# the replacement stack is running, remove only images superseded by this
# Compose project; Docker safely refuses images used by other containers.
cleanup_superseded_project_images "$PROJECT_NAME" "$OLD_PROJECT_IMAGES"
