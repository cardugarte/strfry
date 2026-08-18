#!/bin/sh
# Render strfry.conf from the environment, then hand off to strfry.
#
# A single branch serves both deployments (Fly and Coolify), but they cannot
# share a literal config: NIP-42 validates auth challenges against
# relay.auth.serviceUrl, so each environment needs its own external URL or
# AUTH breaks there.
#
# Every variable is optional. When one is unset the value already in
# strfry.conf is kept, so an environment that sets nothing behaves exactly as
# it did before this script existed.
set -eu

SRC=${STRFRY_CONF_SRC:-/app/strfry.conf}
CONF=${STRFRY_CONF_OUT:-/tmp/strfry.conf}

cp "$SRC" "$CONF"

# Replace `key = "value"` while preserving the original indentation. Only the
# first match is touched, which is correct here: each of these keys appears
# once in strfry.conf.
set_str() {
    key=$1
    val=$2
    [ -z "$val" ] && return 0
    # Escape backslashes and the separator so URLs and descriptions are safe.
    esc=$(printf '%s' "$val" | sed -e 's/[\\|]/\\&/g')
    sed -i "0,/^\([[:space:]]*\)$key[[:space:]]*=.*/s||\1$key = \"$esc\"|" "$CONF"
}

set_str db          "${STRFRY_DB:-}"
set_str bind        "${STRFRY_BIND:-}"
set_str serviceUrl  "${STRFRY_SERVICE_URL:-}"
set_str name        "${STRFRY_RELAY_NAME:-}"
set_str description "${STRFRY_RELAY_DESCRIPTION:-}"
set_str pubkey      "${STRFRY_RELAY_PUBKEY:-}"
set_str contact     "${STRFRY_RELAY_CONTACT:-}"
set_str plugin      "${STRFRY_WRITE_POLICY_PLUGIN:-}"

exec /app/strfry --config="$CONF" "$@"
