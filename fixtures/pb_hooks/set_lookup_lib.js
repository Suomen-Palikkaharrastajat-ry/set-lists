/// <reference path="../pb_data/types.d.ts" />
// Shared helpers for set_lookup.pb.js (Rebrickable + Brickset catalog lookups).
//
// PocketBase serializes every hook/route handler and runs it as an isolated
// program, so functions and constants declared at the top level of a *.pb.js
// file are NOT visible inside handlers. Everything the handlers need lives in
// this plain module (no ".pb.js" suffix, so PocketBase does not auto-load it)
// and is pulled in with `require(`${__hooks}/set_lookup_lib.js`)` inside each
// handler.
//
// Provider credentials are read only from the PocketBase process environment
// (REBRICKABLE_API_KEY, BRICKSET_API_KEY) and are never logged or returned.
//
// Keep this module stateless: all shared state (cache, rate limits, quotas)
// goes through $app.store(), which is process-wide and shared by every JSVM.

const STORE_PREFIX = "set-lookup:v2:"
// Use a new cache payload version after changing the thumbnail flow. Keep rate
// and quota keys on v2 so deploying this update doesn't reset provider limits.
const CACHE_KEY = "set-lookup:v3:cache"
const BRICKSET_QUOTA_KEY = STORE_PREFIX + "quota:brickset"
const REBRICKABLE_LIMIT_KEY = STORE_PREFIX + "limit:rebrickable"

const CACHE_TTL = 30 * 60 * 1000
const NEGATIVE_CACHE_TTL = 5 * 60 * 1000
const CACHE_MAX = 200
const RATE_WINDOW = 60 * 1000
const RATE_MAX = 60
// Brickset allows 100 getSets calls per key per day; leave headroom.
const BRICKSET_DAILY_MAX = 80
// Rebrickable throttles at roughly one request per second per key.
const REBRICKABLE_INTERVAL = 1000
const HTTP_TIMEOUT = 5 // seconds ($http.send timeout unit)

const SEARCH_MIN_LENGTH = 2
const SEARCH_MAX_LENGTH = 80
const SEARCH_MAX_RESULTS = 8
const THUMBNAIL_MAX_BYTES = 1000000

// LEGO sets go back to 1949.
const MIN_YEAR = 1949

// Canonical "number-variant" codes, e.g. 75192-1. A bare number ("75192") is
// accepted by parseCode() and normalized to variant 1.
const CODE = /^[0-9]{1,6}-[0-9]{1,3}$/
const BARE_NUMBER = /^[0-9]{1,6}$/

const PROVIDERS = ["rebrickable", "brickset"]

function store() {
  return $app.store()
}

function json(e, status, body) {
  return e.json(status, body)
}

function trimmed(value, maxLength) {
  if (typeof value !== "string") return ""
  return value.trim().slice(0, maxLength)
}

function integer(value, min, max) {
  if (value === null || value === undefined || value === "") return null
  const number = typeof value === "number" ? value : Number(value)
  if (!Number.isInteger(number) || number < min || number > max) return null
  return number
}

function year(value) {
  return integer(value, MIN_YEAR, new Date().getUTCFullYear() + 2)
}

function pieces(value) {
  return integer(value, 0, 100000)
}

function parseCode(value) {
  const code = trimmed(value, 16)
  if (BARE_NUMBER.test(code)) return code + "-1"
  return CODE.test(code) ? code : ""
}

function isProvider(value) {
  return PROVIDERS.indexOf(value) !== -1
}

function safeImage(value, provider) {
  const imageUrl = trimmed(value, 1000)
  if (!imageUrl || /[\u0000-\u0020\u007f]/.test(imageUrl)) return null

  const allowedPrefixes = provider === "rebrickable"
    ? ["https://cdn.rebrickable.com/"]
    : ["https://images.brickset.com/", "https://brickset.com/", "https://www.brickset.com/"]

  return allowedPrefixes.some((prefix) => imageUrl.startsWith(prefix)) ? imageUrl : null
}

function sourceUrl(provider, code) {
  return provider === "rebrickable"
    ? `https://rebrickable.com/sets/${encodeURIComponent(code)}/`
    : `https://brickset.com/sets/${code}`
}

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

// ---------------------------------------------------------------------------
// Provider response validation / normalization
// ---------------------------------------------------------------------------

// Brickset v3 nests image URLs in `image: { imageURL, thumbnailURL }`; accept
// the flat layout too.
function bricksetImages(set) {
  const image = isPlainObject(set.image) ? set.image : {}
  return {
    full: safeImage(image.imageURL, "brickset") || safeImage(set.imageURL, "brickset"),
    small: safeImage(image.thumbnailURL, "brickset") || safeImage(set.thumbnailURL, "brickset"),
  }
}

function bricksetCode(set) {
  const number = typeof set.number === "number" ? String(set.number) : trimmed(set.number, 16)
  const variant = integer(set.numberVariant, 1, 999) || 1
  return `${number}-${variant}`
}

// A response is "valid" when it is a well-formed answer from the provider,
// whether or not it contains the requested set. Invalid responses map to 503
// and are never cached.
function validResponse(provider, code, data) {
  if (!isPlainObject(data)) return false

  if (provider === "rebrickable") {
    return data.set_num === code && trimmed(data.name, 200) !== ""
  }

  // Brickset reports API errors (bad key, quota exceeded, ...) as HTTP 200
  // with { status: "error", message }.
  return data.status === "success"
    && Array.isArray(data.sets)
    && data.sets.every((set) => {
      if (!isPlainObject(set)) return false
      const validNumber = typeof set.number === "string"
        ? set.number.trim() !== ""
        : typeof set.number === "number" && Number.isFinite(set.number)
      return validNumber && trimmed(set.name, 200) !== ""
    })
}

function normalize(provider, code, data) {
  if (provider === "rebrickable") {
    if (!isPlainObject(data) || data.set_num !== code) return null
    const name = trimmed(data.name, 200)
    if (!name) return null
    return {
      name,
      year: year(data.year),
      pieces: pieces(data.num_parts),
      imageUrl: safeImage(data.set_img_url, provider),
      sourceUrl: sourceUrl(provider, code),
    }
  }

  const sets = isPlainObject(data) && Array.isArray(data.sets) ? data.sets : []
  const set = sets.find((item) => isPlainObject(item) && bricksetCode(item) === code)
  if (!set) return null
  const name = trimmed(set.name, 200)
  if (!name) return null
  const images = bricksetImages(set)
  return {
    name,
    year: year(set.year),
    pieces: pieces(set.pieces),
    imageUrl: images.small || images.full,
    sourceUrl: sourceUrl(provider, code),
  }
}

function normalizeSearch(data) {
  const rows = isPlainObject(data) && Array.isArray(data.results) ? data.results : []
  const results = []
  for (let index = 0; index < rows.length && results.length < SEARCH_MAX_RESULTS; index += 1) {
    const set = rows[index]
    if (!isPlainObject(set)) continue
    const code = trimmed(set.set_num, 16)
    const name = trimmed(set.name, 200)
    if (!CODE.test(code) || !name) continue
    results.push({
      code,
      name,
      year: year(set.year),
      pieces: pieces(set.num_parts),
      imageUrl: safeImage(set.set_img_url, "rebrickable"),
      sourceUrl: sourceUrl("rebrickable", code),
    })
  }
  return results
}

// ---------------------------------------------------------------------------
// Shared store helpers (cache, per-user rate limit, provider quotas)
// ---------------------------------------------------------------------------

function parseJson(value, fallback) {
  if (typeof value !== "string" || !value) return fallback
  try {
    return JSON.parse(value)
  } catch (_) {
    return fallback
  }
}

function readCache(value, now) {
  const parsed = parseJson(value, {})
  const cache = isPlainObject(parsed) ? parsed : {}
  Object.keys(cache).forEach((key) => {
    if (!isPlainObject(cache[key]) || !(cache[key].expiresAt > now)) delete cache[key]
  })
  return cache
}

function cached(key) {
  const now = Date.now()
  let entry = null
  store().setFunc(CACHE_KEY, (value) => {
    const cache = readCache(value, now)
    if (cache[key]) {
      // Refresh insertion order for a bounded LRU cache.
      entry = cache[key]
      delete cache[key]
      cache[key] = entry
    }
    return JSON.stringify(cache)
  })
  return entry
}

function cacheResult(key, status, body, ttl) {
  const now = Date.now()
  store().setFunc(CACHE_KEY, (value) => {
    const cache = readCache(value, now)
    delete cache[key]
    cache[key] = { status, body, expiresAt: now + ttl }
    const keys = Object.keys(cache)
    while (keys.length > CACHE_MAX) delete cache[keys.shift()]
    return JSON.stringify(cache)
  })
}

function rateAllowed(userId) {
  const now = Date.now()
  const cutoff = now - RATE_WINDOW
  let allowed = false
  store().setFunc(STORE_PREFIX + "rate:user:" + userId, (value) => {
    const prior = parseJson(value, [])
    const recent = Array.isArray(prior)
      ? prior.filter((timestamp) => typeof timestamp === "number" && timestamp > cutoff)
      : []
    allowed = recent.length < RATE_MAX
    if (allowed) recent.push(now)
    return JSON.stringify(recent)
  })
  return allowed
}

function rebrickableAllowed(now) {
  let allowed = false
  store().setFunc(REBRICKABLE_LIMIT_KEY, (value) => {
    const previous = typeof value === "string" && value ? Number(value) : NaN
    if (!Number.isFinite(previous) || now - previous >= REBRICKABLE_INTERVAL) {
      allowed = true
      return String(now)
    }
    return String(previous)
  })
  return allowed
}

function bricksetAllowed(now) {
  const day = new Date(now).toISOString().slice(0, 10)
  let allowed = false
  store().setFunc(BRICKSET_QUOTA_KEY, (value) => {
    const quota = parseJson(value, {})
    const current = isPlainObject(quota) && quota.day === day && Number.isInteger(quota.count)
      ? quota.count
      : 0
    allowed = current < BRICKSET_DAILY_MAX
    return JSON.stringify({ day, count: allowed ? current + 1 : current })
  })
  return allowed
}

function providerAllowed(provider, now) {
  return provider === "rebrickable" ? rebrickableAllowed(now) : bricksetAllowed(now)
}

function apiKey(provider) {
  return $os.getenv(provider === "rebrickable" ? "REBRICKABLE_API_KEY" : "BRICKSET_API_KEY")
}

// ---------------------------------------------------------------------------
// Upstream requests
// ---------------------------------------------------------------------------

function fetchSet(provider, code, key) {
  if (provider === "rebrickable") {
    // https://rebrickable.com/api/v3/docs/ — key goes in the Authorization
    // header, never the URL.
    return $http.send({
      method: "GET",
      url: `https://rebrickable.com/api/v3/lego/sets/${encodeURIComponent(code)}/`,
      headers: { Authorization: `key ${key}`, Accept: "application/json" },
      timeout: HTTP_TIMEOUT,
    })
  }

  // Brickset API v3 (ASMX): POST form fields apiKey, userHash, params. All
  // declared parameters must be present for the HTTP POST binding, so send an
  // empty userHash for anonymous lookups. Keep the key in the body so it never
  // lands in URLs or access logs.
  return $http.send({
    method: "POST",
    url: "https://brickset.com/api/v3.asmx/getSets",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
    body: "apiKey=" + encodeURIComponent(key)
      + "&userHash="
      + "&params=" + encodeURIComponent(JSON.stringify({ setNumber: code, extendedData: 0 })),
    timeout: HTTP_TIMEOUT,
  })
}

function fetchSearch(query, key) {
  return $http.send({
    method: "GET",
    url: "https://rebrickable.com/api/v3/lego/sets/?search=" + encodeURIComponent(query)
      + "&page_size=" + SEARCH_MAX_RESULTS,
    headers: { Authorization: `key ${key}`, Accept: "application/json" },
    timeout: HTTP_TIMEOUT,
  })
}

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------

function handleLookup(e) {
  const query = e.request.url.query()
  const provider = query.get("provider")
  const code = parseCode(query.get("code"))

  if (!isProvider(provider)) return json(e, 400, { error: "invalid_provider" })
  if (!code) return json(e, 400, { error: "invalid_code" })

  if (!rateAllowed(e.auth.id)) return json(e, 429, { error: "rate_limited" })

  const cacheKey = `lookup:${provider}:${code}`
  const hit = cached(cacheKey)
  if (hit) return json(e, hit.status, hit.body)

  const key = apiKey(provider)
  if (!key) return json(e, 503, { error: "lookup_not_configured" })

  if (!providerAllowed(provider, Date.now())) {
    return json(e, 503, { error: "lookup_unavailable" })
  }

  try {
    const response = fetchSet(provider, code, key)
    if (response.statusCode === 404) {
      const body = { error: "not_found" }
      cacheResult(cacheKey, 404, body, NEGATIVE_CACHE_TTL)
      return json(e, 404, body)
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return json(e, 503, { error: "lookup_unavailable" })
    }
    if (!validResponse(provider, code, response.json)) {
      return json(e, 503, { error: "lookup_unavailable" })
    }

    const result = normalize(provider, code, response.json)
    if (!result) {
      const body = { error: "not_found" }
      cacheResult(cacheKey, 404, body, NEGATIVE_CACHE_TTL)
      return json(e, 404, body)
    }

    cacheResult(cacheKey, 200, result, CACHE_TTL)
    return json(e, 200, result)
  } catch (_) {
    // Provider response and request errors may contain credentials or request
    // details. Return a fixed message and do not log them.
    return json(e, 503, { error: "lookup_unavailable" })
  }
}

function handleSearch(e) {
  const query = e.request.url.query()
  const search = trimmed(query.get("q"), SEARCH_MAX_LENGTH)
  if (search.length < SEARCH_MIN_LENGTH) return json(e, 400, { error: "invalid_query" })

  if (!rateAllowed(e.auth.id)) return json(e, 429, { error: "rate_limited" })

  const cacheKey = `search:rebrickable:${search.toLowerCase()}`
  const hit = cached(cacheKey)
  if (hit) return json(e, hit.status, hit.body)

  const key = apiKey("rebrickable")
  if (!key) return json(e, 503, { error: "lookup_not_configured" })

  if (!rebrickableAllowed(Date.now())) return json(e, 503, { error: "lookup_unavailable" })

  try {
    const response = fetchSearch(search, key)
    if (response.statusCode < 200 || response.statusCode >= 300
      || !isPlainObject(response.json) || !Array.isArray(response.json.results)) {
      return json(e, 503, { error: "lookup_unavailable" })
    }
    const results = normalizeSearch(response.json)
    cacheResult(cacheKey, 200, results, results.length ? CACHE_TTL : NEGATIVE_CACHE_TTL)
    return json(e, 200, results)
  } catch (_) {
    return json(e, 503, { error: "lookup_unavailable" })
  }
}

// Proxies an approved Brickset image so the browser can convert it to WebP and
// upload it to the `table_thumbnails` collection. Only allow-listed image URLs
// are fetched, and only JPEG, PNG, or WebP responses are returned.
function handleThumbnailSource(e) {
  const inputUrl = e.request.url.query().get("url")
  const sourceUrl = safeImage(inputUrl, "brickset") || safeImage(inputUrl, "rebrickable")
  if (!sourceUrl) return json(e, 400, { error: "invalid_image_url" })

  if (!rateAllowed(e.auth.id)) return json(e, 429, { error: "rate_limited" })

  try {
    const response = $http.send({
      method: "GET",
      url: sourceUrl,
      headers: { Accept: "image/jpeg,image/png,image/webp" },
      timeout: HTTP_TIMEOUT,
    })
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return json(e, 503, { error: "thumbnail_unavailable" })
    }
    const headers = response.headers || {}
    const contentTypeHeader = headers["Content-Type"] || headers["content-type"]
    const contentType = Array.isArray(contentTypeHeader) ? contentTypeHeader[0] : contentTypeHeader
    const mimeType = String(contentType || "").split(";")[0].trim().toLowerCase()
    const bytes = response.body
    if (!bytes || !bytes.length || bytes.length > THUMBNAIL_MAX_BYTES
      || ["image/jpeg", "image/png", "image/webp"].indexOf(mimeType) === -1) {
      return json(e, 503, { error: "thumbnail_unavailable" })
    }
    e.response.header().set("Cache-Control", "private, max-age=300")
    return e.blob(200, mimeType, bytes)
  } catch (_) {
    return json(e, 503, { error: "thumbnail_unavailable" })
  }
}

module.exports = {
  handleLookup,
  handleSearch,
  handleThumbnailSource,
  // Exported for tests.
  parseCode,
  normalize,
  normalizeSearch,
  validResponse,
}
