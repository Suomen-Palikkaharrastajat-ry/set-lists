# Table-catalog data model

`table_catalogs.items` is an ordered JSON array. Each object has this shape:

```json
{
  "title": "Millennium Falcon",
  "codes": ["75192-1", "75192-2"],
  "type": "set",
  "services": ["lego", "brickset", "bricklink"],
  "description": "Optional **Markdown** description",
  "url": "https://example.com/reference",
  "photos": ["photo_01", "photo_03"],
  "catalog": {
    "provider": "rebrickable",
    "code": "75192-1",
    "name": "Millennium Falcon",
    "year": 2017,
    "pieces": 7541,
    "imageUrl": "https://data.palikkaharrastajat.fi/api/files/table_thumbnails/.../set-75192-1.webp"
  }
}
```

The record also has an optional `photo` PocketBase file-field filename for the
cover, and five optional gallery file fields, `photo_01` through `photo_05`. These
are not part of the JSON list form and are uploaded separately after the list
record has been created. The cover is edited on the Description tab; the gallery
is edited on the Photos tab. The editor accepts a camera photo or image file,
decodes and re-encodes it as WebP, strips EXIF/XMP/ICC metadata, scales its
longest edge to 256 pixels without upscaling, and caps the result at 200 KB. The
source file may be up to 20 MB. All six fields are protected: their file access is
checked against the `table_catalogs` view rule, so published photos work
anonymously while private draft photos require an owner file token. The cover
field is added by `fixtures/pb_migrations/1794377044_table_catalogs_photo.js`; the
gallery fields by `fixtures/pb_migrations/1794463444_table_catalogs_gallery.js`.

An item's optional `photos` array lists gallery slot names (`photo_01` to
`photo_05`), never filenames or URLs. Decoding keeps only known slots, without
duplicates, in gallery order; the array is omitted when empty. The item editor
offers the saved gallery slots of the list being edited. Public rendering shows a
selected slot's photo beside the item's set thumbnails, and skips slots that are
currently empty. Clearing a gallery slot also unselects it from every item in the
editor, so refilling the slot later does not reselect it; the change is stored
with the next list save.

The gallery file fields are protected, and a published list's photo files are
reachable under the record's view rule even when no item selects them. Item
`photos` only control presentation; they are not an access list.

`title` is required for every item and is shown as its heading. `type` is `set` (the default), `altbuild`, or `moc`. Set and alternate-build
items require at least one code; MOCs may have zero or more codes. The chosen
service links are generated for each supplied code, including MOC codes.
`description` and `url` are optional; the URL is stored and rendered only when
it is an absolute HTTP or HTTPS URL. Item and list Markdown are rendered by the
safe Markdown renderer and have a lightweight formatting toolbar with preview.
Array position remains the explicit display order.

The optional `catalog` object stores a selected `rebrickable` suggestion and
optional `brickset` enrichment: provider, the item's first valid lookup code,
provider name, optional year and piece count, and optional thumbnail URL. A
suggestion fills the item title and code; changing the first valid code clears
the snapshot. Decoding drops malformed snapshots and snapshots for a different
code; encoding validates the same constraints and permits only approved provider
image hosts or PocketBase-hosted thumbnail URLs. Public list rendering uses this
stored data and never requests provider APIs. Brickset thumbnails are app-encoded
WebP files with dimensions no larger than 256×256, cached in `table_thumbnails`.

The frontend maps these service values to LEGO.com set search, Brickset's set
page, BrickLink's catalog item page, and Rebrickable's set page
(`https://rebrickable.com/sets/{code}/`, with the code percent-encoded). The
`rebrickable` value is stored as a plain string in the `services` array, so no
schema change or migration is needed. Unknown service strings are ignored by
the decoder so a future service addition does not break existing records. The
decoder intentionally does not accept the former `{ "code", "services" }`
format: local development data is replaced as a collection, not migrated.

`table_catalogs.content` stores the whole-list Markdown text. It is rendered
directly beneath the list title. The former PocketBase field name `markdown` is
not read or written.

`table_catalogs.status` is `draft` or `published`. The collection's list/view rules
permit published reads and owner reads. Create requires the authenticated user
id in `owner`; update and delete are restricted to the owner, and update rejects
owner changes.

The top-level `description` field remains in the record schema and is preserved
when editing existing lists, but is currently hidden from the UI. The list-level
`content` field is Markdown, labeled “Kuvaus”, and appears directly below the
list title.

`owner` is included in PocketBase record responses, including public reads of
published lists. The rules restrict which records can be read; they do not mask
the owner field on an otherwise readable published record.

The current PocketBase migration sets `items.maxSize` to 100,000 bytes. This is
unchanged by the frontend feature. It is adequate for ordinary list data, but
collections with extensive item descriptions or many entries may require a
larger max size when the development collection is replaced.
