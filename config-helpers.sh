#!/usr/bin/env bash

# Shared public URL and TLS configuration for the self-host lifecycle scripts.

bt_env_bool() {
  local name="$1"
  local value="${2:-}"
  case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on) printf '%s' "true" ;;
    0|false|no|n|off) printf '%s' "false" ;;
    *)
      echo "Error: $name must be a boolean value, got: $value" >&2
      return 1
      ;;
  esac
}

bt_env_truthy() {
  local name="$1"
  local normalized
  normalized=$(bt_env_bool "$name" "${2:-}") || return 1
  [ "$normalized" = "true" ]
}

bt_set_env_value() {
  local config_file="$1"
  local key="$2"
  local value="$3"
  local escaped
  escaped=$(printf '%s' "$value" | sed 's/[&|]/\\&/g')
  if grep -q "^${key}=" "$config_file"; then
    sed -i.bak "s|^${key}=.*|${key}=${escaped}|" "$config_file"
    rm -f "${config_file}.bak"
  else
    printf '%s=%s\n' "$key" "$value" >> "$config_file"
  fi
}

bt_remove_env_value() {
  local config_file="$1"
  local key="$2"
  if grep -q "^${key}=" "$config_file"; then
    sed -i.bak "/^${key}=/d" "$config_file"
    rm -f "${config_file}.bak"
  fi
}

bt_parse_public_url() {
  local public_url="${1%/}"
  local scheme rest authority remainder

  case "$public_url" in
    http://*) scheme="http"; rest="${public_url#http://}" ;;
    https://*) scheme="https"; rest="${public_url#https://}" ;;
    *)
      echo "Error: BREAKTEST_PUBLIC_URL must start with http:// or https://" >&2
      return 1
      ;;
  esac

  case "$rest" in
    *'?'*|*'#'*|*'@'*|*' '*)
      echo "Error: BREAKTEST_PUBLIC_URL must not contain credentials, spaces, a query, or a fragment" >&2
      return 1
      ;;
  esac
  authority="${rest%%/*}"
  remainder="${rest#"$authority"}"
  if [ -n "$remainder" ] && [ "$remainder" != "/" ]; then
    echo "Error: BREAKTEST_PUBLIC_URL must not contain a path" >&2
    return 1
  fi
  if [ -z "$authority" ]; then
    echo "Error: BREAKTEST_PUBLIC_URL must contain a hostname" >&2
    return 1
  fi

  case "$authority" in
    \[*\]*)
      BT_PUBLIC_HOST="${authority#\[}"
      BT_PUBLIC_HOST="${BT_PUBLIC_HOST%%\]*}"
      remainder="${authority#*\]}"
      case "$remainder" in
        "") BT_PUBLIC_PORT="" ;;
        :*) BT_PUBLIC_PORT="${remainder#:}" ;;
        *) echo "Error: BREAKTEST_PUBLIC_URL contains an invalid IPv6 authority" >&2; return 1 ;;
      esac
      ;;
    *)
      BT_PUBLIC_HOST="${authority%%:*}"
      if [ "$authority" = "$BT_PUBLIC_HOST" ]; then
        BT_PUBLIC_PORT=""
      else
        BT_PUBLIC_PORT="${authority#*:}"
      fi
      ;;
  esac

  if [ -z "$BT_PUBLIC_HOST" ]; then
    echo "Error: BREAKTEST_PUBLIC_URL must contain a hostname" >&2
    return 1
  fi
  if [ -n "$BT_PUBLIC_PORT" ]; then
    case "$BT_PUBLIC_PORT" in
      *[!0-9]*) echo "Error: BREAKTEST_PUBLIC_URL contains an invalid port" >&2; return 1 ;;
    esac
    if [ "$BT_PUBLIC_PORT" -lt 1 ] || [ "$BT_PUBLIC_PORT" -gt 65535 ]; then
      echo "Error: BREAKTEST_PUBLIC_URL port must be between 1 and 65535" >&2
      return 1
    fi
  fi

  BT_PUBLIC_SCHEME="$scheme"
  BT_PUBLIC_URL="${scheme}://${authority}"
}

bt_legacy_tls_mode() {
  local ssl_set=false https_set=false ssl_value=false https_value=false
  if [ "${ENABLE_SSL+x}" = "x" ] && [ -n "${ENABLE_SSL:-}" ]; then
    ssl_set=true
    ssl_value=$(bt_env_bool ENABLE_SSL "$ENABLE_SSL") || return 1
  fi
  if [ "${ENABLE_HTTPS+x}" = "x" ] && [ -n "${ENABLE_HTTPS:-}" ]; then
    https_set=true
    https_value=$(bt_env_bool ENABLE_HTTPS "$ENABLE_HTTPS") || return 1
  fi
  if [ "$ssl_set" = true ] && [ "$https_set" = true ] && [ "$ssl_value" != "$https_value" ]; then
    echo "Error: ENABLE_SSL and ENABLE_HTTPS conflict. Set BREAKTEST_PUBLIC_URL and BREAKTEST_TLS_MODE, then remove both legacy flags." >&2
    return 1
  fi
  if { [ "$ssl_set" = true ] && [ "$ssl_value" = true ]; } || { [ "$https_set" = true ] && [ "$https_value" = true ]; }; then
    printf '%s' "letsencrypt"
  else
    printf '%s' "disabled"
  fi
}

bt_default_public_url() {
  local tls_mode="$1"
  local host="${CONTROLLER_HOST:-localhost}"
  local scheme port default_port suffix=""

  case "$host" in
    http://*|https://*) printf '%s' "${host%/}"; return ;;
  esac
  case "$tls_mode" in
    letsencrypt)
      scheme="https"; port="${HTTPS_PORT:-443}"; default_port=443 ;;
    external)
      scheme="https"; port=""; default_port=443 ;;
    *)
      scheme="http"; port="${HTTP_PORT:-80}"; default_port=80 ;;
  esac
  if [ -n "$port" ] && [ "$port" != "$default_port" ]; then
    suffix=":$port"
  fi
  printf '%s://%s%s' "$scheme" "$host" "$suffix"
}

bt_configure_public_runtime() {
  local config_file="${1:-config.env}"
  local persist="${2:-true}"
  local tls_mode="${BREAKTEST_TLS_MODE:-}"
  local public_url="${BREAKTEST_PUBLIC_URL:-}"
  local legacy_present=false legacy_mode="" backup_file=""
  local configured_entrypoints="${TRAEFIK_ENTRYPOINTS:-}"
  local configured_tls="${TRAEFIK_TLS:-}"
  local configured_cert_resolver="${TRAEFIK_CERT_RESOLVER:-}"
  local configured_frontend_rule="${TRAEFIK_FRONTEND_RULE:-}"
  local configured_backend_rule="${TRAEFIK_BACKEND_RULE:-}"
  local configured_websocket_rule="${TRAEFIK_WEBSOCKET_RULE:-}"
  local configured_pg_proxy_rule="${TRAEFIK_PG_PROXY_RULE:-}"
  local generated_entrypoints generated_tls generated_cert_resolver
  local generated_frontend_rule generated_backend_rule
  local generated_websocket_rule generated_pg_proxy_rule
  local preserve_entrypoints=false preserve_tls=false preserve_cert_resolver=false
  local preserve_frontend_rule=false preserve_backend_rule=false
  local preserve_websocket_rule=false preserve_pg_proxy_rule=false
  local custom_traefik_keys=""

  if [ "${ENABLE_SSL+x}" = "x" ] || [ "${ENABLE_HTTPS+x}" = "x" ]; then
    legacy_present=true
    legacy_mode=$(bt_legacy_tls_mode) || return 1
  fi

  if [ -z "$tls_mode" ]; then
    if [ -n "$legacy_mode" ]; then
      tls_mode="$legacy_mode"
    elif [ -n "$public_url" ]; then
      case "$public_url" in
        https://*) tls_mode="external" ;;
        *) tls_mode="disabled" ;;
      esac
    else
      tls_mode="disabled"
    fi
  fi
  tls_mode=$(printf '%s' "$tls_mode" | tr '[:upper:]' '[:lower:]')
  case "$tls_mode" in
    disabled|letsencrypt|external) ;;
    *)
      echo "Error: BREAKTEST_TLS_MODE must be disabled, letsencrypt, or external; got: $tls_mode" >&2
      return 1
      ;;
  esac

  if [ -z "$public_url" ]; then
    public_url=$(bt_default_public_url "$tls_mode")
  fi
  bt_parse_public_url "$public_url" || return 1

  case "$tls_mode:$BT_PUBLIC_SCHEME" in
    disabled:http|letsencrypt:https|external:https) ;;
    disabled:*)
      echo "Error: BREAKTEST_TLS_MODE=disabled requires an http:// BREAKTEST_PUBLIC_URL; use external when an upstream proxy terminates HTTPS" >&2
      return 1
      ;;
    letsencrypt:*)
      echo "Error: BREAKTEST_TLS_MODE=letsencrypt requires an https:// BREAKTEST_PUBLIC_URL" >&2
      return 1
      ;;
    external:*)
      echo "Error: BREAKTEST_TLS_MODE=external requires an https:// BREAKTEST_PUBLIC_URL" >&2
      return 1
      ;;
  esac

  case "$tls_mode" in
    letsencrypt)
      generated_entrypoints="websecure"
      generated_tls="true"
      generated_cert_resolver="letsencrypt"
      ;;
    disabled|external)
      generated_entrypoints="web"
      generated_tls="false"
      generated_cert_resolver="letsencrypt"
      ;;
  esac

  if [ "$BT_PUBLIC_HOST" = "localhost" ]; then
    generated_frontend_rule='PathPrefix(`/`)'
    generated_backend_rule='PathPrefix(`/api`)'
    generated_websocket_rule='PathPrefix(`/ws`)'
    generated_pg_proxy_rule='PathPrefix(`/ingest`) || PathPrefix(`/upsert`)'
  else
    generated_frontend_rule="Host(\`$BT_PUBLIC_HOST\`) && (PathPrefix(\`/\`))"
    generated_backend_rule="Host(\`$BT_PUBLIC_HOST\`) && (PathPrefix(\`/api\`))"
    generated_websocket_rule="Host(\`$BT_PUBLIC_HOST\`) && (PathPrefix(\`/ws\`))"
    generated_pg_proxy_rule="Host(\`$BT_PUBLIC_HOST\`) && (PathPrefix(\`/ingest\`) || PathPrefix(\`/upsert\`))"
  fi

  if [ -n "$configured_entrypoints" ] && [ "$configured_entrypoints" != "$generated_entrypoints" ]; then
    preserve_entrypoints=true
    custom_traefik_keys="TRAEFIK_ENTRYPOINTS"
  fi
  if [ -n "$configured_tls" ] && [ "$configured_tls" != "$generated_tls" ]; then
    preserve_tls=true
    custom_traefik_keys="${custom_traefik_keys:+$custom_traefik_keys, }TRAEFIK_TLS"
  fi
  if [ -n "$configured_cert_resolver" ] && [ "$configured_cert_resolver" != "$generated_cert_resolver" ]; then
    preserve_cert_resolver=true
    custom_traefik_keys="${custom_traefik_keys:+$custom_traefik_keys, }TRAEFIK_CERT_RESOLVER"
  fi
  if [ -n "$configured_frontend_rule" ] && [ "$configured_frontend_rule" != "$generated_frontend_rule" ]; then
    preserve_frontend_rule=true
    custom_traefik_keys="${custom_traefik_keys:+$custom_traefik_keys, }TRAEFIK_FRONTEND_RULE"
  fi
  if [ -n "$configured_backend_rule" ] && [ "$configured_backend_rule" != "$generated_backend_rule" ]; then
    preserve_backend_rule=true
    custom_traefik_keys="${custom_traefik_keys:+$custom_traefik_keys, }TRAEFIK_BACKEND_RULE"
  fi
  if [ -n "$configured_websocket_rule" ] && [ "$configured_websocket_rule" != "$generated_websocket_rule" ]; then
    preserve_websocket_rule=true
    custom_traefik_keys="${custom_traefik_keys:+$custom_traefik_keys, }TRAEFIK_WEBSOCKET_RULE"
  fi
  if [ -n "$configured_pg_proxy_rule" ] && [ "$configured_pg_proxy_rule" != "$generated_pg_proxy_rule" ]; then
    preserve_pg_proxy_rule=true
    custom_traefik_keys="${custom_traefik_keys:+$custom_traefik_keys, }TRAEFIK_PG_PROXY_RULE"
  fi

  if [ "$persist" = true ] && [ -f "$config_file" ] && { [ "$legacy_present" = true ] || [ "${BREAKTEST_PUBLIC_URL:-}" != "$BT_PUBLIC_URL" ] || [ "${BREAKTEST_TLS_MODE:-}" != "$tls_mode" ]; }; then
    backup_file="${config_file}.before-public-url.$(date +%Y%m%d%H%M%S)"
    cp "$config_file" "$backup_file"
    bt_set_env_value "$config_file" BREAKTEST_PUBLIC_URL "$BT_PUBLIC_URL"
    bt_set_env_value "$config_file" BREAKTEST_TLS_MODE "$tls_mode"
    bt_remove_env_value "$config_file" ENABLE_SSL
    bt_remove_env_value "$config_file" ENABLE_HTTPS
    bt_remove_env_value "$config_file" CONTROLLER_HOST
    [ "$preserve_entrypoints" = true ] || bt_remove_env_value "$config_file" TRAEFIK_ENTRYPOINTS
    [ "$preserve_tls" = true ] || bt_remove_env_value "$config_file" TRAEFIK_TLS
    [ "$preserve_cert_resolver" = true ] || bt_remove_env_value "$config_file" TRAEFIK_CERT_RESOLVER
    [ "$preserve_frontend_rule" = true ] || bt_remove_env_value "$config_file" TRAEFIK_FRONTEND_RULE
    [ "$preserve_backend_rule" = true ] || bt_remove_env_value "$config_file" TRAEFIK_BACKEND_RULE
    [ "$preserve_websocket_rule" = true ] || bt_remove_env_value "$config_file" TRAEFIK_WEBSOCKET_RULE
    [ "$preserve_pg_proxy_rule" = true ] || bt_remove_env_value "$config_file" TRAEFIK_PG_PROXY_RULE
    echo "Migrated public endpoint settings in $config_file (backup: $backup_file)"
  fi

  BREAKTEST_PUBLIC_URL="$BT_PUBLIC_URL"
  BREAKTEST_TLS_MODE="$tls_mode"
  export BREAKTEST_PUBLIC_URL BREAKTEST_TLS_MODE

  TRAEFIK_ENTRYPOINTS="$generated_entrypoints"
  TRAEFIK_TLS="$generated_tls"
  TRAEFIK_CERT_RESOLVER="$generated_cert_resolver"
  TRAEFIK_FRONTEND_RULE="$generated_frontend_rule"
  TRAEFIK_BACKEND_RULE="$generated_backend_rule"
  TRAEFIK_WEBSOCKET_RULE="$generated_websocket_rule"
  TRAEFIK_PG_PROXY_RULE="$generated_pg_proxy_rule"
  [ "$preserve_entrypoints" = true ] && TRAEFIK_ENTRYPOINTS="$configured_entrypoints"
  [ "$preserve_tls" = true ] && TRAEFIK_TLS="$configured_tls"
  [ "$preserve_cert_resolver" = true ] && TRAEFIK_CERT_RESOLVER="$configured_cert_resolver"
  [ "$preserve_frontend_rule" = true ] && TRAEFIK_FRONTEND_RULE="$configured_frontend_rule"
  [ "$preserve_backend_rule" = true ] && TRAEFIK_BACKEND_RULE="$configured_backend_rule"
  [ "$preserve_websocket_rule" = true ] && TRAEFIK_WEBSOCKET_RULE="$configured_websocket_rule"
  [ "$preserve_pg_proxy_rule" = true ] && TRAEFIK_PG_PROXY_RULE="$configured_pg_proxy_rule"
  if [ -n "$custom_traefik_keys" ]; then
    echo "Preserving customized Traefik settings: $custom_traefik_keys"
  fi
  export TRAEFIK_ENTRYPOINTS TRAEFIK_TLS TRAEFIK_CERT_RESOLVER
  export TRAEFIK_FRONTEND_RULE TRAEFIK_BACKEND_RULE TRAEFIK_WEBSOCKET_RULE TRAEFIK_PG_PROXY_RULE
}

bt_uses_https_compose() {
  [ "${BREAKTEST_TLS_MODE:-disabled}" = "letsencrypt" ]
}
