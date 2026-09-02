#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=config-helpers.sh
source "$SCRIPT_DIR/config-helpers.sh"

if [ ! -f config.env ]; then
  echo "Error: config.env not found. Run ./install.sh or ./start.sh first." >&2
  exit 1
fi
if [ ! -f version.env ] && ! grep -q '^BREAKTEST_VERSION=..*' config.env; then
  echo "Error: version.env not found and BREAKTEST_VERSION is not set in config.env." >&2
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE=(docker-compose)
else
  echo "Error: neither 'docker compose' nor 'docker-compose' was found." >&2
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

PROJECT_NAME="${BREAKTEST_COMPOSE_PROJECT_NAME:-breaktest}"
COMPOSE_ARGS=(--env-file config.env -f docker-compose.yaml -p "$PROJECT_NAME" --profile ai-assistant)
if [ -f version.env ]; then
  COMPOSE_ARGS=(--env-file version.env "${COMPOSE_ARGS[@]}")
fi
COMPOSE=("${DOCKER_COMPOSE[@]}" "${COMPOSE_ARGS[@]}")

echo "Preparing the pinned BreakTest AI assistant image..."
"${COMPOSE[@]}" pull ai-assistant

WAS_RUNNING="$("${COMPOSE[@]}" ps -q ai-assistant 2>/dev/null || true)"
if [ -n "$WAS_RUNNING" ]; then
  echo "Stopping the AI assistant while its provider configuration is changed..."
  "${COMPOSE[@]}" stop ai-assistant
fi

echo
echo "Select an inference provider, authenticate when prompted, and choose a model."
echo "For an OpenAI subscription, choose OpenAI, then OpenAI Codex."
echo

if ! "${COMPOSE[@]}" run --rm --no-deps \
  -e AWS_EC2_METADATA_DISABLED=true \
  --entrypoint /bin/sh ai-assistant -c '
  set -eu
  config="$HERMES_HOME/config.yaml"
  auth="$HERMES_HOME/auth.json"
  config_backup="$HERMES_HOME/config.yaml.breaktest-setup-backup"
  auth_backup="$HERMES_HOME/auth.json.breaktest-setup-backup"
  had_config=false
  had_auth=false

  if [ -f "$config" ]; then
    cp -p "$config" "$config_backup"
    had_config=true
  fi
  if [ -f "$auth" ]; then
    cp -p "$auth" "$auth_backup"
    had_auth=true
  fi

  if hermes model --no-browser && python - "$config" <<'PY'
import sys
import yaml

try:
    data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
    model = data.get("model") if isinstance(data, dict) else {}
    valid = (
        isinstance(model, dict)
        and model.get("provider")
        and model.get("default")
        and not (model.get("provider") == "custom" and model.get("default") == "hermes-agent")
    )
except Exception:
    valid = False
raise SystemExit(0 if valid else 1)
PY
  then
    rm -f "$config_backup" "$auth_backup"
    exit 0
  else
    status=$?
  fi

  if [ "$had_config" = true ] && [ -f "$config_backup" ]; then
    mv "$config_backup" "$config"
  else
    rm -f "$config" "$config_backup"
  fi
  if [ "$had_auth" = true ] && [ -f "$auth_backup" ]; then
    mv "$auth_backup" "$auth"
  else
    rm -f "$auth" "$auth_backup"
  fi
  exit "$status"
'; then
  echo "AI setup was not completed; the previous Hermes configuration was restored." >&2
  if [ -n "$WAS_RUNNING" ]; then
    "${COMPOSE[@]}" up -d --no-deps ai-assistant >/dev/null
    echo "The existing AI assistant was started again." >&2
  fi
  exit 1
fi

CONFIG_BACKUP="config.env.bak.ai-setup.$(date +%s)"
cp -p config.env "$CONFIG_BACKUP"
chmod 600 config.env "$CONFIG_BACKUP"

# Provider credentials and model selection are owned by Hermes in its Docker
# volume. Remove legacy Selfhost fields so config.env contains no AI tokens.
for key in \
  OPENAI_CODEX_DEVICE_AUTH \
  OPENAI_ACCESS_TOKEN \
  OPENAI_REFRESH_TOKEN \
  OPENAI_TOKEN_EXPIRES \
  OPENAI_EMAIL \
  ANTHROPIC_API_KEY \
  AI_MODEL
do
  bt_remove_env_value config.env "$key"
  bt_remove_env_value "$CONFIG_BACKUP" "$key"
done
bt_set_env_value config.env AI_ASSISTANT_ENABLED true

if ! bt_profile_contains "${COMPOSE_PROFILES:-}" "ai-assistant"; then
  COMPOSE_PROFILES="$(bt_append_profile "${COMPOSE_PROFILES:-}" "ai-assistant")"
  bt_set_env_value config.env COMPOSE_PROFILES "$COMPOSE_PROFILES"
fi

echo
echo "AI provider setup completed. Starting BreakTest with the AI assistant enabled..."
./start.sh --no-pull
echo
echo "AI assistant setup is active. Re-run ./ai-setup.sh to change the provider, model, or login."
