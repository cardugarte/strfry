# Fly.io Staging Guardrails

This directory remains pinned to upstream `hoytech/strfry` commit
`ca48c518d9aabf6912cbcb41f3d810cde7e0acb7`. The staging setup uses the
upstream `Dockerfile` unchanged and keeps the deployment definition in
`fly.toml`.

## Guardrail Policy

This is an explicitly bounded, single-Machine staging relay. The approved
desired state is:

- One shared-CPU Machine with 1 CPU and 256 MB RAM in `iad`.
- One encrypted 10 GB `strfry_data` volume in `iad`, mounted at
  `/app/strfry-db`, with seven-day snapshots.
- One `app` process and one TCP service on internal port `7777`.
- Public ports `80` and `443` only, with HTTPS forced on port `80`.
- No dedicated IPv4, autoscaling, or automatic Machine stopping/starting.

The relay limits in `strfry.conf` are also guardrails: event size 65536,
WebSocket payload 131072, pending outbound bytes 33554432, filter limit 500,
subscriptions per connection 200, tags per filter 3, and COUNT limit 1000000.

## Cost And Availability Intent

The small fixed shape and disabled autostop/autostart make cost predictable for
this low-volume staging relay, but Fly has no hard billing cap here. A single
LMDB-backed Machine is intentional: it avoids unsafe horizontal scaling while
trading away automatic failover and maintenance availability. Snapshots are not
a substitute for an independent relay export backup.

The upstream Dockerfile remains unchanged. Fly-specific runtime values are kept
in the root `strfry.conf`, which is the smaller overlay and the image's existing
configuration source.

The tradeoff is that `strfry.conf` is no longer the upstream default config in
this staging checkout. If this clone is later reused for another environment,
the environment-specific config should be restored or split into a deliberate
build/runtime configuration strategy rather than silently changing it again.

## Staging shape

- App name: `travelsats-relay-staging`
- Primary region: `iad` (Ashburn, Virginia, United States)
- Relay port: `7777`, bound to `0.0.0.0`
- LMDB path: `/app/strfry-db`, mounted from the `strfry_data` Fly Volume
- NIP-42 service URL: `wss://travelsats-relay-staging.fly.dev`
- No production domain or certificate is configured here
- Metrics: `/metrics` shares the relay listener and must be treated as
  private-only. Do not expose or scrape it publicly until an access-control
  path is approved.

## Validation Before Any Deploy

Run these commands from this directory. They do not deploy or mutate remote
resources:

```sh
fly config validate --config ./fly.toml --strict
bash -n scripts/check-fly-staging.sh
git diff --check
FLY_APP=travelsats-relay-staging ./scripts/check-fly-staging.sh
```

The policy script requires `fly` and `jq`, uses fixed read-only commands, and
defaults `FLY_APP` to `travelsats-relay-staging`. It checks both local desired
state and live JSON state. A failing check is a deployment blocker.

Do not use `fly launch`, `fly scale count` greater than `1`, dedicated IPv4,
autoscaling, or extra services. Do not deploy this overlay until the policy
script passes against the intended app. Never use these guardrails as a reason
to touch production, DNS, secrets, native, or PWA code.
