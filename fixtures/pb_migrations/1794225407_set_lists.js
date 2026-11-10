/// <reference path="../pb_data/types.d.ts" />
// Private-by-default owned set lists. Only published lists are public; owners
// can read and manage their own drafts and published records.
migrate((app) => {
  const lists = new Collection({
    "name": "table_catalogs",
    "type": "base",
    "listRule": "status = \"published\" || owner = @request.auth.id",
    "viewRule": "status = \"published\" || owner = @request.auth.id",
    "createRule": "@request.auth.id != \"\" && @request.body.owner = @request.auth.id",
    "updateRule": "owner = @request.auth.id && @request.body.owner:changed = false",
    "deleteRule": "owner = @request.auth.id",
    "fields": [
      { "id": "text_table_catalogs_title", "name": "title", "type": "text", "required": true, "presentable": true, "min": 1, "max": 200 },
      { "id": "text_table_catalogs_description", "name": "description", "type": "text", "max": 2000 },
      { "id": "text_table_catalogs_markdown", "name": "markdown", "type": "text", "max": 50000 },
      // Each ordered entry stores a title, codes, type, selected services, and
      // optional Markdown description, reference URL, and catalog metadata
      // snapshot (provider, code, name, year, pieces, imageUrl) as JSON.
      { "id": "json_table_catalogs_items", "name": "items", "type": "json", "maxSize": 100000 },
      { "id": "select_table_catalogs_status", "name": "status", "type": "select", "required": true, "maxSelect": 1, "values": ["draft", "published"] },
      { "id": "text_table_catalogs_owner", "name": "owner", "type": "text", "required": true, "min": 1, "max": 20 },
      { "id": "autodate_table_catalogs_created", "name": "created", "type": "autodate", "onCreate": true, "onUpdate": false },
      { "id": "autodate_table_catalogs_updated", "name": "updated", "type": "autodate", "onCreate": true, "onUpdate": true }
    ],
    "indexes": [
      "CREATE INDEX `idx_table_catalogs_owner` ON `table_catalogs` (`owner`)",
      "CREATE INDEX `idx_table_catalogs_status` ON `table_catalogs` (`status`)"
    ]
  })
  app.save(lists)
}, (app) => {
  app.delete(app.findCollectionByNameOrId("table_catalogs"))
})
