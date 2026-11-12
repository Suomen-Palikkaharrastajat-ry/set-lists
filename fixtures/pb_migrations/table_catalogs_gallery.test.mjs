import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, '1794463444_table_catalogs_gallery.js'), 'utf8')
const GALLERY_SLOTS = ['photo_01', 'photo_02', 'photo_03', 'photo_04', 'photo_05']

class FileField {
  constructor(options) {
    Object.assign(this, options)
  }
}

function loadMigration() {
  const registered = []
  new Function('migrate', 'FileField', source)((up, down) => registered.push({ up, down }), FileField)
  assert.equal(registered.length, 1)
  return registered[0]
}

function fakeApp(initialFieldNames) {
  const fields = new Map(initialFieldNames.map((name) => [name, { name }]))
  const saved = []
  const catalogs = {
    fields: {
      add(field) {
        fields.set(field.name, field)
      },
      removeByName(name) {
        fields.delete(name)
      },
    },
  }
  const app = {
    findCollectionByNameOrId(name) {
      assert.equal(name, 'table_catalogs')
      return catalogs
    },
    save(collection) {
      assert.equal(collection, catalogs)
      saved.push([...fields.keys()])
    },
  }
  return { app, fields, saved }
}

test('Given the gallery migration, when applied, then exactly five protected WebP file fields are added', () => {
  const { up } = loadMigration()
  const { app, fields, saved } = fakeApp(['title', 'photo'])

  up(app)

  assert.deepEqual([...fields.keys()], ['title', 'photo', ...GALLERY_SLOTS])
  assert.equal(saved.length, 1)
  for (const slot of GALLERY_SLOTS) {
    const field = fields.get(slot)
    assert.ok(field instanceof FileField)
    assert.equal(field.id, `file_table_catalogs_${slot}`)
    assert.equal(field.maxSelect, 1)
    assert.equal(field.maxSize, 200000)
    assert.deepEqual(field.mimeTypes, ['image/webp'])
    assert.equal(field.protected, true)
  }
})

test('Given the gallery migration, when reverted, then only the five gallery fields are removed', () => {
  const { down } = loadMigration()
  const { app, fields, saved } = fakeApp(['title', 'photo', ...GALLERY_SLOTS, 'photo_09'])

  down(app)

  assert.deepEqual([...fields.keys()], ['title', 'photo', 'photo_09'])
  assert.equal(saved.length, 1)
})

test('Given the gallery migration, when applied and reverted, then the schema returns to its original fields', () => {
  const { up, down } = loadMigration()
  const { app, fields } = fakeApp(['title', 'photo'])

  up(app)
  down(app)

  assert.deepEqual([...fields.keys()], ['title', 'photo'])
})
