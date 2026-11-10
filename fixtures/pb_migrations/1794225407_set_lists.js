/// <reference path="../pb_data/types.d.ts" />
// Private-by-default owned set lists. Only published lists are public; owners
// can read and manage their own drafts and published records.
migrate((app) => {
  const lists = new Collection({
    "name": "set_lists",
    "type": "base",
    "listRule": "status = \"published\" || owner = @request.auth.id",
    "viewRule": "status = \"published\" || owner = @request.auth.id",
    "createRule": "@request.auth.id != \"\" && @request.body.owner = @request.auth.id",
    "updateRule": "owner = @request.auth.id && @request.body.owner:changed = false",
    "deleteRule": "owner = @request.auth.id",
    "fields": [
      { "id": "text_set_lists_title", "name": "title", "type": "text", "required": true, "presentable": true, "min": 1, "max": 200 },
      { "id": "text_set_lists_description", "name": "description", "type": "text", "max": 2000 },
      { "id": "text_set_lists_markdown", "name": "markdown", "type": "text", "max": 50000 },
      // Each ordered entry stores a title, codes, type, selected services, and
      // optional Markdown description, reference URL, and catalog metadata
      // snapshot (provider, code, name, year, pieces, imageUrl) as JSON.
      { "id": "json_set_lists_items", "name": "items", "type": "json", "maxSize": 100000 },
      { "id": "select_set_lists_status", "name": "status", "type": "select", "required": true, "maxSelect": 1, "values": ["draft", "published"] },
      { "id": "text_set_lists_owner", "name": "owner", "type": "text", "required": true, "min": 1, "max": 20 },
      { "id": "autodate_set_lists_created", "name": "created", "type": "autodate", "onCreate": true, "onUpdate": false },
      { "id": "autodate_set_lists_updated", "name": "updated", "type": "autodate", "onCreate": true, "onUpdate": true }
    ],
    "indexes": [
      "CREATE INDEX `idx_set_lists_owner` ON `set_lists` (`owner`)",
      "CREATE INDEX `idx_set_lists_status` ON `set_lists` (`status`)"
    ]
  })
  app.save(lists)
}, (app) => {
  app.delete(app.findCollectionByNameOrId("set_lists"))
})
