#!/usr/bin/env bash
set -u

readonly CONFIG="./fly.toml"
readonly STRFRY_CONFIG="./strfry.conf"
readonly APP="${FLY_APP:-travelsats-relay-staging}"

failures=0
tmp_dir=""

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

pass() {
    printf 'PASS: %s\n' "$1"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "dependency missing: $1"
}

if ! printf '%s\n' "$APP" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
    fail 'FLY_APP must contain only lowercase letters, digits, and hyphens'
fi

require_command fly
require_command jq

if [ "$failures" -ne 0 ]; then
    exit 1
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/check-fly-staging.XXXXXX") || exit 1
trap 'rm -rf "$tmp_dir"' EXIT

run_json() {
    local output="$1"
    shift
    if ! "$@" >"$output" 2>"$output.stderr"; then
        fail "could not evaluate: $*"
        return 1
    fi
    if ! jq -e . "$output" >/dev/null 2>&1; then
        fail "command did not return valid JSON: $*"
        return 1
    fi
    return 0
}

if ! fly config validate --config "$CONFIG" --strict >"$tmp_dir/config-validate.out" 2>"$tmp_dir/config-validate.err"; then
    fail 'fly.toml strict validation'
else
    pass 'fly.toml strict validation'
fi

if ! run_json "$tmp_dir/local.json" fly config show --local --config "$CONFIG"; then
    exit 1
fi
if ! jq --arg app "$APP" -e '
    .app == $app and
    .primary_region == "iad" and
    (.http_service.internal_port == 7777) and
    (.http_service.force_https == true) and
    (.http_service.auto_stop_machines == false) and
    (.http_service.auto_start_machines == false) and
    (.http_service | has("min_machines_running") | not) and
    (.http_service | has("max_machines_running") | not) and
    (.http_service.processes == ["app"]) and
    (.mounts | length == 1) and
    (.mounts[0].source == "strfry_data") and
    (.mounts[0].destination == "/app/strfry-db") and
    (.mounts[0].snapshot_retention == 7) and
    (.vm | length == 1) and (.vm[0].cpu_kind == "shared") and
    (.vm[0].cpus == 1) and (.vm[0].memory == "256mb")
' "$tmp_dir/local.json" >/dev/null; then
    fail 'local fly.toml does not express the complete approved desired state'
else
    pass 'local fly.toml expresses the approved desired state'
fi

if ! run_json "$tmp_dir/machines.json" fly machine list --app "$APP" --json; then exit 1; fi
if ! jq -e '
    length == 1 and .[0].region == "iad" and
    .[0].config.guest.cpu_kind == "shared" and
    .[0].config.guest.cpus == 1 and
    .[0].config.guest.memory_mb == 256 and
    (. [0].config.mounts | length == 1) and
    (.[0].config.services | length == 1) and
    (.[0].config.services[0].internal_port == 7777) and
    (.[0].config.services[0].protocol == "tcp") and
    (.[0].config.services[0].ports | length == 2) and
    ([.[0].config.services[0].ports[].port] | sort == [80, 443]) and
    (.[0].config.services[0].ports | any(.[]; .port == 80 and .force_https == true)) and
    (.[0].config.services[0].ports | any(.[]; .port == 443 and ([.handlers[]] | sort == ["http", "tls"])))
' "$tmp_dir/machines.json" >/dev/null; then
    fail 'live app must have exactly one iad Machine with the approved VM and service shape'
else
    pass 'live Machine, VM, and public service shape'
fi

if ! run_json "$tmp_dir/volumes.json" fly volumes list --app "$APP" --json; then exit 1; fi
if ! jq -e '
    length == 1 and .[0].name == "strfry_data" and .[0].size_gb == 10 and
    .[0].region == "iad" and .[0].encrypted == true and
    .[0].attached_machine_id != null and .[0].attached_machine_id != "" and
    .[0].snapshot_retention == 7
' "$tmp_dir/volumes.json" >/dev/null; then
    fail 'live app must have one attached encrypted 10GB iad volume with 7-day snapshots'
else
    pass 'live volume shape and snapshot retention'
fi

if ! run_json "$tmp_dir/ips.json" fly ips list --app "$APP" --json; then exit 1; fi
if ! jq -e 'all(.[]; has("Type") and (.Type != "v4") and (.Type != "dedicated_ipv4"))' "$tmp_dir/ips.json" >/dev/null; then
    fail 'live app must not have a dedicated IPv4 address'
else
    pass 'no dedicated IPv4 address'
fi

if ! run_json "$tmp_dir/remote.json" fly config show --app "$APP"; then exit 1; fi
if ! jq --arg app "$APP" -e '
    .app == $app and .primary_region == "iad" and
    (.http_service.internal_port == 7777) and (.http_service.force_https == true) and
    (.http_service.auto_stop_machines == false) and (.http_service.auto_start_machines == false) and
    (.http_service | has("min_machines_running") | not) and
    (.http_service | has("max_machines_running") | not) and
    (.http_service.processes == ["app"]) and
    (.mounts | length == 1) and .mounts[0].source == "strfry_data" and
    .mounts[0].destination == "/app/strfry-db" and .mounts[0].snapshot_retention == 7
' "$tmp_dir/remote.json" >/dev/null; then
    fail 'live app config has autoscaling or desired-state drift'
else
    pass 'live app config has no autoscaling or desired-state drift'
fi

check_limit() {
    local key="$1"
    local max="$2"
    local value
    value=$(awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            line = $0; sub(/#.*/, "", line); sub(/^[^=]*=/, "", line)
            gsub(/[[:space:]]/, "", line); print line; exit
        }
    ' "$STRFRY_CONFIG")
    if [ -z "$value" ] || ! printf '%s\n' "$value" | grep -Eq '^[0-9]+$' || [ "$value" -gt "$max" ]; then
        fail "strfry limit $key is absent or exceeds $max"
    else
        pass "strfry limit $key <= $max"
    fi
}

if [ ! -r "$STRFRY_CONFIG" ]; then
    fail "cannot read $STRFRY_CONFIG"
else
    check_limit maxEventSize 65536
    check_limit maxWebsocketPayloadSize 131072
    check_limit maxPendingOutboundBytes 33554432
    check_limit maxFilterLimit 500
    check_limit maxSubsPerConnection 200
    check_limit maxTagsPerFilter 3
    check_limit maxFilterLimitCount 1000000
fi

if [ "$failures" -ne 0 ]; then
    printf '%s policy check(s) failed for %s\n' "$failures" "$APP" >&2
    exit 1
fi

printf 'All staging guardrail checks passed for %s\n' "$APP"
