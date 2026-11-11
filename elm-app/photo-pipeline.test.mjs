import assert from 'node:assert/strict'
import test from 'node:test'
import { stripWebpMetadata, thumbnailDimensions } from './photo-pipeline.mjs'

function webpChunk(type, payload) {
  const size = payload.length
  const chunk = new Uint8Array(8 + size + (size % 2))
  chunk.set(new TextEncoder().encode(type), 0)
  new DataView(chunk.buffer).setUint32(4, size, true)
  chunk.set(payload, 8)
  return chunk
}

function webpFile(chunks) {
  const size = 12 + chunks.reduce((sum, chunk) => sum + chunk.length, 0)
  const bytes = new Uint8Array(size)
  bytes.set(new TextEncoder().encode('RIFF'), 0)
  new DataView(bytes.buffer).setUint32(4, size - 8, true)
  bytes.set(new TextEncoder().encode('WEBP'), 8)
  let offset = 12
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.length
  }
  return new Blob([bytes], { type: 'image/webp' })
}

function webpChunks(bytes) {
  const tags = []
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  let offset = 12
  while (offset < bytes.length) {
    const type = new TextDecoder().decode(bytes.slice(offset, offset + 4))
    const size = view.getUint32(offset + 4, true)
    tags.push(type)
    offset += 8 + size + (size % 2)
  }
  return tags
}

test('thumbnail dimensions preserve aspect ratio, cap the longest edge, and never upscale', () => {
  assert.deepEqual(thumbnailDimensions(4000, 2000), { width: 256, height: 128 })
  assert.deepEqual(thumbnailDimensions(2000, 4000), { width: 128, height: 256 })
  assert.deepEqual(thumbnailDimensions(120, 80), { width: 120, height: 80 })
})

test('WebP sanitizing removes EXIF and other metadata chunks and clears feature flags', async () => {
  const flags = new Uint8Array(10)
  flags[0] = 0x3e // ICCP, alpha, EXIF, XMP, and animation flags
  const source = webpFile([
    webpChunk('VP8X', flags),
    webpChunk('ICCP', new Uint8Array([ 1, 2, 3 ])),
    webpChunk('EXIF', new TextEncoder().encode('GPS coordinates')),
    webpChunk('XMP ', new TextEncoder().encode('location metadata')),
    webpChunk('VP8 ', new Uint8Array([ 4, 5, 6, 7 ])),
  ])

  const sanitized = await stripWebpMetadata(source)
  const bytes = new Uint8Array(await sanitized.arrayBuffer())

  assert.equal(sanitized.type, 'image/webp')
  assert.deepEqual(webpChunks(bytes), [ 'VP8X', 'VP8 ' ])
  assert.equal(bytes[20] & 0x2c, 0)
  assert.equal(bytes[20] & 0x12, 0x12)
  assert.equal(new DataView(bytes.buffer).getUint32(4, true), bytes.length - 8)
})

test('WebP sanitizing rejects malformed input', async () => {
  await assert.rejects(stripWebpMetadata(new Blob([ 'not an image' ])), /Invalid WebP image/)
})
