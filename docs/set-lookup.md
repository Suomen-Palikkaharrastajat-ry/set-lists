# Authenticated set metadata lookup

The item editor can request a set's title, year, piece count, and source page
from Rebrickable or Brickset. The browser sends the user's PocketBase auth token
to `GET /api/set-lists/lookup?provider=rebrickable|brickset&code=75192-1`.
PocketBase checks that the token belongs to the `users` auth collection before
the request reaches either provider. Provider credentials and provider HTTP
requests stay on the PocketBase server.

Lookup results remain temporary in the editor until the user chooses
“Tallenna tiedot”. Acceptance stores the provider, lookup code, name, year,
piece count, and optional approved HTTPS image URL in the item's existing JSON
`catalog` field and fills the item title only if it is blank. Editing the first
valid code clears that snapshot. Public list pages render only persisted
snapshots and never call either provider API. A rendered thumbnail causes a
direct browser GET for the image asset from its approved Rebrickable/Brickset
host; it is not a provider API request. No collection or schema migration is
required.

Lookup codes must use the canonical `digits-variant` form, such as `75192-1`.
The route returns bounded metadata and an optional HTTPS image URL. Its shared
PocketBase store caches successful results for 30 minutes and not-found results
for 5 minutes; the cache is bounded to 200 entries. Each authenticated user is
limited to 20 requests per rolling minute. Cache hits still count toward this
per-user limit, but do not consume provider quotas. Rebrickable is limited to at
most one uncached upstream request per second globally. Brickset has a global
cap of 80 upstream requests per UTC day, below its default approximate
100-request daily limit. On a cache miss, missing credentials return `503`;
invalid codes return `400`; no matching set returns `404`. Provider failures and
quota exhaustion return the same generic `503` response.

## Install the hook

Copy `fixtures/pb_hooks/set_lookup.pb.js` into the PocketBase instance's
`pb_hooks` directory (or configure PocketBase to load that directory). The
development PocketBase process loads `fixtures/pb_hooks` automatically. Keep
this hook on the server; it is not part of the Elm client or static frontend.
The triple-slash `types.d.ts` reference at the top is editor-only: relative to a
deployed `pb_hooks` file it points to the instance's generated
`pb_data/types.d.ts`. PocketBase ignores the reference at runtime, so it does
not need to be resolved to load the hook. In this fixture layout, an editor
looking for that reference expects `fixtures/pb_data/types.d.ts`.

The observed generic HTTP 400 from the live host was accompanied by PocketBase
logs showing that the hook loaded from `/workspace/set-lists/pb.js` is different
from or incomplete compared with the current fixture (for example,
`SET_LOOKUP_CODE` or `setLookupJson` is missing). The deployer must ensure exactly
one lookup route is loaded, from the complete `fixtures/pb_hooks/set_lookup.pb.js`,
including its helpers and constants. Do not load a partial copy or stale duplicate
that can register a competing handler. These are operator-side host changes; do
not alter any host files as part of this application change.

For read-only diagnosis, compare checksums of the deployed file and the checked
out fixture, then search the deployed file and any configured hook directory for
lookup-route declarations:

```sh
sha256sum /workspace/web/set-lists/fixtures/pb_hooks/set_lookup.pb.js /workspace/set-lists/pb.js
grep -n 'routerAdd("GET", "/api/set-lists/lookup"' /workspace/set-lists/pb.js
grep -R -n 'routerAdd("GET", "/api/set-lists/lookup"' /workspace/set-lists/pb_hooks
```

The checksum should match if `/workspace/set-lists/pb.js` is the copied fixture;
the declaration should occur exactly once across all files PocketBase loads
(substitute its configured hook directory if it differs from `pb_hooks`). These
commands only read files and do not restart or modify the host.

No collection migration or additional collection is required. This is a
standalone PocketBase custom route.

## Configure provider credentials

Create a root-owned environment file on the PocketBase host, for example
`/etc/pocketbase/set-lookup.env`, and place the provider credentials in that
file outside the repository. The variable names are:

- `REBRICKABLE_API_KEY` for Rebrickable lookups
- `BRICKSET_API_KEY` for Brickset lookups

An empty or unset provider variable disables only that provider and the route
responds with `503` for its requests. Restrict the environment file to the
PocketBase service account (for example, mode `0600`). Never put the values in
the frontend, Vite configuration, this repository, or logs.

For a systemd service, add a drop-in such as
`/etc/systemd/system/pocketbase.service.d/set-lookup.conf`:

```ini
[Service]
EnvironmentFile=/etc/pocketbase/set-lookup.env
```

After installing the hook and configuring the environment file, reload systemd
and restart PocketBase:

```sh
sudo systemctl daemon-reload
sudo systemctl restart pocketbase
sudo systemctl status pocketbase
```

Check the service status if the route is unavailable. Do not include credentials
in command-line arguments or diagnostic output.

## Local checks

The hook tests use mocked provider responses and do not make network requests or
need credentials:

```sh
make pb-hook-test
```
