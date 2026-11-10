/// <reference path="../pb_data/types.d.ts" />
// Authenticated, server-side lookup for catalog metadata. Provider credentials
// are read only from the PocketBase process environment and are never logged.

// The triple-slash reference is editor-only. Relative to this fixture it points
// at fixtures/pb_data/types.d.ts; when copied into a PocketBase instance's
// pb_hooks directory, it resolves to that instance's generated pb_data/types.d.ts.
// PocketBase ignores this comment at runtime.
const setLookupStore = $app.store()
const SET_LOOKUP_STORE_PREFIX = "set-lookup:v1:"
const SET_LOOKUP_CACHE_KEY = SET_LOOKUP_STORE_PREFIX + "cache"
const SET_LOOKUP_BRICKSET_QUOTA_KEY = SET_LOOKUP_STORE_PREFIX + "quota:brickset"
const SET_LOOKUP_REBRICKABLE_LIMIT_KEY = SET_LOOKUP_STORE_PREFIX + "limit:rebrickable"
const SET_LOOKUP_CACHE_TTL = 30 * 60 * 1000
const SET_LOOKUP_NEGATIVE_CACHE_TTL = 5 * 60 * 1000
const SET_LOOKUP_CACHE_MAX = 200
const SET_LOOKUP_RATE_WINDOW = 60 * 1000
const SET_LOOKUP_RATE_MAX = 20
const SET_LOOKUP_BRICKSET_DAILY_MAX = 80
const SET_LOOKUP_REBRICKABLE_INTERVAL = 1000
const SET_LOOKUP_CODE = /^[0-9]{1,6}-[0-9]{1,3}$/

function setLookupJson(e, status, body) {
  return e.json(status, body)
}

function setLookupTrimmedString(value, maxLength) {
  if (typeof value !== "string") return ""
  return value.trim().slice(0, maxLength)
}

function setLookupInteger(value, min, max) {
  if (value === null || value === undefined || value === "") return null
  const number = typeof value === "number" ? value : Number(value)
  if (!Number.isInteger(number) || number < min || number > max) return null
  return number
}

function setLookupImage(value, provider) {
  const imageUrl = setLookupTrimmedString(value, 1000)
  if (!imageUrl || /[\u0000-\u0020\u007f]/.test(imageUrl)) return null

  const allowedHosts = provider === "rebrickable"
    ? ["https://cdn.rebrickable.com/"]
    : ["https://images.brickset.com/", "https://brickset.com/", "https://www.brickset.com/"]

  return allowedHosts.some((prefix) => imageUrl.startsWith(prefix)) ? imageUrl : null
}

function setLookupNormalize(provider, code, data) {
  let name = ""
  let year = null
  let pieces = null
  let imageUrl = null

  if (provider === "rebrickable") {
    if (!data || typeof data !== "object" || data.set_num !== code) return null
    name = setLookupTrimmedString(data.name, 200)
    year = setLookupInteger(data.year, 1950, new Date().getUTCFullYear() + 1)
    pieces = setLookupInteger(data.num_parts, 0, 100000)
    imageUrl = setLookupImage(data.set_img_url, provider)
  } else {
    const sets = data && Array.isArray(data.sets) ? data.sets : []
    const set = sets.find((item) => {
      if (!item || typeof item !== "object") return false
      const variant = setLookupInteger(item.numberVariant, 1, 999) || 1
      return `${item.number}-${variant}` === code
    })
    if (!set) return null
    name = setLookupTrimmedString(set.name, 200)
    year = setLookupInteger(set.year, 1950, new Date().getUTCFullYear() + 1)
    pieces = setLookupInteger(set.pieces, 0, 100000)
    imageUrl = setLookupImage(set.imageURL, provider)
      || setLookupImage(set.thumbnailURL, provider)
  }

  if (!name) return null
  return {
    name,
    year,
    pieces,
    imageUrl,
    sourceUrl: provider === "rebrickable"
      ? `https://rebrickable.com/sets/${code}/`
      : `https://brickset.com/sets/${code}`,
  }
}

function setLookupValidResponse(provider, code, data) {
  if (!data || typeof data !== "object" || Array.isArray(data)) return false

  if (provider === "rebrickable") {
    return data.set_num === code
      && typeof data.name === "string"
      && setLookupTrimmedString(data.name, 200) !== ""
  }

  return data.status === "success"
    && Array.isArray(data.sets)
    && data.sets.every((set) => {
      if (!set || typeof set !== "object" || Array.isArray(set)) return false
      const validNumber = typeof set.number === "string"
        ? set.number.trim() !== ""
        : typeof set.number === "number" && Number.isFinite(set.number)
      return validNumber
        && typeof set.name === "string"
        && setLookupTrimmedString(set.name, 200) !== ""
    })
}

function setLookupParseJson(value, fallback) {
  if (typeof value !== "string" || !value) return fallback
  try {
    return JSON.parse(value)
  } catch (_) {
    return fallback
  }
}

function setLookupCacheObject(value) {
  const parsed = setLookupParseJson(value, {})
  return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {}
}

function setLookupCached(key) {
  const now = Date.now()
  let cached = null
  setLookupStore.setFunc(SET_LOOKUP_CACHE_KEY, (value) => {
    const cache = setLookupCacheObject(value)
    Object.keys(cache).forEach((cacheKey) => {
      if (!cache[cacheKey] || cache[cacheKey].expiresAt <= now) delete cache[cacheKey]
    })

    const entry = cache[key]
    if (entry) {
      // Refresh insertion order for a bounded LRU cache.
      delete cache[key]
      cache[key] = entry
      cached = entry
    }
    return JSON.stringify(cache)
  })
  return cached
}

function setLookupCacheResult(key, status, body, ttl) {
  const now = Date.now()
  setLookupStore.setFunc(SET_LOOKUP_CACHE_KEY, (value) => {
    const cache = setLookupCacheObject(value)
    Object.keys(cache).forEach((cacheKey) => {
      if (!cache[cacheKey] || cache[cacheKey].expiresAt <= now) delete cache[cacheKey]
    })

    delete cache[key]
    cache[key] = { status, body, expiresAt: now + ttl }
    const keys = Object.keys(cache)
    while (keys.length > SET_LOOKUP_CACHE_MAX) {
      delete cache[keys.shift()]
    }
    return JSON.stringify(cache)
  })
}

function setLookupRateAllowed(userId) {
  const now = Date.now()
  const cutoff = now - SET_LOOKUP_RATE_WINDOW
  const rateKey = SET_LOOKUP_STORE_PREFIX + "rate:user:" + userId
  let allowed = false
  setLookupStore.setFunc(rateKey, (value) => {
    const prior = setLookupParseJson(value, [])
    const recent = Array.isArray(prior)
      ? prior.filter((timestamp) => typeof timestamp === "number" && timestamp > cutoff)
      : []
    allowed = recent.length < SET_LOOKUP_RATE_MAX
    if (allowed) recent.push(now)
    return JSON.stringify(recent)
  })
  return allowed
}

function setLookupRebrickableAllowed(now) {
  let allowed = false
  setLookupStore.setFunc(SET_LOOKUP_REBRICKABLE_LIMIT_KEY, (value) => {
    const previous = Number(value)
    if (!Number.isFinite(previous) || now - previous >= SET_LOOKUP_REBRICKABLE_INTERVAL) {
      allowed = true
      return String(now)
    }
    return String(previous)
  })
  return allowed
}

function setLookupBricksetAllowed(now) {
  const day = new Date(now).toISOString().slice(0, 10)
  let allowed = false
  setLookupStore.setFunc(SET_LOOKUP_BRICKSET_QUOTA_KEY, (value) => {
    const quota = setLookupParseJson(value, {})
    const current = quota && quota.day === day && Number.isInteger(quota.count)
      ? quota.count
      : 0
    allowed = current < SET_LOOKUP_BRICKSET_DAILY_MAX
    return JSON.stringify({ day, count: allowed ? current + 1 : current })
  })
  return allowed
}

function setLookupFetch(provider, code, apiKey) {
  if (provider === "rebrickable") {
    return $http.send({
      method: "GET",
      url: `https://rebrickable.com/api/v3/lego/sets/${code}/`,
      headers: { Authorization: `key ${apiKey}`, Accept: "application/json" },
      timeout: 5,
    })
  }

  // Brickset API v3 accepts POSTed form parameters, with params as a JSON
  // string. Keep its API key in the body (never the URL/access logs).
  return $http.send({
    method: "POST",
    url: "https://brickset.com/api/v3.asmx/getSets",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
    body: "apiKey=" + encodeURIComponent(apiKey)
      + "&params=" + encodeURIComponent(JSON.stringify({ setNumber: code, extendedData: 0 })),
    timeout: 5,
  })
}

routerAdd("GET", "/api/set-lists/lookup", (e) => {
  const query = e.request.url.query()
  const provider = query.get("provider")
  const code = query.get("code").trim()

  if (provider !== "rebrickable" && provider !== "brickset") {
    return setLookupJson(e, 400, { error: "invalid_provider" })
  }
  if (!SET_LOOKUP_CODE.test(code)) {
    return setLookupJson(e, 400, { error: "invalid_code" })
  }

  if (!setLookupRateAllowed(e.auth.id)) {
    return setLookupJson(e, 429, { error: "rate_limited" })
  }

  const cacheKey = `${provider}:${code}`
  const cached = setLookupCached(cacheKey)
  if (cached) return setLookupJson(e, cached.status, cached.body)

  const envName = provider === "rebrickable" ? "REBRICKABLE_API_KEY" : "BRICKSET_API_KEY"
  const apiKey = $os.getenv(envName)
  if (!apiKey) {
    return setLookupJson(e, 503, { error: "lookup_not_configured" })
  }

  const now = Date.now()
  const providerAllowed = provider === "rebrickable"
    ? setLookupRebrickableAllowed(now)
    : setLookupBricksetAllowed(now)
  if (!providerAllowed) {
    return setLookupJson(e, 503, { error: "lookup_unavailable" })
  }

  try {
    const response = setLookupFetch(provider, code, apiKey)
    if (response.statusCode === 404) {
      const body = { error: "not_found" }
      setLookupCacheResult(cacheKey, 404, body, SET_LOOKUP_NEGATIVE_CACHE_TTL)
      return setLookupJson(e, 404, body)
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return setLookupJson(e, 503, { error: "lookup_unavailable" })
    }
    if (!setLookupValidResponse(provider, code, response.json)) {
      return setLookupJson(e, 503, { error: "lookup_unavailable" })
    }

    const result = setLookupNormalize(provider, code, response.json)
    if (!result) {
      const body = { error: "not_found" }
      setLookupCacheResult(cacheKey, 404, body, SET_LOOKUP_NEGATIVE_CACHE_TTL)
      return setLookupJson(e, 404, body)
    }

    setLookupCacheResult(cacheKey, 200, result, SET_LOOKUP_CACHE_TTL)
    return setLookupJson(e, 200, result)
  } catch (_) {
    // Provider response and request errors may contain credentials or request
    // details. Return a fixed message and do not log them.
    return setLookupJson(e, 503, { error: "lookup_unavailable" })
  }
}, $apis.requireAuth("users"))
