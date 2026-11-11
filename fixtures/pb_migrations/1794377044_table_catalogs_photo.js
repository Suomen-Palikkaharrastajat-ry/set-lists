/// <reference path="../pb_data/types.d.ts" />
// Optional, protected browser-resized WebP cover image for a table catalog. Protected
// file requests use the collection view rule, keeping draft covers private.
migrate((app) => {
  const catalogs = app.findCollectionByNameOrId("table_catalogs")
  catalogs.fields.add(new FileField({
    "id": "file_table_catalogs_photo",
    "name": "photo",
    "maxSelect": 1,
    "maxSize": 200000,
    "mimeTypes": ["image/webp"],
    "protected": true
  }))
  app.save(catalogs)
}, (app) => {
  const catalogs = app.findCollectionByNameOrId("table_catalogs")
  catalogs.fields.removeByName("photo")
  app.save(catalogs)
})
