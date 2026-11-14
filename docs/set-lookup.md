# Authenticated set metadata lookup

The item editor searches Rebrickable by set name or number and offers up to eight
suggestions. The browser sends the user's PocketBase auth token to
`GET /api/set-lists/search?q=millennium%20falcon`. Selecting a result fills the
item title and code, then requests the matching Brickset metadata from
`GET /api/set-lists/lookup?provider=brickset&code=75192-1`. PocketBase checks
that both requests belong to the `users` auth collection before calling a
provider. Provider credentials and provider HTTP requests stay on PocketBase.

Selecting a suggestion fills the form's title and code and stores its
Rebrickable metadata snapshot in the form. Brickset metadata enriches that
snapshot when available. Saving the list persists the selected snapshot in the
existing JSON `catalog` field. Editing the first valid code clears it. Public
list pages render only persisted snapshots and never call either provider API.

The app uses the selected Rebrickable suggestion's image URL first. If it has no
image, it falls back to Brickset's `thumbnailURL`. The authenticated hook proxies
the approved provider image to the app. The app decodes it, scales it down
without upscaling so neither dimension exceeds 256 pixels, re-encodes it as
WebP, strips EXIF/XMP/ICC metadata chunks, and uploads that WebP to the code-keyed `table_thumbnails` PocketBase
collection. The original provider image is not stored. Public list pages load
the compact WebP from PocketBase rather than contacting either provider. The
collection is created by
`fixtures/pb_migrations/1794268800_table_thumbnails.js`; apply that migration
before deploying the updated hook.

The main list record can also have an optional camera/uploaded cover photo. It
uses the same browser-side WebP conversion, metadata stripping, 256-pixel
maximum edge, and 200 KB size limit, then uploads the result to the protected
`table_catalogs.photo` file field. Apply
`fixtures/pb_migrations/1794377044_table_catalogs_photo.js` before deploying the
frontend. Public published views are authorized by the collection view rule;
owner views of drafts use PocketBase's short-lived protected-file token.
The ten gallery photos (`photo_01` to `photo_10`) use the same processing and
protection; apply `fixtures/pb_migrations/1794463444_table_catalogs_gallery.js`
and `fixtures/pb_migrations/1794637169_table_catalogs_gallery_10.js`
with them. Set lookup and thumbnail caching do not change for gallery photos.

Lookup codes must use the canonical `digits-variant` form, such as `75192-1`.
The route returns bounded metadata and an optional HTTPS image URL. Its shared
PocketBase store caches successful results for 30 minutes and not-found results
for 5 minutes; the cache is bounded to 200 entries. Each authenticated user is
limited to 60 requests per rolling minute. Cache hits still count toward this
per-user limit, but do not consume provider quotas. Rebrickable is limited to at
most one uncached upstream request per second globally. Brickset has a global
cap of 80 upstream requests per UTC day, below its default approximate
100-request daily limit. On a cache miss, missing credentials return `503`;
invalid codes return `400`; no matching set returns `404`. Provider failures and
quota exhaustion return the same generic `503` response.

## Install the hook

Copy both `fixtures/pb_hooks/set_lookup.pb.js` and
`fixtures/pb_hooks/set_lookup_lib.js` into the PocketBase instance's `pb_hooks`
directory. The route wrappers require the library from inside each handler;
deploy both files together and ensure there is only one registration for each
route. The development PocketBase process loads `fixtures/pb_hooks`
automatically. Keep these files on the server; they are not part of the Elm
client or static frontend. The triple-slash `types.d.ts` reference is
editor-only: relative to deployed files in `pb_hooks` it points to the
instance's generated `pb_data/types.d.ts`. PocketBase ignores the reference at
runtime.

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
sha256sum /workspace/web/set-lists/fixtures/pb_hooks/set_lookup_lib.js /workspace/set-lists/set_lookup_lib.js
grep -R -n 'routerAdd("GET", "/api/set-lists/lookup"' /workspace/set-lists/pb_hooks
```

The checksum should match if `/workspace/set-lists/pb.js` is the copied fixture;
the declaration should occur exactly once across all files PocketBase loads
(substitute its configured hook directory if it differs from `pb_hooks`). These
commands only read files and do not restart or modify the host.

The search and metadata routes are standalone PocketBase custom routes. The
`table_thumbnails` file collection is required for PocketBase-hosted thumbnails.

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
