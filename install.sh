#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=config-helpers.sh
source "$(dirname "$0")/config-helpers.sh"

CONFIG_FILE="config.env"
SAMPLE_FILE="config.env.sample"

rule() {
  printf '  %s\n' '----------------------------------------'
}

indent_echo() {
  printf '  %s\n' "$1"
}

section() {
  echo
  indent_echo "$1"
  rule
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value=""
  printf '  %s [%s]: ' "$prompt" "$default" >&2
  read -r value || true
  printf '%s' "${value:-$default}"
}

prompt_yes_no() {
  local prompt="$1"
  local default="$2"
  local value=""
  local suffix
  if [ "$default" = "yes" ]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi

  while true; do
    printf '  %s [%s]: ' "$prompt" "$suffix" >&2
    read -r value || true
    value="${value:-$default}"
    case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) indent_echo "Please answer yes or no." ;;
    esac
  done
}

prompt_port() {
  local prompt="$1"
  local default="$2"
  local value=""
  while true; do
    value=$(prompt_default "$prompt" "$default")
    case "$value" in
      ''|*[!0-9]*)
        indent_echo "Enter a port number between 1 and 65535."
        continue
        ;;
    esac
    if [ "$value" -ge 1 ] && [ "$value" -le 65535 ]; then
      printf '%s' "$value"
      return
    fi
    indent_echo "Enter a port number between 1 and 65535."
  done
}

prompt_email() {
  local prompt="$1"
  local default="$2"
  local value=""
  while true; do
    value=$(prompt_default "$prompt" "$default")
    case "$value" in
      ?*@?*.?*)
        printf '%s' "$value"
        return
        ;;
    esac
    indent_echo "Enter an email address, for example admin@example.com."
  done
}

origin_for_host() {
  local scheme="$1"
  local host="$2"
  local port="$3"
  local default_port="$4"
  if [ -n "$port" ] && [ "$port" != "$default_port" ]; then
    printf '%s://%s:%s' "$scheme" "$host" "$port"
  else
    printf '%s://%s' "$scheme" "$host"
  fi
}

normalize_host_or_url() {
  local raw="$1"
  local scheme="$2"
  local port="$3"
  local default_port="$4"
  raw=$(printf '%s' "$raw" | tr -d '\r\n ')
  case "$raw" in
    http://*|https://*)
      printf '%s' "${raw%/}"
      ;;
    *:*)
      printf '%s://%s' "$scheme" "$raw"
      ;;
    *)
      origin_for_host "$scheme" "$raw" "$port" "$default_port"
      ;;
  esac
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

accept_selected_public_url() {
  local selected="$1"
  local tls_mode="$2"

  if ! bt_parse_public_url "$selected"; then
    return 1
  fi
  case "$tls_mode:$BT_PUBLIC_SCHEME" in
    disabled:http|letsencrypt:https|external:https) ;;
    disabled:*)
      indent_echo "HTTP-only installs require an http:// public URL."
      return 1
      ;;
    letsencrypt:*|external:*)
      indent_echo "HTTPS installs require an https:// public URL."
      return 1
      ;;
  esac
  if [ "$tls_mode" = "letsencrypt" ] && bt_host_is_letsencrypt_unsuitable "$BT_PUBLIC_HOST"; then
    indent_echo "Let's Encrypt cannot issue a certificate for ${BT_PUBLIC_HOST}."
    indent_echo "Enter a public DNS hostname that points at this server."
    return 1
  fi
  BT_SELECTED_PUBLIC_URL="$BT_PUBLIC_URL"
}

prompt_public_url() {
  local scheme="$1"
  local listen_port="$2"
  local default_port="$3"
  local tls_mode="$4"
  local hosts=()
  local host origin choice index custom_index selected=""

  while IFS= read -r host; do
    [ -n "$host" ] || continue
    hosts+=("$host")
  done <<EOF
$(bt_detect_local_hosts </dev/null)
EOF

  if [ "${#hosts[@]}" -eq 0 ]; then
    hosts=("localhost")
  fi

  if [ "$tls_mode" = "letsencrypt" ]; then
    local suitable=()
    for host in "${hosts[@]}"; do
      bt_host_is_letsencrypt_unsuitable "$host" && continue
      suitable+=("$host")
    done
    hosts=()
    if [ "${#suitable[@]}" -gt 0 ]; then
      hosts=("${suitable[@]}")
    fi
  fi

  indent_echo "Users and remote load generators will reach BreakTest here."
  if [ "$tls_mode" = "letsencrypt" ] && [ "${#hosts[@]}" -eq 0 ]; then
    indent_echo "Let's Encrypt needs a public DNS hostname that points at this server."
    echo
    while true; do
      printf '  Public hostname or URL: ' >&2
      read -r host || true
      host=$(printf '%s' "$host" | tr -d '\r\n ')
      if [ -z "$host" ]; then
        indent_echo "Enter a DNS hostname, for example breaktest.example.com."
        continue
      fi
      selected=$(normalize_host_or_url "$host" "$scheme" "$listen_port" "$default_port")
      if accept_selected_public_url "$selected" "$tls_mode"; then
        return
      fi
    done
  fi

  indent_echo "Choose a detected address, or type a hostname or URL."
  echo
  index=1
  for host in "${hosts[@]}"; do
    origin=$(origin_for_host "$scheme" "$host" "$listen_port" "$default_port")
    printf '    %s) %s\n' "$index" "$origin"
    index=$((index + 1))
  done
  custom_index="$index"
  printf '    %s) Enter a different hostname or URL\n' "$custom_index"
  echo

  while true; do
    printf '  Select [1], or type a hostname: ' >&2
    read -r choice || true
    choice="${choice:-1}"
    case "$choice" in
      ''|*[!0-9]*)
        selected=$(normalize_host_or_url "$choice" "$scheme" "$listen_port" "$default_port")
        ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -lt "$custom_index" ]; then
          host="${hosts[$((choice - 1))]}"
          selected=$(origin_for_host "$scheme" "$host" "$listen_port" "$default_port")
        elif [ "$choice" -eq "$custom_index" ]; then
          printf '  Hostname or URL: ' >&2
          read -r host || true
          host=$(printf '%s' "$host" | tr -d '\r\n ')
          if [ -z "$host" ]; then
            indent_echo "Enter a hostname, IP address, or full URL."
            continue
          fi
          selected=$(normalize_host_or_url "$host" "$scheme" "$listen_port" "$default_port")
        else
          indent_echo "Choose a number between 1 and ${custom_index}, or type a hostname."
          continue
        fi
        ;;
    esac

    if accept_selected_public_url "$selected" "$tls_mode"; then
      return
    fi
  done
}

if [ ! -f "$SAMPLE_FILE" ]; then
  echo "Error: $SAMPLE_FILE not found. Run this script from the self-host bundle directory." >&2
  exit 1
fi

echo
indent_echo "BreakTest self-host installer"
rule
echo
indent_echo "This writes config.env and generates local database and JWT secrets."
indent_echo "Press Enter to keep the suggested value in [brackets]."

if [ -f "$CONFIG_FILE" ]; then
  echo
  indent_echo "$CONFIG_FILE already exists."
  if ! prompt_yes_no "Overwrite it" "no"; then
    indent_echo "Keeping existing $CONFIG_FILE"
    echo
    exit 0
  fi
fi

registry="breakingit"
compose_project_name="breaktest"
compose_profiles=""
append_profile "loadgenerator"
lg_location="Local"
lg_public="false"
lg_customer_name="Default"
lg_supports_sm="true"

ai_assistant_enabled="false"
hermes_api_key=$(random_hex 32)

section "1/3  Network"

http_port=$(prompt_port "HTTP port" "80")
https_port=""
email="admin@example.com"
tls_mode="disabled"
while true; do
  tls_mode_input=$(prompt_default "Enable HTTPS / TLS (disabled, letsencrypt, or external)" "disabled")
  tls_mode_normalized=$(printf '%s' "$tls_mode_input" | tr '[:upper:]' '[:lower:]')
  case "$tls_mode_normalized" in
    y|yes|letsencrypt)
      tls_mode="letsencrypt"
      https_port=$(prompt_port "HTTPS port" "443")
      email=$(prompt_email "Let's Encrypt email" "admin@example.com")
      break
      ;;
    n|no|disabled|"")
      tls_mode="disabled"
      break
      ;;
    external)
      tls_mode="external"
      break
      ;;
    *)
      indent_echo "Please enter disabled, letsencrypt, or external."
      ;;
  esac
done

section "2/3  Public URL"

public_scheme="http"
public_listen_port="$http_port"
public_default_port="80"
if [ "$tls_mode" = "letsencrypt" ] || [ "$tls_mode" = "external" ]; then
  public_scheme="https"
  public_listen_port="${https_port:-443}"
  public_default_port="443"
fi
prompt_public_url "$public_scheme" "$public_listen_port" "$public_default_port" "$tls_mode"
public_url="$BT_SELECTED_PUBLIC_URL"

section "3/3  Timezone"

detected_timezone=$(detect_timezone)
indent_echo "Used for service logs, PostgreSQL, and scheduled maintenance."
timezone=$(prompt_default "Timezone" "$detected_timezone")
postgres_data_path=""

echo
indent_echo "Configuring the local load generator..."
lg_run_mode=$(bt_choose_loadgenerator_run_mode)

cat > "$CONFIG_FILE" <<EOF
# BreakTest self-host runtime configuration
# Generated by install.sh
# Image versions are pinned in version.env, which ships with this bundle.
# Set BREAKTEST_VERSION here to override every image, for example for a rollback.

BREAKTEST_IMAGE_REGISTRY=$registry
BREAKTEST_COMPOSE_PROJECT_NAME=$compose_project_name

BREAKTEST_PUBLIC_URL=$public_url
# Optional name shown for this installation in the customer portal. When left
# empty, pairing uses the hostname from BREAKTEST_PUBLIC_URL.
BREAKTEST_INSTALLATION_NAME=
BREAKTEST_TLS_MODE=$tls_mode
LETS_ENCRYPT_EMAIL=$email
HTTP_PORT=$http_port
HTTPS_PORT=$https_port

TZ=$timezone
LOG_LEVEL=INFO
BACKUP_PATH=./backups
BREAKTEST_MIN_FREE_DISK_GB=2
BREAKTEST_STARTUP_HEALTH_TIMEOUT_SECONDS=300
LOCAL_BACKUP_RETENTION_COUNT=2
HETZNER_STORAGE_ENABLED=false
BACKUP_INSTALLATION_NAME=
HETZNER_STORAGE_HOST=
HETZNER_STORAGE_USER=
HETZNER_STORAGE_PATH=backups
HETZNER_STORAGE_SSH_PORT=23
HETZNER_STORAGE_SSH_KEY=

GRAFANA_ENABLED=false
GRAFANA_ADMIN_PASSWORD=
# Comma-separated IP/CIDR ranges allowed to access /grafana through Traefik.
# Default is localhost only. Add your public admin IP, e.g. 203.0.113.10/32.
GRAFANA_IP_ALLOWLIST="127.0.0.1/32,::1/128"
GRAFANA_MONITORING_DB_USER=graf_breaktest_monitoring_ro
GRAFANA_MONITORING_DB_PASSWORD=
# Required when Grafana is enabled behind an external TLS proxy.
TRAEFIK_TRUSTED_PROXY_IPS=

AI_ASSISTANT_ENABLED=$ai_assistant_enabled
HERMES_URL=http://ai-assistant:8080
HERMES_API_KEY=$hermes_api_key

JWT_SECRET_KEY=$(random_hex 32)
CREDENTIAL_ENCRYPTION_KEY=$(credential_key)
MONGO_INITDB_ROOT_USERNAME=admin
MONGO_INITDB_ROOT_PASSWORD=$(random_hex 24)
POSTGRES_USER=admin
POSTGRES_PASSWORD=$(random_hex 24)

MONGO_DATABASE=breakingit

POSTGRES_DATA_PATH=$postgres_data_path
POSTGRES_MAX_CONNECTIONS=100
POSTGRES_MAX_WORKER_PROCESSES=64
POSTGRES_MAX_PARALLEL_WORKERS=16
POSTGRES_MAX_BG_WORKERS=32
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
bt_configure_loadgenerator_identity "$CONFIG_FILE"
bt_prepare_loadgenerator_files_directory loadgenerator/files

echo
indent_echo "Created $CONFIG_FILE"
rule
indent_echo "Public URL : $public_url"
indent_echo "TLS        : $tls_mode"
indent_echo "HTTP port  : $http_port"
if [ -n "$https_port" ]; then
  indent_echo "HTTPS port : $https_port"
fi
indent_echo "Timezone   : $timezone"
indent_echo "Load gen   : $lg_run_mode mode, synthetic monitoring enabled"
if [ "$tls_mode" = "letsencrypt" ]; then
  echo
  indent_echo "Make sure DNS for $BT_PUBLIC_HOST points to this server"
  indent_echo "and ports $http_port/$https_port are reachable."
elif [ "$tls_mode" = "external" ]; then
  echo
  indent_echo "Configure the upstream TLS proxy for $BT_PUBLIC_HOST"
  indent_echo "to forward to this server on port $http_port."
fi
echo
indent_echo "Start BreakTest with:  ./start.sh"
echo
