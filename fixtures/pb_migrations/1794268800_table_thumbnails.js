/// <reference path="../pb_data/types.d.ts" />
// Public, code-keyed thumbnails cached from Brickset for selected catalog sets.
migrate((app) => {
  const thumbnails = new Collection({
    "name": "table_thumbnails",
    "type": "base",
    "listRule": "",
    "viewRule": "",
    "createRule": "@request.auth.id != \"\"",
    "updateRule": null,
    "deleteRule": null,
    "fields": [
      { "id": "text_table_thumbnails_code", "name": "code", "type": "text", "required": true, "min": 3, "max": 20 },
      { "id": "file_table_thumbnails_thumbnail", "name": "thumbnail", "type": "file", "required": true, "maxSelect": 1, "maxSize": 200000, "mimeTypes": ["image/webp"] }
    ],
    "indexes": [
      "CREATE UNIQUE INDEX `idx_table_thumbnails_code` ON `table_thumbnails` (`code`)"
    ]
  })
  app.save(thumbnails)
}, (app) => {
  app.delete(app.findCollectionByNameOrId("table_thumbnails"))
})
