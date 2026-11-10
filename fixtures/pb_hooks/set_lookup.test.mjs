import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import vm from 'node:vm'

const source = await readFile(new URL('./set_lookup.pb.js', import.meta.url), 'utf8')

function createStore() {
  const values = new Map()
  return {
    get: (key) => values.get(key) || '',
    keys: () => Array.from(values.keys()),
    remove: (key) => values.delete(key),
    set: (key, value) => values.set(key, value),
    setFunc(key, update) {
      values.set(key, update(values.get(key) || ''))
    },
  }
}

function loadHook({
  env = {},
  send = () => { throw new Error('Unexpected network call') },
  store = createStore(),
  now = () => Date.now(),
} = {}) {
  let route
  class MockDate extends Date {
    static now() { return now() }
  }
  const context = {
    routerAdd(method, path, handler, ...middlewares) {
      route = { method, path, handler, middlewares }
    },
    $app: { store: () => store },
    $apis: { requireAuth: (...collections) => ({ authCollections: collections }) },
    $os: { getenv: (name) => env[name] || '' },
    $http: { send },
    Date: MockDate,
    JSON,
    Number,
    String,
    Array,
    Math,
  }
  vm.runInNewContext(source, context, { filename: 'set_lookup.pb.js' })
  return route
}

function request(route, query, userId = 'test-user') {
  let response
  route.handler({
    auth: { id: userId },
    request: { url: { query: () => ({ get: (name) => query[name] || '' }) } },
    realIP: () => { throw new Error('The authenticated route must not use realIP') },
    json: (status, body) => {
      response = { status, body }
      return response
    },
  })
  return JSON.parse(JSON.stringify(response))
}

test('registers the GET route with PocketBase users-only auth middleware', () => {
  const route = loadHook()
  assert.equal(route.method, 'GET')
  assert.equal(route.path, '/api/set-lists/lookup')
  assert.deepEqual(Array.from(route.middlewares[0].authCollections), ['users'])
})

test('returns 503 without a provider credential and does not call upstream', () => {
  let called = false
  const route = loadHook({ send: () => { called = true } })
  assert.deepEqual(request(route, { provider: 'rebrickable', code: '75192-1' }), {
    status: 503,
    body: { error: 'lookup_not_configured' },
  })
  assert.equal(called, false)
})

test('rejects unknown providers and non-canonical codes before any provider call', () => {
  let called = false
  const route = loadHook({ env: { REBRICKABLE_API_KEY: 'not-a-real-value' }, send: () => { called = true } })
  assert.equal(request(route, { provider: 'unknown', code: '75192-1' }).status, 400)
  assert.equal(request(route, { provider: 'rebrickable', code: 'MOC-123' }).status, 400)
  assert.equal(called, false)
})

test('normalizes Rebrickable fields and rejects an untrusted image URL', () => {
  let sent
  const route = loadHook({
    env: { REBRICKABLE_API_KEY: 'not-a-real-value' },
    send: (config) => {
      sent = config
      return {
        statusCode: 200,
        json: {
          set_num: '75192-1',
          name: `  ${'Falcon'.repeat(50)}  `,
          year: 1800,
          num_parts: 100001,
          set_img_url: 'https://images.attacker.invalid/image.jpg',
        },
      }
    },
  })
  const response = request(route, { provider: 'rebrickable', code: '75192-1' })
  assert.equal(response.status, 200)
  assert.equal(response.body.name.length, 200)
  assert.equal(response.body.year, null)
  assert.equal(response.body.pieces, null)
  assert.equal(response.body.imageUrl, null)
  assert.equal(response.body.sourceUrl, 'https://rebrickable.com/sets/75192-1/')
  assert.equal(sent.method, 'GET')
  assert.match(sent.headers.Authorization, /^key /)
  assert.equal(sent.timeout, 5)
  assert.equal(sent.url.includes('not-a-real-value'), false)
})

test('sends Brickset form-encoded POST parameters with the credential out of its URL', () => {
  let sent
  const route = loadHook({
    env: { BRICKSET_API_KEY: 'not-a-real-value' },
    send: (config) => {
      sent = config
      return {
        statusCode: 200,
        json: {
          status: 'success',
          sets: [
            {
              number: '75192',
              numberVariant: 1,
              name: 'Millennium Falcon',
              year: 2017,
              pieces: 7541,
              imageURL: 'https://images.brickset.com/sets/images/75192-1.jpg',
            },
          ],
        },
      }
    },
  })
  const response = request(route, { provider: 'brickset', code: '75192-1' })
  assert.equal(response.status, 200)
  const postBody = new URLSearchParams(sent.body)
  assert.equal(postBody.get('apiKey'), 'not-a-real-value')
  assert.deepEqual(JSON.parse(postBody.get('params')), { setNumber: '75192-1', extendedData: 0 })
  assert.equal(sent.method, 'POST')
  assert.equal(sent.headers['Content-Type'], 'application/x-www-form-urlencoded')
  assert.equal(sent.url, 'https://brickset.com/api/v3.asmx/getSets')
  assert.equal(sent.url.includes('not-a-real-value'), false)
  assert.equal(sent.timeout, 5)
  assert.deepEqual(JSON.parse(JSON.stringify(response.body)), {
    name: 'Millennium Falcon',
    year: 2017,
    pieces: 7541,
    imageUrl: 'https://images.brickset.com/sets/images/75192-1.jpg',
    sourceUrl: 'https://brickset.com/sets/75192-1',
  })
})

test('shares positive cache entries between independently loaded hook VMs for 30 minutes', () => {
  const store = createStore()
  let now = 100000
  let calls = 0
  const env = { REBRICKABLE_API_KEY: 'not-a-real-value' }
  const first = loadHook({
    env,
    store,
    now: () => now,
    send: () => {
      calls += 1
      return { statusCode: 200, json: { set_num: '75192-1', name: 'Millennium Falcon' } }
    },
  })
  const second = loadHook({ env, store, now: () => now })
  assert.equal(request(first, { provider: 'rebrickable', code: '75192-1' }).status, 200)
  now += 30 * 60 * 1000 - 1
  assert.equal(request(second, { provider: 'rebrickable', code: '75192-1' }).status, 200)
  assert.equal(calls, 1)

  now += 1
  const expired = loadHook({
    env,
    store,
    now: () => now,
    send: () => {
      calls += 1
      return { statusCode: 200, json: { set_num: '75192-1', name: 'Millennium Falcon' } }
    },
  })
  assert.equal(request(expired, { provider: 'rebrickable', code: '75192-1' }).status, 200)
  assert.equal(calls, 2)
})

test('shares per-user sliding-window rate limits across VMs without relying on realIP', () => {
  const store = createStore()
  const first = loadHook({ store })
  const second = loadHook({ store })
  for (let index = 0; index < 20; index += 1) {
    assert.equal(request(first, { provider: 'rebrickable', code: `${index}-1` }, 'same-user').status, 503)
  }
  assert.equal(request(second, { provider: 'rebrickable', code: '999-1' }, 'same-user').status, 429)
  assert.equal(request(second, { provider: 'rebrickable', code: '999-1' }, 'different-user').status, 503)
})

test('caches not-found results briefly across hook VMs', () => {
  const store = createStore()
  let now = 200000
  let calls = 0
  const env = { REBRICKABLE_API_KEY: 'not-a-real-value' }
  const first = loadHook({
    env,
    store,
    now: () => now,
    send: () => {
      calls += 1
      return { statusCode: 404, json: { detail: 'Not found' } }
    },
  })
  const second = loadHook({ env, store, now: () => now })
  assert.deepEqual(request(first, { provider: 'rebrickable', code: '75192-1' }), {
    status: 404,
    body: { error: 'not_found' },
  })
  now += 5 * 60 * 1000 - 1
  assert.equal(request(second, { provider: 'rebrickable', code: '75192-1' }).status, 404)
  assert.equal(calls, 1)

  now += 1
  const expired = loadHook({
    env,
    store,
    now: () => now,
      send: () => {
        calls += 1
        return { statusCode: 404, json: { detail: 'Not found' } }
    },
  })
  assert.equal(request(expired, { provider: 'rebrickable', code: '75192-1' }).status, 404)
  assert.equal(calls, 2)
})

test('Rebrickable has one global uncached request per second; cache hits do not use the quota', () => {
  const store = createStore()
  let now = 10000
  let calls = 0
  const env = { REBRICKABLE_API_KEY: 'not-a-real-value' }
  const route = loadHook({
    env,
    store,
    now: () => now,
    send: (config) => {
      calls += 1
      const code = config.url.match(/sets\/([^/]+)\//)[1]
      return { statusCode: 200, json: { set_num: code, name: `Set ${code}` } }
    },
  })
  const secondVm = loadHook({
    env,
    store,
    now: () => now,
    send: (config) => {
      calls += 1
      const code = config.url.match(/sets\/([^/]+)\//)[1]
      return { statusCode: 200, json: { set_num: code, name: `Set ${code}` } }
    },
  })
  assert.equal(request(route, { provider: 'rebrickable', code: '1-1' }).status, 200)
  now += 1000
  assert.equal(request(secondVm, { provider: 'rebrickable', code: '1-1' }).status, 200)
  now += 500
  assert.equal(request(secondVm, { provider: 'rebrickable', code: '2-1' }).status, 200)
  assert.deepEqual(request(route, { provider: 'rebrickable', code: '3-1' }), {
    status: 503,
    body: { error: 'lookup_unavailable' },
  })
  assert.equal(calls, 2)
})

test('Brickset has a global daily cap of 80, and cached results bypass the provider quota', () => {
  const store = createStore()
  let calls = 0
  const route = loadHook({
    env: { BRICKSET_API_KEY: 'not-a-real-value' },
    store,
    send: (config) => {
      calls += 1
      const params = JSON.parse(new URLSearchParams(config.body).get('params'))
      const [number, variant] = params.setNumber.split('-')
      return {
        statusCode: 200,
        json: {
          status: 'success',
          sets: [{ number, numberVariant: Number(variant), name: `Set ${number}` }],
        },
      }
    },
  })

  assert.equal(request(route, { provider: 'brickset', code: '1-1' }, 'quota-user-0').status, 200)
  for (let index = 2; index <= 80; index += 1) {
    assert.equal(request(route, { provider: 'brickset', code: `${index}-1` }, `quota-user-${index}`).status, 200)
  }
  const secondVm = loadHook({ env: { BRICKSET_API_KEY: 'not-a-real-value' }, store })
  assert.equal(request(secondVm, { provider: 'brickset', code: '1-1' }, 'cached-user').status, 200)
  assert.deepEqual(request(secondVm, { provider: 'brickset', code: '81-1' }, 'quota-user-81'), {
    status: 503,
    body: { error: 'lookup_unavailable' },
  })
  assert.equal(calls, 80)
})

test('returns generic not-found and upstream errors without exposing response details', () => {
  const notFound = loadHook({
    env: { REBRICKABLE_API_KEY: 'not-a-real-value' },
    send: () => ({ statusCode: 404, json: { detail: 'Not found' } }),
  })
  assert.deepEqual(request(notFound, { provider: 'rebrickable', code: '75192-1' }), {
    status: 404,
    body: { error: 'not_found' },
  })

  const unavailable = loadHook({
    env: { BRICKSET_API_KEY: 'not-a-real-value' },
    send: () => { throw new Error('sensitive provider response') },
  })
  assert.deepEqual(request(unavailable, { provider: 'brickset', code: '75192-1' }), {
    status: 503,
    body: { error: 'lookup_unavailable' },
  })
})

test('malformed or missing 200 JSON is unavailable and is never cached as not-found', () => {
  const malformedResponses = [
    {},
    { json: null },
    { json: [] },
    { json: 'unexpected' },
    { json: { set_num: '75192-1', name: '' } },
    { json: { set_num: 'different-code', name: 'Unexpected set' } },
  ]

  for (const response of malformedResponses) {
    let calls = 0
    let now = 10000
    const route = loadHook({
      env: { REBRICKABLE_API_KEY: 'not-a-real-value' },
      now: () => now,
      send: () => {
        calls += 1
        return { statusCode: 200, ...response }
      },
    })

    for (let attempt = 0; attempt < 2; attempt += 1) {
      assert.deepEqual(request(route, { provider: 'rebrickable', code: '75192-1' }), {
        status: 503,
        body: { error: 'lookup_unavailable' },
      })
      now += 1000
    }
    assert.equal(calls, 2)
  }

  const missingBricksetSets = loadHook({
    env: { BRICKSET_API_KEY: 'not-a-real-value' },
    send: () => ({ statusCode: 200, json: { status: 'success' } }),
  })
  assert.deepEqual(request(missingBricksetSets, { provider: 'brickset', code: '75192-1' }), {
    status: 503,
    body: { error: 'lookup_unavailable' },
  })
})

test('caches a valid Brickset success with an empty sets array as not-found', () => {
  const store = createStore()
  let calls = 0
  const env = { BRICKSET_API_KEY: 'not-a-real-value' }
  const first = loadHook({
    env,
    store,
    send: () => {
      calls += 1
      return { statusCode: 200, json: { status: 'success', sets: [] } }
    },
  })
  const second = loadHook({ env, store })

  const expected = { status: 404, body: { error: 'not_found' } }
  assert.deepEqual(request(first, { provider: 'brickset', code: '75192-1' }), expected)
  assert.deepEqual(request(second, { provider: 'brickset', code: '75192-1' }), expected)
  assert.equal(calls, 1)
})
