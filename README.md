# Palikkaesitteet (Table catalogs)

Palikkaesitteet is an Elm 0.19 SPA backed by PocketBase. Signed-in members can
create, edit, publish, and delete their own table catalogs. Ordered list items can be
sets, alternate builds, or MOCs; each item supports multiple set numbers,
selected LEGO.com/Brickset/BrickLink/Rebrickable links, optional Markdown description, and a
safe HTTP(S) reference URL. Lists and item descriptions include a small
Markdown toolbar and preview. A published list is available at `/#/[id]` and
includes an A4 print view with a QR code to
`https://esite.palikkaharrastajat.fi/#/[id]`.

Signed-in editors can search Rebrickable for a set, then automatically enrich
the selected item with Brickset metadata and a PocketBase-hosted thumbnail.
Public list pages render saved snapshots without provider API requests. Hook,
credential, thumbnail migration, and install details are in
[docs/set-lookup.md](docs/set-lookup.md).

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
description?, url?, photos?, catalog? }` per item), an optional protected `photo`
cover image, and up to ten optional protected gallery photos (`photo_01` to
`photo_10`) that items select by slot name,
`status` (`draft` or `published`), and the authenticated PocketBase user id in
`owner`. `type` is `set`, `altbuild`, or `moc`; set and alternate-build items
require at least one code, while MOC codes are optional and may contain multiple
strings. The optional item URL accepts only absolute HTTP(S) addresses. Array
order is the display order, and each item's `services` selection applies to every
code on that item. The top-level `description` field is edited as “Alaotsikko” and
shown below the title when non-empty. List-level Markdown is labeled “Kuvaus” and
shown below the title and optional subtitle.

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

The optional `photo` file is uploaded separately to an existing list record.
The browser re-encodes it as a metadata-free WebP thumbnail (maximum edge 256 px,
maximum size 200 KB). The `1794377044_table_catalogs_photo` migration must be
applied before deploying the frontend. Protected-file access follows the list
view rule: published covers work for anonymous visitors, while draft covers
require the authenticated owner's short-lived file token.

The ten gallery photos use the same processing and protection. They are added
by the `1794463444_table_catalogs_gallery` and
`1794637169_table_catalogs_gallery_10` migrations, which must also be applied
before deploying the frontend. Items record which gallery slots they show; the
photos are rendered beside the item's set thumbnails. Protected gallery files
follow the same view-rule access as the cover, so a published list's photos are
reachable even when no item selects them.

For deployment, ensure the target PocketBase collection has the current field
schema before deploying the frontend. Its JSON `items` field currently has a
100,000-byte `maxSize`; longer per-item Markdown or very large lists may require
raising that limit when configuring the collection. OAuth2/OIDC login uses the
shared `master-builder` PocketBase auth helper.
