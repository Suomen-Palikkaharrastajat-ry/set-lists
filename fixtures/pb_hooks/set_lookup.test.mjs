import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import vm from 'node:vm'

// Harness that emulates how PocketBase's JSVM runs set_lookup.pb.js:
//   1. the *.pb.js file is evaluated once to register routes;
//   2. each handler is serialized (Function#toString) and executed as its own
//      program in a fresh context, so it cannot see top-level declarations of
//      the hook file;
//   3. handlers pull shared code in via require(`${__hooks}/...`).
// $app.store() is process-wide and shared by all contexts.

const HOOKS_DIR = '/pb_hooks'
const hookSource = await readFile(new URL('./set_lookup.pb.js', import.meta.url), 'utf8')
const libSource = await readFile(new URL('./set_lookup_lib.js', import.meta.url), 'utf8')

function createStore() {
  const values = new Map()
  return {
    get: (key) => values.get(key) ?? null,
    keys: () => Array.from(values.keys()),
    remove: (key) => values.delete(key),
    set: (key, value) => values.set(key, value),
    // Mirrors PocketBase's Store.SetFunc: a missing key yields a nil (null) old value.
    setFunc(key, update) {
      values.set(key, update(values.has(key) ? values.get(key) : null))
    },
  }
}

function createApp(store) {
  return {
    store: () => store,
    settings: () => ({ meta: { appURL: 'https://data.palikkaharrastajat.fi' } }),
  }
}

function createGlobals({ env, send, now, app }) {
  class MockDate extends Date {
    static now() { return now() }
  }
  return {
    __hooks: HOOKS_DIR,
    $app: app,
    $apis: { requireAuth: (...collections) => ({ authCollections: collections }) },
    $os: { getenv: (name) => env[name] || '' },
    $http: { send },
    Date: MockDate,
  }
}

// A goja_nodejs-style require that evaluates modules inside the calling VM.
function installRequire(context) {
  const cache = new Map()
  context.require = (path) => {
    if (path !== `${HOOKS_DIR}/set_lookup_lib.js`) throw new Error(`Unexpected require: ${path}`)
    if (!cache.has(path)) {
      const module = { exports: {} }
      const wrapper = vm.runInContext(`(function (module, exports) {\n${libSource}\n})`, context, { filename: 'set_lookup_lib.js' })
      wrapper(module, module.exports)
      cache.set(path, module.exports)
    }
    return cache.get(path)
  }
}

function loadHooks({
  env = {},
  send = () => { throw new Error('Unexpected network call') },
  store = createStore(),
  now = () => Date.now(),
  app = {},
} = {}) {
  const fullApp = { ...createApp(store), ...app, store: () => store }
  const registered = {}
  const loader = vm.createContext({
    ...createGlobals({ env, send, now, app: fullApp }),
    routerAdd(method, path, handler, ...middlewares) {
      registered[path] = { method, path, handler, middlewares }
    },
  })
  vm.runInContext(hookSource, loader, { filename: 'set_lookup.pb.js' })

  const routes = {}
  for (const [path, route] of Object.entries(registered)) {
    const isolated = vm.createContext(createGlobals({ env, send, now, app: fullApp }))
    installRequire(isolated)
    const handler = vm.runInContext(`(${route.handler.toString()})`, isolated, { filename: `handler:${path}` })
    routes[path] = { ...route, handler }
  }
  return routes
}

function loadHook(options) {
  const routes = loadHooks(options)
  const route = routes['/api/set-lists/lookup']
  route.searchRoute = routes['/api/set-lists/search']
  route.thumbnailRoute = routes['/api/set-lists/thumbnail-source']
  return route
}

function request(route, query, userId = 'test-user') {
  let response
  route.handler({
    auth: { id: userId },
    request: { host: 'pb.example.test', url: { query: () => ({ get: (name) => query[name] || '' }) } },
    realIP: () => { throw new Error('The authenticated route must not use realIP') },
    json: (status, body) => {
      response = { status, body }
      return response
    },
    blob: (status, contentType, body) => {
      response = { status, contentType, body }
      return response
    },
    response: { header: () => ({ set: () => {} }) },
  })
  return JSON.parse(JSON.stringify(response))
}

// ---------------------------------------------------------------------------
// New coverage for the fixed hooks.
// ---------------------------------------------------------------------------

test('handlers do not depend on hook-file top-level scope (PocketBase isolation)', () => {
  assert.doesNotMatch(hookSource, /^(const|let|var|function)\s/m)
  const route = loadHook({ env: { REBRICKABLE_API_KEY: 'not-a-real-value' }, send: () => ({ statusCode: 404 }) })
  assert.equal(request(route, { provider: 'rebrickable', code: '75192-1' }).status, 404)
})

test('Brickset sends an empty top-level userHash and reads v3 nested image URLs', () => {
  let sent
  const route = loadHook({
    env: { BRICKSET_API_KEY: 'not-a-real-value' },
    send: (config) => {
      sent = config
      return {
        statusCode: 200,
        json: {
          status: 'success',
          matches: 1,
          sets: [{
            number: '10179',
            numberVariant: 1,
            name: 'Ultimate Collector\'s Millennium Falcon',
            year: 2007,
            pieces: 5195,
            image: {
              thumbnailURL: 'https://images.brickset.com/sets/small/10179-1.jpg',
              imageURL: 'https://images.brickset.com/sets/images/10179-1.jpg',
            },
          }],
        },
      }
    },
  })
  const response = request(route, { provider: 'brickset', code: '10179-1' })
  assert.equal(response.status, 200)
  assert.equal(response.body.imageUrl, 'https://images.brickset.com/sets/small/10179-1.jpg')
  assert.equal(response.body.thumbnailSource, undefined)
  const postBody = new URLSearchParams(sent.body)
  assert.equal(postBody.has('userHash'), true)
  assert.equal(postBody.get('userHash'), '')
  assert.equal(JSON.parse(postBody.get('params')).userHash, undefined)
})

test('Brickset lookups never fetch provider images server-side', () => {
  const urls = []
  const route = loadHook({
    env: { BRICKSET_API_KEY: 'not-a-real-value' },
    send: (config) => {
      urls.push(config.url)
      return {
        statusCode: 200,
        json: { status: 'success', sets: [{ number: '75192', numberVariant: 1, name: 'Falcon', image: { imageURL: 'https://images.brickset.com/sets/images/75192-1.jpg' } }] },
      }
    },
  })
  assert.equal(
    request(route, { provider: 'brickset', code: '75192-1' }).body.imageUrl,
    'https://images.brickset.com/sets/images/75192-1.jpg',
  )
  assert.deepEqual(urls, ['https://brickset.com/api/v3.asmx/getSets'])
})

test('Brickset API errors reported as HTTP 200 are unavailable and not cached', () => {
  let calls = 0
  const route = loadHook({
    env: { BRICKSET_API_KEY: 'not-a-real-value' },
    send: () => {
      calls += 1
      return { statusCode: 200, json: { status: 'error', message: 'Invalid API key' } }
    },
  })
  for (let attempt = 0; attempt < 2; attempt += 1) {
    assert.deepEqual(request(route, { provider: 'brickset', code: '75192-1' }), {
      status: 503,
      body: { error: 'lookup_unavailable' },
    })
  }
  assert.equal(calls, 2)
})

test('a bare set number is normalized to variant 1', () => {
  let sent
  const route = loadHook({
    env: { REBRICKABLE_API_KEY: 'not-a-real-value' },
    send: (config) => {
      sent = config
      return { statusCode: 200, json: { set_num: '75192-1', name: 'Millennium Falcon', year: 2017 } }
    },
  })
  const response = request(route, { provider: 'rebrickable', code: ' 75192 ' })
  assert.equal(response.status, 200)
  assert.equal(sent.url, 'https://rebrickable.com/api/v3/lego/sets/75192-1/')
  assert.equal(response.body.year, 2017)
})

test('search results are cached as JSON values (not double-encoded strings)', () => {
  const store = createStore()
  let calls = 0
  const env = { REBRICKABLE_API_KEY: 'not-a-real-value' }
  const send = () => {
    calls += 1
    return { statusCode: 200, json: { results: [{ set_num: '75192-1', name: 'Millennium Falcon' }, { set_num: 'fig-000001', name: 'Minifig' }] } }
  }
  const first = loadHook({ env, store, send }).searchRoute
  const second = loadHook({ env, store }).searchRoute
  const firstResponse = request(first, { q: 'Falcon' })
  assert.equal(firstResponse.status, 200)
  assert.equal(Array.isArray(firstResponse.body), true)
  assert.deepEqual(request(second, { q: 'falcon' }), firstResponse)
  assert.equal(calls, 1)
})

test('search treats a malformed Rebrickable response as unavailable', () => {
  const route = loadHook({ env: { REBRICKABLE_API_KEY: 'x' }, send: () => ({ statusCode: 200, json: { detail: 'Invalid token.' } }) }).searchRoute
  assert.deepEqual(request(route, { q: 'Falcon' }), { status: 503, body: { error: 'lookup_unavailable' } })
})

test('proxies only approved provider thumbnails for authenticated app-side WebP conversion', () => {
  let sent
  const route = loadHook({
    send: (config) => {
      sent = config
      return {
        statusCode: 200,
        headers: { 'Content-Type': ['image/jpeg; charset=binary'] },
        body: [255, 216, 255],
      }
    },
  }).thumbnailRoute
  const result = request(route, { url: 'https://images.brickset.com/sets/small/75192-1.jpg' })
  assert.deepEqual(result, { status: 200, contentType: 'image/jpeg', body: [255, 216, 255] })
  assert.equal(sent.url, 'https://images.brickset.com/sets/small/75192-1.jpg')
  assert.equal(sent.timeout, 5)

  const rebrickableImage = 'https://cdn.rebrickable.com/media/sets/75192-1.jpg'
  assert.equal(request(route, { url: rebrickableImage }).status, 200)
  assert.equal(sent.url, rebrickableImage)

  let called = false
  const invalidRoute = loadHook({ send: () => { called = true } }).thumbnailRoute
  assert.equal(request(invalidRoute, { url: 'https://attacker.invalid/image.jpg' }).status, 400)
  assert.equal(request(invalidRoute, { url: 'https://images.brickset.com.attacker.invalid/image.jpg' }).status, 400)
  assert.equal(called, false)
})

test('thumbnail proxy rejects non-image upstream responses and oversized bodies', () => {
  const htmlRoute = loadHook({
    send: () => ({ statusCode: 200, headers: { 'Content-Type': ['text/html'] }, body: [60, 104] }),
  }).thumbnailRoute
  assert.deepEqual(request(htmlRoute, { url: 'https://images.brickset.com/sets/small/75192-1.jpg' }), {
    status: 503,
    body: { error: 'thumbnail_unavailable' },
  })

  const largeRoute = loadHook({
    send: () => ({ statusCode: 200, headers: { 'Content-Type': ['image/png'] }, body: new Array(1000001).fill(0) }),
  }).thumbnailRoute
  assert.deepEqual(request(largeRoute, { url: 'https://images.brickset.com/sets/small/75192-1.jpg' }), {
    status: 503,
    body: { error: 'thumbnail_unavailable' },
  })
})

test('thumbnail proxy requires the users auth collection and shares the per-user limit', () => {
  const store = createStore()
  const first = loadHook({ store, send: () => ({ statusCode: 200, headers: { 'Content-Type': ['image/webp'] }, body: [82] }) })
  assert.deepEqual(Array.from(first.thumbnailRoute.middlewares[0].authCollections), ['users'])
  for (let index = 0; index < 60; index += 1) {
    assert.equal(request(first.thumbnailRoute, { url: 'https://images.brickset.com/sets/small/75192-1.jpg' }, 'same-user').status, 200)
  }
  assert.deepEqual(request(first.thumbnailRoute, { url: 'https://images.brickset.com/sets/small/75192-1.jpg' }, 'same-user'), {
    status: 429,
    body: { error: 'rate_limited' },
  })
})

// ---------------------------------------------------------------------------
// Original pb_hooks suite (behaviour preserved).
// ---------------------------------------------------------------------------

test('registers the GET route with PocketBase users-only auth middleware', () => {
  const route = loadHook()
  assert.equal(route.method, 'GET')
  assert.equal(route.path, '/api/set-lists/lookup')
  assert.deepEqual(Array.from(route.middlewares[0].authCollections), ['users'])
  assert.equal(route.searchRoute.method, 'GET')
  assert.equal(route.searchRoute.path, '/api/set-lists/search')
  assert.deepEqual(Array.from(route.searchRoute.middlewares[0].authCollections), ['users'])
  assert.equal(route.thumbnailRoute.method, 'GET')
  assert.equal(route.thumbnailRoute.path, '/api/set-lists/thumbnail-source')
  assert.deepEqual(Array.from(route.thumbnailRoute.middlewares[0].authCollections), ['users'])
})

test('searches Rebrickable and returns at most eight normalized suggestions', () => {
  let sent
  const route = loadHook({
    env: { REBRICKABLE_API_KEY: 'not-a-real-value' },
    send: (config) => {
      sent = config
      return {
        statusCode: 200,
        json: {
          results: Array.from({ length: 10 }, (_, index) => ({
            set_num: `${70000 + index}-1`,
            name: `Set ${index}`,
            year: 2020,
            num_parts: 100 + index,
            set_img_url: 'https://cdn.rebrickable.com/media/sets/70000-1.jpg',
          })),
        },
      }
    },
  })
  const response = request(route.searchRoute, { q: ' Falcon ' })
  assert.equal(response.status, 200)
  assert.equal(response.body.length, 8)
  assert.deepEqual(response.body[0], {
    code: '70000-1',
    name: 'Set 0',
    year: 2020,
    pieces: 100,
    imageUrl: 'https://cdn.rebrickable.com/media/sets/70000-1.jpg',
    sourceUrl: 'https://rebrickable.com/sets/70000-1/',
  })
  assert.match(sent.url, /search=Falcon/)
  assert.match(sent.url, /page_size=8/)
  assert.match(sent.headers.Authorization, /^key /)
  assert.equal(sent.timeout, 5)
})

test('rejects short search queries and reports missing search credentials', () => {
  const route = loadHook().searchRoute
  assert.equal(request(route, { q: 'a' }).status, 400)
  assert.deepEqual(request(route, { q: 'Falcon' }), {
    status: 503,
    body: { error: 'lookup_not_configured' },
  })
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
  let imageRequest
  const route = loadHook({
    env: { BRICKSET_API_KEY: 'not-a-real-value' },
    send: (config) => {
      if (config.url === 'https://brickset.com/api/v3.asmx/getSets') {
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
                thumbnailURL: 'https://images.brickset.com/sets/small/75192-1.jpg',
              },
            ],
          },
        }
      }
      imageRequest = config
      return { statusCode: 200, headers: { 'Content-Type': ['image/jpeg'] }, body: [255, 216, 255] }
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
    imageUrl: 'https://images.brickset.com/sets/small/75192-1.jpg',
    sourceUrl: 'https://brickset.com/sets/75192-1',
  })
  assert.equal(imageRequest, undefined)
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
  for (let index = 0; index < 60; index += 1) {
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
