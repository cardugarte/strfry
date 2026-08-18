# Fork-Specific: Travelsats Deployment

Fork of [`hoytech/strfry`](https://github.com/hoytech/strfry), deployed to two
environments from one branch.

## Branch model

| Branch | Role |
|---|---|
| `master` | Mirror of `upstream/master`. Do not commit here. |
| `travelsats` | **The deployment branch.** Both Fly and Coolify build from it. |

One branch serves both because the two deployments run identical code and
differ only in configuration. What makes that possible is that `strfry.conf`
is rendered at startup rather than baked in — see below.

```bash
git remote add upstream https://github.com/hoytech/strfry.git   # one-time
git fetch upstream && git checkout master && git merge --ff-only upstream/master
git checkout travelsats && git rebase master
```

## Why the config is rendered, not committed

NIP-42 validates auth challenges against `relay.auth.serviceUrl`. That URL is
necessarily different per environment, so a single literal `strfry.conf` would
break AUTH on whichever deployment did not own the URL.

`docker-entrypoint.sh` copies `strfry.conf`, applies any variables that are
set, and execs strfry against the result. **Every variable is optional and an
unset one keeps the file's existing value**, so an environment that sets
nothing renders a byte-identical config. This is what lets Fly keep working
untouched.

| Variable | Overrides |
|---|---|
| `STRFRY_SERVICE_URL` | `relay.auth.serviceUrl` — required for NIP-42 |
| `STRFRY_RELAY_NAME` | NIP-11 name |
| `STRFRY_RELAY_DESCRIPTION` | NIP-11 description |
| `STRFRY_RELAY_PUBKEY` | NIP-11 pubkey |
| `STRFRY_RELAY_CONTACT` | NIP-11 contact |
| `STRFRY_DB` | LMDB directory |
| `STRFRY_BIND` | listen interface |
| `STRFRY_WRITE_POLICY_PLUGIN` | `relay.writePolicy.plugin` |
| `STRFRY_ALLOWED_PUBKEYS` | read by the plugin itself, not by strfry |

## Write policy

strfry has no config equivalent to nostr-rs-relay's `restricted_writes`;
policy lives in plugins. `policy/whitelist.sh` accepts writes only from the
pubkeys in `STRFRY_ALLOWED_PUBKEYS` (comma-separated hex, not npub) and
**fails closed** — an empty list rejects everything.

It runs as one streaming `jq` process, not a shell read loop: strfry blocks
waiting for the plugin's answer before sending the next event, so spawning a
process per event would become the relay's write ceiling. `jq` is installed in
the runtime image for this.

### The policy is on by default, and the entrypoint enforces it

`strfry.conf` ships `writePolicy.plugin = "/app/policy/whitelist.sh"`, not
upstream's empty string, and `docker-entrypoint.sh` refuses to start when the
resulting path is empty or not executable. `STRFRY_ALLOW_OPEN_RELAY=1` is the
only way past that check.

This is not belt-and-braces for its own sake. On 2026-08-18 `relay.travelsats.ar`
was pointed at the Fly deployment before the write policy was configured there.
The relay was reachable, well-behaved, and completely open. Within the minutes
it took to deploy the policy, 33 events from 29 unrelated pubkeys had been
written to it and had to be deleted by hand.

Two properties come out of that:

- **An unconfigured deployment writes nothing.** Forgetting
  `STRFRY_ALLOWED_PUBKEYS` leaves the plugin with an empty allow-list, which
  rejects every event. The failure mode is "nobody can publish", which someone
  reports in minutes — not "anybody can publish", which nobody notices.
- **A broken image does not boot.** A missing or non-executable plugin is
  indistinguishable at runtime from a deliberate open relay, so the entrypoint
  treats it as fatal instead of serving traffic.

**Order matters when moving a hostname**: configure the write policy on the
target *before* DNS points at it. A relay on a real hostname takes traffic in
seconds.

## Deployments

### Fly — `relay.travelsats.ar` (production)

Serves the production hostname since 2026-08-18. Its configuration lives in
`fly.toml` under `[env]` rather than in `fly secrets`: every value is public —
the relay's advertised identity plus a list of public keys — so it belongs in
version control where a review can catch it being wrong.

> **Known drift — the version string under-reports.** `fly deploy` builds from
> the working tree, and the version strfry advertises comes from `git describe`
> at build time. The running deployment was built between the `v1.1.1-ts.2` and
> `v1.1.1-ts.3` tags, so it reports `v1.1.1-ts.2` while actually carrying the
> ts.3 changes — the fail-closed write policy and the entrypoint boot guard.
>
> The relay is not out of date; its label is. Treat NIP-11 `version` on Fly as
> a lower bound, not as the truth, and confirm against `fly releases` or the
> presence of the behaviour itself. Redeploying from a checkout of the tag
> clears it. Coolify does not have this problem: it pulls a tagged image from
> GHCR, so what it reports is what it runs.

`README.fly.md` remains the authority for the machine, volume and rollout
shape of that environment.

Earlier revisions of this file said Fly set no `STRFRY_*` variables and
therefore rendered a config byte-identical to the committed one. That stopped
being true when Fly became production: `serviceUrl` has to match the hostname
clients dial, because NIP-42 validates the AUTH challenge against it.

### Coolify — `relay-dev.travelsats.ar`

Runs `ghcr.io/cardugarte/strfry:<tag>`, built by
`.github/workflows/docker-build.yml` on tag push (amd64 only; upstream also
builds arm64 and publishes only `:latest`).

Required configuration:

```
STRFRY_SERVICE_URL          wss://relay-dev.travelsats.ar
STRFRY_RELAY_NAME           Travelsats Relay
STRFRY_RELAY_DESCRIPTION    The home of Bitcoin travel in Argentina. …
STRFRY_RELAY_PUBKEY         9e868499203cb9659fca70bff7f2f47c71e970fbabde1c8db3704ad2b55f662d
STRFRY_RELAY_CONTACT        hello@travelsats.ar
STRFRY_WRITE_POLICY_PLUGIN  /app/policy/whitelist.sh
STRFRY_ALLOWED_PUBKEYS      9e868499203cb9659fca70bff7f2f47c71e970fbabde1c8db3704ad2b55f662d
```

`9e868499…` is the Travelsats corporate pubkey. **Do not copy the NIP-11
`pubkey` out of the old relay's `config.toml`**: it carries `9e868932…`, a
corrupted transcription of the same key that appears nowhere else in the
project and that the retiring relay has been advertising as its owner.

**Leave Coolify's health check disabled.** Enabling it fails the deployment on
this app, and it has been ruled out carefully: scheme, host, port, path, method
and return code are all correct, `curl` is in the image, and the exact command
succeeds inside the container as both root and the `strfry` user. Coolify's API
returns no deployment logs, so the cause is not observable from outside.

The image carries its own `HEALTHCHECK` instead. Docker runs it and Coolify
surfaces the result — the app reports `running:healthy` with Coolify's own
check switched off, where an image without one reports `running:unknown`.

A **persistent volume mounted at `/app/strfry-db`** is mandatory. LMDB lives
there; without it the event history is destroyed on every container recreate.

`mapsize = 10995116277760` in `strfry.conf` is 10 TB of *virtual* address
space, not disk. It does not preallocate.

**`/metrics` shares the relay listener.** It must not be publicly reachable.
This is inherited from the Fly setup, where `README.fly.md` already flags it,
and applies equally here.

## Migration from nostr-rs-relay

`relay.travelsats.ar` runs `nostr-rs-relay 0.9.0` on SQLite. There is no
in-place conversion to LMDB, and none was needed.

The old relay held **73 events, all authored by the corporate pubkey, and
every one of them was already replicated on public relays** — `nos.lol` alone
carried those 73 plus 274 more. So the content was backfilled from the public
network instead of being exported out of SQLite: read the corporate pubkey's
history from `nos.lol` / `relay.damus.io` / `nostr.land`, deduplicate by event
id, and republish the events as raw `["EVENT", …]` frames.

Republishing works because the write policy filters on the **event author**,
not the connection, and the events keep their original id and signature. No
host access, no downtime on the old relay, and a strictly larger result than
an export would have produced.

Two things to know before repeating this:

- **`nak req` is the wrong tool for a dump.** It waits to collect `limit`
  events instead of closing on EOSE, so any query returning fewer events than
  the limit hangs until its timeout — which reads exactly like a relay that
  refuses to answer. Use a client that closes on EOSE.
- Contrary to an earlier note here, the old relay does **not** require NIP-42
  AUTH to answer REQ. Reads are open; only writes are restricted.

`strfry import` (JSONL on stdin) remains the right tool when the source is a
database rather than a live relay.
