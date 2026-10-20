#!/usr/bin/env bash
# Deterministic test for policy/whitelist.sh. Needs only bash and jq.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
allowed="$(printf 'a%.0s' {1..64})"
random="$(printf 'b%.0s' {1..64})"
export STRFRY_ALLOWED_PUBKEYS="$allowed"

fail=0
reject='{"id":"id1","action":"reject","msg":"blocked: not on write whitelist"}'
accept='{"id":"id1","action":"accept"}'

# ev <type> <kind> <pubkey> <tags-json>
ev() {
  jq -nc --arg t "$1" --argjson k "$2" --arg p "$3" --argjson tags "$4" \
    '{type:$t, event:{id:"id1", kind:$k, pubkey:$p, tags:$tags}}'
}

# check <name> <input-jsonl> <expected-output>
check() {
  local got
  got="$(printf '%s\n' "$2" | "$here/whitelist.sh")"
  if [ "$got" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    echo "  want: $3"
    echo "  got:  $got"
    fail=1
  fi
}

check "kind 1 whitelisted author -> accept" \
  "$(ev new 1 "$allowed" '[]')" "$accept"
check "kind 1 random author -> reject" \
  "$(ev new 1 "$random" '[]')" "$reject"
check "kind 1059 random author with p tag -> accept" \
  "$(ev new 1059 "$random" "[[\"p\",\"$allowed\"]]")" "$accept"
check "kind 1059 random author without p tag -> reject" \
  "$(ev new 1059 "$random" '[["e","x"]]')" "$reject"
check "1059 to whitelisted recipient from random author -> accept" \
  "$(ev new 1059 "$random" "[[\"p\",\"$(printf '%s' "$allowed" | tr a A)\"]]")" "$accept"
check "1059 to non-whitelisted recipient -> reject" \
  "$(ev new 1059 "$random" "[[\"p\",\"$random\"]]")" "$reject"
check "1059 with malformed p value -> reject" \
  "$(ev new 1059 "$random" '[["p","not-hex"],["p"],["p",42]]')" "$reject"
check "1059 with two p tags, one whitelisted -> reject" \
  "$(ev new 1059 "$random" "[[\"p\",\"$allowed\"],[\"p\",\"$random\"]]")" "$reject"
check "1059 with one whitelisted p tag plus an e tag -> accept" \
  "$(ev new 1059 "$random" "[[\"e\",\"x\"],[\"p\",\"$allowed\"]]")" "$accept"
check "non-new type is ignored" \
  "$(ev lookback 1 "$allowed" '[]')" ""

exit "$fail"
