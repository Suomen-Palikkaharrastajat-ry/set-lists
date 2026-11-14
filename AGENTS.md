# AGENTS.md

## Project overview

Table catalogs is an Elm 0.19 SPA backed by PocketBase. Signed-in users manage
their own catalogs; published catalogs are public at `/#/[id]`. The Haskell
`statics` executable is intentionally a no-op, but its build target is retained
for compatibility with the sibling projects.

## Project layout and commands

- `elm-app/`: Elm application, Vite entry points, and Elm tests.
- `fixtures/pb_migrations/`: PocketBase schema and access rules.
- `fixtures/pb_hooks/`: server-only PocketBase custom routes and mocked tests.
- `docs/set-lookup.md`: install and server-side configuration for metadata lookup.
- `statics/`: no-op Haskell executable; keep `make statics-build` and
  `make statics` working.
- `assets/robots.txt`: blocks all crawlers; preserve this behavior.
- `vendor/master-builder/`: shared project tooling and authentication helpers.

Run project commands in the devenv shell:

```sh
devenv shell -- make elm-test
devenv shell -- make check
devenv shell -- make elm-build
devenv shell -- make statics-build statics
devenv shell -- make test
```

Use `make vendor` if the shared `master-builder` checkout is missing. Do not
install npm dependencies directly; they are managed through Nix in `pkgs/`.
The Vite and local PocketBase servers bind to `0.0.0.0` so the sandbox can
publish their ports; keep those bind addresses when changing their commands.

## Data and security

- PocketBase is the authority for ownership and draft/public access. Keep
  collection rules in the migration restrictive; do not rely on client-side
  filtering for access control.
- Only published lists are public. Users may manage only their own lists.
- Item order is the order of entries in `items`; preserve it when encoding,
  decoding, and editing. Each new item has `codes`, `type`, and `services`, with
  optional Markdown `description` and safe HTTP(S) `url`.
- Markdown links and images must continue to use `MarkdownSafety.safeUrl`.
- Item reference URLs must use `MarkdownSafety.safeWebUrl`. Do not add a legacy
  item decoder or a PocketBase migration for replacing development data.
- Set search and metadata lookup are authenticated PocketBase routes restricted to the
  `users` auth collection. Keep provider credentials server-side; never add them
  to Elm, browser JavaScript, Vite environment variables, `dist/`, or examples.
  Local PocketBase loads `fixtures/pb_hooks/`; do not enable that fixture hook
  directory in production. Apply the `table_thumbnails` migration before deploying
  the updated production hook.
- Selected set data is stored in each item's optional `catalog` JSON snapshot.
  Brickset thumbnails are app-encoded WebP files no larger than 256px and are
  cached in PocketBase;
  public list routes must render saved snapshots without provider API requests.
  See `docs/set-lookup.md` for deployed-hook troubleshooting.
- The optional main-list cover is a protected `table_catalogs.photo` WebP file.
  Uploads must be decoded and re-encoded in the browser, stripped of image
  metadata, limited to a 256px maximum edge and 200 KB, and authorized through
  PocketBase's list view rule/file token. Apply the cover-photo migration before
  deploying the frontend.
- Up to ten optional gallery photos (`table_catalogs.photo_01` to
  `photo_10`) follow the same rules. Items store only the selected slot names in
  their `photos` array, never filenames or URLs; the decoder keeps only known
  slots. Clearing a slot also unselects it from every item in the editor.
  Published gallery files are reachable under the record's view rule even when
  no item selects them; item selections only control display. Apply the gallery
  migrations (`1794463444_table_catalogs_gallery` and
  `1794637169_table_catalogs_gallery_10`) before deploying the frontend.
- Keep `robots.txt` disallowing all crawlers and the document metadata noindex.
- Apply the PocketBase migration before using a fresh local instance. Local
  development uses password login against loopback PocketBase and requires a
  local `users` auth collection with password auth enabled. Production uses the
  shared `oidc` OAuth provider configured on the hosted PocketBase.

## Manual checks before release

- Signed-out home shows only login; protected edit routes require auth.
- A user can create, order, edit, and delete their own lists, but not another
  user's lists.
- Drafts are private; published list routes work signed out.
- An owner can upload a cover from a camera or image picker; published covers
  display to signed-out visitors, while draft covers remain protected.
- The Photos tab manages all ten gallery slots: each uploads, crops, replaces,
  and clears independently. Items list only saved slots, and a selected gallery
  photo appears beside the set thumbnails on published lists, while draft
  gallery photos stay hidden from signed-out visitors.
- Anonymous published-list views have a non-linked logo bar only, no status or
  container borders, actions, QR section, or footer; check mobile width.
- Each set displays only its selected provider links.
- Printing a published list outputs only its centered QR code on A4, linking to
  `https://esite.palikkaharrastajat.fi/#/[id]`.
- `dist/robots.txt` contains `Disallow: /`.

## Agent Sandbox

```toml agent-sandbox
[network]
allowed_hosts = [
    "GET,POST,PATCH,DELETE,HEAD data.palikkaharrastajat.fi:443/**",
    "GET,HEAD esite.palikkaharrastajat.fi:443/**",
    "GET,HEAD palikkaharrastajat.fi:443/**",
    "GET,POST,HEAD lemur-14.cloud-iam.com:443/**",
    "GET,HEAD package.elm-lang.org:443/**",
    "GET,HEAD github.com:443/**",
    "GET,HEAD api.github.com:443/**",
    "GET,HEAD codeload.github.com:443/**",
    "GET,HEAD cache.nixos.org:443/**",
    "GET,HEAD channels.nixos.org:443/**",
    "GET,HEAD devenv.cachix.org:443/**",
    "GET,HEAD nix-community.cachix.org:443/**",
    "GET,HEAD crates.io:443/**",
    "GET,HEAD index.crates.io:443/**",
    "GET,HEAD static.crates.io:443/**",
    "GET,HEAD static.rust-lang.org:443/**",
    "GET,HEAD www.lego.com:443/**",
    "GET,POST,HEAD brickset.com:443/**",
    "GET rebrickable.com:443/**",
    "GET cdn.rebrickable.com:443/**",
    "GET images.brickset.com:443/**",
    "GET,HEAD www.bricklink.com:443/**",
    "GET,HEAD registry.npmjs.org:443/**",
    "POST package.elm-lang.org:443/all-packages"
]

[ports]
web = 5173
pocketbase = 8090
```
