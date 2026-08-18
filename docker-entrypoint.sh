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

# Replace `key = "value"` while preserving the original indentation.
#
# Every key handled here appears exactly once in strfry.conf, so a plain
# substitution is enough - no address range is needed. That matters: this runs
# under busybox sed in Alpine, which does not support GNU's `0,/re/` range, and
# a range-based version silently substituted nothing here while working fine
# against GNU sed on a developer machine.
set_str() {
    key=$1
    val=$2
    [ -z "$val" ] && return 0
    # Escape backslashes, the separator, and & (which means "the whole match"
    # on the replacement side).
    esc=$(printf '%s' "$val" | sed -e 's/[\\|&]/\\&/g')
    sed -i "s|^\([[:space:]]*\)$key[[:space:]]*=.*|\1$key = \"$esc\"|" "$CONF"

    # Fail loudly rather than booting with a config that silently ignored the
    # environment.
    if ! grep -q "^[[:space:]]*$key[[:space:]]*= \"" "$CONF"; then
        echo "entrypoint: failed to set '$key' in $CONF" >&2
        exit 1
    fi
}

set_str db          "${STRFRY_DB:-}"
set_str bind        "${STRFRY_BIND:-}"
set_str serviceUrl  "${STRFRY_SERVICE_URL:-}"
set_str name        "${STRFRY_RELAY_NAME:-}"
set_str description "${STRFRY_RELAY_DESCRIPTION:-}"
set_str pubkey      "${STRFRY_RELAY_PUBKEY:-}"
set_str contact     "${STRFRY_RELAY_CONTACT:-}"
set_str plugin      "${STRFRY_WRITE_POLICY_PLUGIN:-}"

# Refuse to boot an accidental open relay.
#
# strfry.conf points writePolicy.plugin at the whitelist script by default, so
# the only ways to end up without a policy are a genuine decision to run an
# open relay or a broken image. Those two look identical at runtime - the relay
# comes up fine and quietly accepts the whole network - which is exactly what
# happened once already. Fail loudly here instead.
#
# Set STRFRY_ALLOW_OPEN_RELAY=1 to run without a write policy on purpose.
plugin_path=$(sed -n 's|^[[:space:]]*plugin[[:space:]]*=[[:space:]]*"\(.*\)".*|\1|p' "$CONF")

if [ "${STRFRY_ALLOW_OPEN_RELAY:-}" != "1" ]; then
    if [ -z "$plugin_path" ]; then
        echo "entrypoint: writePolicy.plugin is empty - this would accept writes from anyone." >&2
        echo "entrypoint: set STRFRY_WRITE_POLICY_PLUGIN, or STRFRY_ALLOW_OPEN_RELAY=1 to allow it." >&2
        exit 1
    fi
    if [ ! -x "$plugin_path" ]; then
        echo "entrypoint: write policy '$plugin_path' is missing or not executable." >&2
        exit 1
    fi
fi

exec /app/strfry --config="$CONF" "$@"
