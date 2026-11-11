import assert from 'node:assert/strict'
import test from 'node:test'
import { encodeLosslessWebp, stripWebpMetadata, thumbnailDimensions, validateCropRegion } from './photo-pipeline.mjs'

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

test('cropped regions are sized to the 256px thumbnail limit without upscaling', () => {
  const region = validateCropRegion(4000, 3000, { x: 500, y: 0, width: 3000, height: 3000 })
  assert.deepEqual(thumbnailDimensions(region.width, region.height), { width: 256, height: 256 })
  const wide = validateCropRegion(4000, 3000, { x: 0, y: 375, width: 4000, height: 2250 })
  assert.deepEqual(thumbnailDimensions(wide.width, wide.height), { width: 256, height: 144 })
  assert.deepEqual(thumbnailDimensions(90, 120), { width: 90, height: 120 })
})

test('crop regions must be whole pixels inside the source image', () => {
  assert.deepEqual(validateCropRegion(10, 8, { x: 0, y: 0, width: 10, height: 8 }), { x: 0, y: 0, width: 10, height: 8 })
  assert.throws(() => validateCropRegion(10, 8, { x: 0, y: 0, width: 11, height: 8 }), /Invalid crop region/)
  assert.throws(() => validateCropRegion(10, 8, { x: 9, y: 0, width: 2, height: 8 }), /Invalid crop region/)
  assert.throws(() => validateCropRegion(10, 8, { x: -1, y: 0, width: 2, height: 2 }), /Invalid crop region/)
  assert.throws(() => validateCropRegion(10, 8, { x: 0, y: 0, width: 0, height: 2 }), /Invalid crop region/)
  assert.throws(() => validateCropRegion(10, 8, { x: 0.5, y: 0, width: 2, height: 2 }), /Invalid crop region/)
  assert.throws(() => validateCropRegion(10, 8, { x: 0, y: 0, width: Number.NaN, height: 2 }), /Invalid crop region/)
  assert.throws(() => validateCropRegion(10, 8, undefined), /Invalid crop region/)
  assert.throws(() => validateCropRegion(0, 8, { x: 0, y: 0, width: 1, height: 1 }), /Invalid image dimensions/)
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

function readBits(bytes, bitOffset, count) {
  let value = 0
  for (let bit = 0; bit < count; bit++) {
    const position = bitOffset + bit
    value |= ((bytes[position >> 3] >> (position & 7)) & 1) << bit
  }
  return value
}

test('lossless WebP fallback writes a VP8L image with the requested dimensions', async () => {
  const width = 3
  const height = 2
  const rgba = new Uint8ClampedArray(width * height * 4).fill(255)
  const bytes = new Uint8Array(await encodeLosslessWebp(width, height, rgba).arrayBuffer())
  const view = new DataView(bytes.buffer)

  assert.equal(new TextDecoder().decode(bytes.slice(0, 4)), 'RIFF')
  assert.equal(new TextDecoder().decode(bytes.slice(8, 16)), 'WEBPVP8L')
  assert.equal(view.getUint32(4, true), bytes.length - 8)
  assert.equal(view.getUint32(16, true), bytes.length - 20)
  assert.equal(bytes[20], 0x2f)
  assert.equal(readBits(bytes, 168, 14) + 1, width)
  assert.equal(readBits(bytes, 182, 14) + 1, height)
  const sanitized = await stripWebpMetadata(encodeLosslessWebp(width, height, rgba))
  assert.deepEqual(webpChunks(new Uint8Array(await sanitized.arrayBuffer())), [ 'VP8L' ])
})

test('lossless WebP fallback stays under the thumbnail limit for the largest thumbnail', () => {
  const rgba = new Uint8ClampedArray(256 * 256 * 4)
  for (let i = 0; i < rgba.length; i++) rgba[i] = (i * 2654435761) >>> 24
  assert.ok(encodeLosslessWebp(256, 256, rgba).size <= 200_000)
})

test('lossless WebP fallback rejects invalid dimensions and pixel data', () => {
  assert.throws(() => encodeLosslessWebp(0, 1, new Uint8ClampedArray(4)), /Invalid image dimensions/)
  assert.throws(() => encodeLosslessWebp(1.5, 1, new Uint8ClampedArray(4)), /Invalid image dimensions/)
  assert.throws(() => encodeLosslessWebp(2, 1, new Uint8ClampedArray(4)), /Invalid pixel data/)
})
