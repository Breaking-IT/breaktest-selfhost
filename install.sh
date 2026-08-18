#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=config-helpers.sh
source "$(dirname "$0")/config-helpers.sh"

CONFIG_FILE="config.env"
SAMPLE_FILE="config.env.sample"

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value
  printf '%s' "${value:-$default}"
}

prompt_yes_no() {
  local prompt="$1"
  local default="$2"
  local value
  local suffix
  if [ "$default" = "yes" ]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi

  while true; do
    read -r -p "$prompt [$suffix]: " value
    value="${value:-$default}"
    case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer yes or no." ;;
    esac
  done
}

prompt_tls_mode() {
  local value
  while true; do
    value=$(prompt_default "TLS mode (disabled, letsencrypt, or external)" "disabled")
    value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
    case "$value" in
      disabled|letsencrypt|external) printf '%s' "$value"; return ;;
      *) echo "Please enter disabled, letsencrypt, or external." >&2 ;;
    esac
  done
}

random_hex() {
  openssl rand -hex "${1:-32}" 2>/dev/null || {
    echo "Error: openssl is required to generate secrets" >&2
    exit 1
  }
}

credential_key() {
  openssl rand -base64 32 | tr '+/' '-_'
}

detect_timezone() {
  local candidate="${TZ:-}"
  local localtime_target=""

  candidate="${candidate#:}"
  case "$candidate" in
    /*|*" "*|*":"*) candidate="" ;;
  esac
  if [ -z "$candidate" ] && [ -r /etc/timezone ]; then
    IFS= read -r candidate < /etc/timezone || true
  fi

  if [ -z "$candidate" ] && [ -L /etc/localtime ]; then
    localtime_target=$(readlink /etc/localtime 2>/dev/null || true)
    case "$localtime_target" in
      */zoneinfo/*) candidate="${localtime_target#*/zoneinfo/}" ;;
    esac
  fi

  if [ -z "$candidate" ] && command -v timedatectl >/dev/null 2>&1; then
    candidate=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
  fi

  if [ -z "$candidate" ] && command -v systemsetup >/dev/null 2>&1; then
    candidate=$(systemsetup -gettimezone 2>/dev/null | sed 's/^Time Zone: //' || true)
  fi

  candidate=$(printf '%s' "$candidate" | tr -d '\r\n')
  case "$candidate" in
    ""|"n/a"|"localtime"|/*|*" "*|*":"*) candidate="UTC" ;;
  esac
  printf '%s' "$candidate"
}

append_profile() {
  local profile="$1"
  if [ -z "$compose_profiles" ]; then
    compose_profiles="$profile"
  else
    compose_profiles="$compose_profiles,$profile"
  fi
}

if [ ! -f "$SAMPLE_FILE" ]; then
  echo "Error: $SAMPLE_FILE not found. Run this script from the self-host bundle directory." >&2
  exit 1
fi

if [ -f "$CONFIG_FILE" ]; then
  if ! prompt_yes_no "$CONFIG_FILE already exists. Overwrite it" "no"; then
    echo "Keeping existing $CONFIG_FILE"
    exit 0
  fi
fi

echo "BreakTest self-host installer"
echo

registry="breakingit"
compose_project_name="breaktest"
tls_mode=$(prompt_tls_mode)

if [ "$tls_mode" = "letsencrypt" ]; then
  email=$(prompt_default "Let's Encrypt email" "admin@example.com")
else
  email="admin@example.com"
fi

lg_run_mode="container"
if prompt_yes_no "Start a local load generator in this stack" "yes"; then
  compose_profiles=""
  append_profile "loadgenerator"
  lg_location=$(prompt_default "Local load generator location label" "Local")
  lg_public="false"
  lg_customer_name="Default"
  lg_supports_sm="false"
  if prompt_yes_no "Allow this local load generator to run synthetic monitoring" "yes"; then
    lg_supports_sm="true"
  fi
  echo
  lg_run_mode=$(bt_choose_loadgenerator_run_mode)
  echo
else
  compose_profiles=""
  lg_location="Local"
  lg_public="false"
  lg_customer_name="Default"
  lg_supports_sm="false"
fi

ai_assistant_enabled="false"
anthropic_api_key=""
openai_access_token=""
openai_refresh_token=""
openai_token_expires=""
openai_email=""
ai_model=""
hermes_api_key=$(random_hex 32)

http_port=$(prompt_default "HTTP port" "80")
https_port=""
if [ "$tls_mode" = "letsencrypt" ]; then
  https_port=$(prompt_default "HTTPS port" "443")
fi
case "$tls_mode" in
  disabled)
    default_public_url="http://localhost"
    if [ "$http_port" != "80" ]; then
      default_public_url="${default_public_url}:$http_port"
    fi
    ;;
  letsencrypt)
    default_public_url="https://localhost"
    if [ "$https_port" != "443" ]; then
      default_public_url="${default_public_url}:$https_port"
    fi
    ;;
  external) default_public_url="https://localhost" ;;
esac
public_url=$(prompt_default "Public URL users will use to access BreakTest" "$default_public_url")
bt_parse_public_url "$public_url"
public_url="$BT_PUBLIC_URL"
case "$tls_mode:$BT_PUBLIC_SCHEME" in
  disabled:http|letsencrypt:https|external:https) ;;
  disabled:*) echo "Error: disabled TLS mode requires an http:// public URL" >&2; exit 1 ;;
  letsencrypt:*) echo "Error: letsencrypt TLS mode requires an https:// public URL" >&2; exit 1 ;;
  external:*) echo "Error: external TLS mode requires an https:// public URL" >&2; exit 1 ;;
esac
detected_timezone=$(detect_timezone)
timezone=$(prompt_default "Timezone" "$detected_timezone")
postgres_data_path=""

cat > "$CONFIG_FILE" <<EOF
# BreakTest self-host runtime configuration
# Generated by install.sh
# The image version is pinned in version.env, which ships with this bundle.
# Set BREAKTEST_VERSION here only to override it, for example for a rollback.

BREAKTEST_IMAGE_REGISTRY=$registry
BREAKTEST_COMPOSE_PROJECT_NAME=$compose_project_name

BREAKTEST_PUBLIC_URL=$public_url
BREAKTEST_TLS_MODE=$tls_mode
LETS_ENCRYPT_EMAIL=$email
HTTP_PORT=$http_port
HTTPS_PORT=$https_port

TZ=$timezone
LOG_LEVEL=INFO
BACKUP_PATH=./backups

AI_ASSISTANT_ENABLED=$ai_assistant_enabled
HERMES_URL=http://ai-assistant:8080
HERMES_API_KEY=$hermes_api_key
ANTHROPIC_API_KEY=$anthropic_api_key
OPENAI_ACCESS_TOKEN=$openai_access_token
OPENAI_REFRESH_TOKEN=$openai_refresh_token
OPENAI_TOKEN_EXPIRES=$openai_token_expires
OPENAI_EMAIL=$openai_email
AI_MODEL=$ai_model

JWT_SECRET_KEY=$(random_hex 32)
CREDENTIAL_ENCRYPTION_KEY=$(credential_key)
MONGO_INITDB_ROOT_USERNAME=admin
MONGO_INITDB_ROOT_PASSWORD=$(random_hex 24)
POSTGRES_USER=admin
POSTGRES_PASSWORD=$(random_hex 24)

MONGO_DATABASE=breakingit

POSTGRES_DATA_PATH=$postgres_data_path
POSTGRES_MAX_CONNECTIONS=100
POSTGRES_TIMEZONE=$timezone
POSTGRES_FSYNC=off
POSTGRES_SYNCHRONOUS_COMMIT=off
POSTGRES_FULL_PAGE_WRITES=on
POSTGRES_WORK_MEM=64MB

PG_PROXY_MAX_CONNS=100
PG_PROXY_MAX_INFLIGHT=512
PG_PROXY_COPY_TIMEOUT_SEC=60
PG_PROXY_MAX_BODY_BYTES=67108864

LOAD_GENERATOR_TOKEN=local-token
LOAD_GENERATOR_NAME=loadgenerator
LOAD_GENERATOR_LOCATION=$lg_location
# Test execution mode: container (preferred, isolated JMeter/K6 workloads) or
# process. start.sh verifies the Docker socket mount after pulling the image
# and falls back to process mode when container mode is not usable.
LOAD_GENERATOR_RUN_MODE=$lg_run_mode
# Optional limit for the load generator and each child test container.
# LOAD_GENERATOR_CPU_LIMIT=4.0
# LOAD_GENERATOR_MEMORY_LIMIT=4096m
LOAD_GENERATOR_PUBLIC=$lg_public
LOAD_GENERATOR_SUPPORTS_SYNTHETIC_MONITORING=$lg_supports_sm
LOAD_GENERATOR_CUSTOMER_NAME=$lg_customer_name
COMPOSE_PROFILES=$compose_profiles

AWS_ACCESS_KEY=
AWS_SECRET_KEY=
AWS_SES_REGION=eu-west-1
AZURE_SUBSCRIPTION_ID=
AZURE_TENANT_ID=
AZURE_CLIENT_ID=
AZURE_CLIENT_SECRET=
AZURE_SSH_PUBLIC_KEY=
AZURE_LOADGENERATOR_IMAGE=
AZURE_CONTAINER_REGISTRY_SERVER=
AZURE_CONTAINER_REGISTRY_USERNAME=
AZURE_CONTAINER_REGISTRY_PASSWORD=
AZURE_DOCKERHUB_USERNAME=
AZURE_DOCKERHUB_TOKEN=
DOP_API_TOKEN=
DOP_SSH_KEY_NAME=
GCP_PROJECT_ID=
GCP_SERVICE_ACCOUNT_KEY=
EOF

mkdir -p backups
case ",$compose_profiles," in
  *,loadgenerator,*) 
  mkdir -p loadgenerator/files
  ;;
esac

echo
echo "Created $CONFIG_FILE"
if [ "$tls_mode" = "letsencrypt" ]; then
  echo "Make sure DNS for $BT_PUBLIC_HOST points to this server and ports $http_port/$https_port are reachable."
elif [ "$tls_mode" = "external" ]; then
  echo "Configure the upstream TLS proxy for $BT_PUBLIC_HOST to forward to this server on port $http_port."
fi
case ",$compose_profiles," in
  *,loadgenerator,*)
    echo "Local load generator run mode: $lg_run_mode"
    ;;
esac
echo "Start BreakTest with: ./start.sh"
