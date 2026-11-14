import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, '1794637169_table_catalogs_gallery_10.js'), 'utf8')
const GALLERY_SLOTS_10 = ['photo_06', 'photo_07', 'photo_08', 'photo_09', 'photo_10']

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

test('Given the gallery 06-10 migration, when applied, then five protected WebP file fields are added', () => {
  const { up } = loadMigration()
  const { app, fields, saved } = fakeApp(['title', 'photo', 'photo_01', 'photo_02', 'photo_03', 'photo_04', 'photo_05'])

  up(app)

  assert.deepEqual([...fields.keys()], ['title', 'photo', 'photo_01', 'photo_02', 'photo_03', 'photo_04', 'photo_05', ...GALLERY_SLOTS_10])
  assert.equal(saved.length, 1)
  for (const slot of GALLERY_SLOTS_10) {
    const field = fields.get(slot)
    assert.ok(field instanceof FileField)
    assert.equal(field.id, `file_table_catalogs_${slot}`)
    assert.equal(field.maxSelect, 1)
    assert.equal(field.maxSize, 200000)
    assert.deepEqual(field.mimeTypes, ['image/webp'])
    assert.equal(field.protected, true)
  }
})

test('Given the gallery 06-10 migration, when reverted, then only the five new gallery fields are removed', () => {
  const { down } = loadMigration()
  const { app, fields, saved } = fakeApp(['title', 'photo', 'photo_01', 'photo_02', 'photo_03', 'photo_04', 'photo_05', ...GALLERY_SLOTS_10, 'other_field'])

  down(app)

  assert.deepEqual([...fields.keys()], ['title', 'photo', 'photo_01', 'photo_02', 'photo_03', 'photo_04', 'photo_05', 'other_field'])
  assert.equal(saved.length, 1)
})

test('Given the gallery 06-10 migration, when applied and reverted, then the schema returns to its original fields', () => {
  const { up, down } = loadMigration()
  const { app, fields } = fakeApp(['title', 'photo', 'photo_01', 'photo_02', 'photo_03', 'photo_04', 'photo_05'])

  up(app)
  down(app)

  assert.deepEqual([...fields.keys()], ['title', 'photo', 'photo_01', 'photo_02', 'photo_03', 'photo_04', 'photo_05'])
})
