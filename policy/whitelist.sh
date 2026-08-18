#!/bin/sh
# strfry write-policy plugin: accept events only from whitelisted pubkeys.
#
# Replaces nostr-rs-relay's `restricted_writes` / "Event publishing restricted
# to N pubkey(s)" setting, which strfry has no equivalent for in config.
#
# STRFRY_ALLOWED_PUBKEYS is a comma-separated list of hex pubkeys (64 chars,
# not npub). An empty list rejects everything, which fails closed on purpose:
# a misconfigured relay should refuse writes rather than accept the world.
#
# Implemented as a single streaming jq process rather than a shell read loop.
# strfry waits for a response before sending the next event, so per-event
# process spawns would become the relay's write throughput ceiling.
set -eu

exec jq -c --unbuffered --arg allowed "${STRFRY_ALLOWED_PUBKEYS:-}" '
    # Anything other than a "new" request needs no response.
    select(.type == "new")
    | . as $req
    | (
        $allowed
        | ascii_downcase
        | split(",")
        | map(gsub("^\\s+|\\s+$"; ""))
        | map(select(length > 0))
      ) as $whitelist
    | if ($whitelist | index($req.event.pubkey | ascii_downcase)) then
          { id: $req.event.id, action: "accept" }
      else
          { id: $req.event.id, action: "reject",
            msg: "blocked: not on write whitelist" }
      end
'
