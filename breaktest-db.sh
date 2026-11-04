#!/bin/bash
# One breaktest-db service ingests live tests and serves every stored result.

# Prints the normalised BREAKTEST_DB_ENABLED value (true/false). Accepts
# true/1/yes/on in any case, and the former BREAKTEST_DB_APPLICATION_PREVIEW=1
# when the new flag is unset, so preview installations stay enabled after upgrade.
bt_breaktest_db_enabled_value() {
    local value="${BREAKTEST_DB_ENABLED:-}"
    if [ -z "$value" ] && [ "${BREAKTEST_DB_APPLICATION_PREVIEW:-}" = 1 ]; then value=true; fi
    case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) printf true ;;
        ''|false|0|no|off) printf false ;;
        *) echo "Error: BREAKTEST_DB_ENABLED must be true or false; got '$value'. Fix config.env." >&2; return 1 ;;
    esac
}

bt_breaktest_db_profiles() {
    local enabled
    enabled=$(bt_breaktest_db_enabled_value) || return 1
    if [ "$enabled" = true ]; then
        printf '%s' '--profile breaktest-db'
    fi
}
