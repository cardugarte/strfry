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
# Exemption: kind 1059 (NIP-59 gift wrap) is accepted from ANY author provided
# it has EXACTLY ONE `p` tag and that tag names a whitelisted pubkey (64 hex
# chars). NIP-59 signs every gift wrap with a fresh one-time key, so an author
# whitelist can never admit them; scoping on the single recipient keeps the
# relay an inbox for members only (extra `p` tags cannot piggyback on a
# member), while still letting external NIP-17 clients write to a member.
# Reads of kinds 4 and 1059 stay NIP-42 gated in strfry.conf. Every other kind
# still goes through the author whitelist.
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
    | if (
          $req.event.kind == 1059
          and (
              [ ($req.event.tags // [])[]
                | select(type == "array" and .[0] == "p") ] as $ptags
              | ($ptags | length) == 1
                and ($ptags[0][1] | type == "string")
                and ($ptags[0][1] | ascii_downcase | . as $recipient
                     | ($recipient | test("^[0-9a-f]{64}$"))
                       and ($whitelist | index($recipient)))
          )
      ) or ($whitelist | index($req.event.pubkey | ascii_downcase)) then
          { id: $req.event.id, action: "accept" }
      else
          { id: $req.event.id, action: "reject",
            msg: "blocked: not on write whitelist" }
      end
'
