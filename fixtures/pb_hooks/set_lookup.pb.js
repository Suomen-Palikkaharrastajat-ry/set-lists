/// <reference path="../pb_data/types.d.ts" />
// Authenticated, server-side catalog lookups against Rebrickable and Brickset.
//
//   GET /api/set-lists/lookup?provider=rebrickable|brickset&code=75192-1
//   GET /api/set-lists/search?q=falcon            (Rebrickable only)
//   GET /api/set-lists/thumbnail-source?url=...   (approved provider images only)
//
// Provider credentials come only from the PocketBase process environment
// (REBRICKABLE_API_KEY, BRICKSET_API_KEY) and are never logged.
//
// PocketBase runs each handler as an isolated program: nothing declared at the
// top level of this file is visible inside a handler. All logic therefore lives
// in set_lookup_lib.js and is required *inside* each handler via __hooks.
//
// The triple-slash reference is editor-only; PocketBase ignores it at runtime.

routerAdd("GET", "/api/set-lists/search", (e) => {
  return require(`${__hooks}/set_lookup_lib.js`).handleSearch(e)
}, $apis.requireAuth("users"))

routerAdd("GET", "/api/set-lists/thumbnail-source", (e) => {
  return require(`${__hooks}/set_lookup_lib.js`).handleThumbnailSource(e)
}, $apis.requireAuth("users"))

routerAdd("GET", "/api/set-lists/lookup", (e) => {
  return require(`${__hooks}/set_lookup_lib.js`).handleLookup(e)
}, $apis.requireAuth("users"))
