# Palikkalistat (Set Lists)

Palikkalistat is an Elm 0.19 SPA backed by PocketBase. Signed-in members can
create, edit, publish, and delete their own set lists. Ordered list items can be
LEGO sets, alternate builds, or MOCs; each item supports multiple LEGO codes,
selected LEGO.com/Brickset/BrickLink/Rebrickable links, optional Markdown description, and a
safe HTTP(S) reference URL. Lists and item descriptions include a small
Markdown toolbar and preview. A published list is available at `/#/[id]` and
includes an A4 print view with a QR code to
`https://listat.palikkaharrastajat.fi/#/[id]`.

Signed-in editors can optionally look up set metadata from Rebrickable or
Brickset and accept a snapshot into the item. Public list pages render accepted
snapshots without provider API requests (an optional saved thumbnail is a direct
image-asset GET). The PocketBase hook, server-side credential setup, and install
steps are documented in [docs/set-lookup.md](docs/set-lookup.md). No collection
migration is needed.

## Development

This follows the sibling applications' devenv, Elm/Vite, and Haskell statics
scaffold:

```sh
devenv shell -- make elm-dev
devenv shell -- make elm-test
devenv shell -- make elm-build
devenv shell -- make statics-build
```

The Haskell statics executable is intentionally a no-op: app data is read from
PocketBase at runtime, and there are no feed or generated content files. Keep
`statics-build` in the project so the app retains the standard sibling build
scaffolding.

`VITE_POCKETBASE_URL` overrides the default `https://data.palikkaharrastajat.fi`
API URL. Local PocketBase is exposed on `http://127.0.0.1:8090` by devenv; apply
the migration in `fixtures/pb_migrations/` before using the app against it. When
the development server targets a loopback PocketBase, its login page uses
password authentication instead of OAuth. Create a local `users` auth collection
with password auth enabled and a test user in the PocketBase admin UI. Production
continues to use OAuth/OIDC via the hosted PocketBase; local OAuth requires an
OIDC provider named `oidc` to be configured. The default URL points to the hosted
PocketBase, where member authentication is already configured.

## PocketBase data and access

The `table_catalogs` collection stores `title`, `description`, list-level `content`
(Markdown), and an ordered JSON `items` array (`{ title, codes, type, services,
description?, url?, catalog? }` per item),
`status` (`draft` or `published`), and the authenticated PocketBase user id in
`owner`. `type` is `set`, `altbuild`, or `moc`; set and alternate-build items
require at least one code, while MOC codes are optional and may contain multiple
strings. The optional item URL accepts only absolute HTTP(S) addresses. Array
order is the display order, and each item's `services` selection applies to every
code on that item. List-level Markdown is labeled “Kuvaus” and shown directly
below the title. The top-level `description` field remains stored but is currently
hidden from the UI and preserved when an existing list is edited.

Accepted `catalog` snapshots store provider metadata in the existing JSON item.
They are cleared when the item's first valid lookup code changes. Public pages
use only the stored snapshot and do not call Rebrickable or Brickset APIs.

The client intentionally decodes only this item shape; it does not migrate old
`{ code, services }` rows. For development data replacement, back up and replace
the local `table_catalogs` collection; the existing dev list data is discarded.

PocketBase rules allow public reads only for published lists; authenticated
owners can read their drafts and published records and may only update or delete
their own. Record ownership is set on create and immutable through the update
rule. Because `owner` is an ordinary record field, unauthenticated reads of
published records include the owner's PocketBase user id; the rules prevent an
unauthenticated owner-wide listing of drafts, but do not hide owner ids on
published records. The home screen itself is login-only and fetches all pages of
the authenticated owner's lists, so accounts with more than 200 lists are not
silently truncated. `assets/robots.txt` disallows all crawlers and the document
metadata requests `noindex, nofollow, noarchive`.

For deployment, ensure the target PocketBase collection has the current field
schema before deploying the frontend. Its JSON `items` field currently has a
100,000-byte `maxSize`; longer per-item Markdown or very large lists may require
raising that limit when configuring the collection. OAuth2/OIDC login uses the
shared `master-builder` PocketBase auth helper.
