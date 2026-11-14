/// <reference path="../pb_data/types.d.ts" />
// Optional, protected browser-resized WebP gallery photos 06-10 for table catalogs. Each slot follows
// the cover photo's file rules and is authorized by the collection view rule.
const GALLERY_SLOTS = ["photo_06", "photo_07", "photo_08", "photo_09", "photo_10"]

migrate((app) => {
  const catalogs = app.findCollectionByNameOrId("table_catalogs")
  for (const slot of GALLERY_SLOTS) {
    catalogs.fields.add(new FileField({
      "id": `file_table_catalogs_${slot}`,
      "name": slot,
      "maxSelect": 1,
      "maxSize": 200000,
      "mimeTypes": ["image/webp"],
      "protected": true
    }))
  }
  app.save(catalogs)
}, (app) => {
  const catalogs = app.findCollectionByNameOrId("table_catalogs")
  for (const slot of GALLERY_SLOTS) catalogs.fields.removeByName(slot)
  app.save(catalogs)
})
