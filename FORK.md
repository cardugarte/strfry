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

## Deployments

### Fly — production

Unchanged by this fork's additions. It sets no `STRFRY_*` variables, so the
rendered config equals the committed `strfry.conf`. Its shape, guardrails and
validation steps are documented in `README.fly.md`, which remains the
authority for that environment.

### Coolify — `relay-dev.travelsats.ar`

Runs `ghcr.io/cardugarte/strfry:<tag>`, built by
`.github/workflows/docker-build.yml` on tag push (amd64 only; upstream also
builds arm64 and publishes only `:latest`).

Required configuration:

```
STRFRY_SERVICE_URL          wss://relay-dev.travelsats.ar
STRFRY_RELAY_NAME           Travelsats Relay
STRFRY_RELAY_DESCRIPTION    The home of Bitcoin travel in Argentina. …
STRFRY_WRITE_POLICY_PLUGIN  /app/policy/whitelist.sh
STRFRY_ALLOWED_PUBKEYS      9e868499203cb9659fca70bff7f2f47c71e970fbabde1c8db3704ad2b55f662d
```

A **persistent volume mounted at `/app/strfry-db`** is mandatory. LMDB lives
there; without it the event history is destroyed on every container recreate.

`mapsize = 10995116277760` in `strfry.conf` is 10 TB of *virtual* address
space, not disk. It does not preallocate.

**`/metrics` shares the relay listener.** It must not be publicly reachable.
This is inherited from the Fly setup, where `README.fly.md` already flags it,
and applies equally here.

## Migration from nostr-rs-relay

`relay.travelsats.ar` currently runs `nostr-rs-relay 0.9.0` with a SQLite
database. There is no in-place conversion to LMDB. The route is an event
export followed by `strfry import`, which reads JSONL on stdin. Note that the
existing relay requires NIP-42 AUTH to answer REQ, so a plain `strfry download`
against it will not work without authenticating.
