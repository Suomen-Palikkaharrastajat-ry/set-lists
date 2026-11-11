const WEBP_METADATA_CHUNKS = new Set(['ICCP', 'EXIF', 'XMP '])
const WEBP_METADATA_FLAGS = 0x20 | 0x08 | 0x04
const VP8L_CODE_LENGTH_ORDER = [ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8 ]

export function thumbnailDimensions(width, height, maxDimension = 256) {
  if (![width, height, maxDimension].every(Number.isFinite) || width <= 0 || height <= 0 || maxDimension <= 0) {
    throw new Error('Invalid image dimensions')
  }

  const scale = Math.min(1, maxDimension / width, maxDimension / height)
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  }
}

export function validateCropRegion(sourceWidth, sourceHeight, region) {
  const values = [ region?.x, region?.y, region?.width, region?.height ]
  if (![sourceWidth, sourceHeight].every(Number.isInteger) || sourceWidth < 1 || sourceHeight < 1) {
    throw new Error('Invalid image dimensions')
  }
  if (!values.every(Number.isInteger)) throw new Error('Invalid crop region')

  const { x, y, width, height } = region
  if (x < 0 || y < 0 || width < 1 || height < 1 || x + width > sourceWidth || y + height > sourceHeight) {
    throw new Error('Invalid crop region')
  }
  return { x, y, width, height }
}

export async function stripWebpMetadata(blob) {
  const input = new Uint8Array(await blob.arrayBuffer())
  const inputView = new DataView(input.buffer, input.byteOffset, input.byteLength)

  if (input.length < 12 || readTag(input, 0) !== 'RIFF' || readTag(input, 8) !== 'WEBP') {
    throw new Error('Invalid WebP image')
  }

  if (inputView.getUint32(4, true) !== input.length - 8) {
    throw new Error('Invalid WebP container size')
  }

  const chunks = []
  let offset = 12

  while (offset < input.length) {
    if (offset + 8 > input.length) throw new Error('Invalid WebP chunk header')

    const type = readTag(input, offset)
    const size = inputView.getUint32(offset + 4, true)
    const payloadStart = offset + 8
    const chunkEnd = payloadStart + size + (size % 2)
    if (chunkEnd > input.length) throw new Error('Invalid WebP chunk size')

    if (!WEBP_METADATA_CHUNKS.has(type)) {
      const chunk = input.slice(offset, chunkEnd)
      if (type === 'VP8X') {
        if (size < 10) throw new Error('Invalid WebP extended header')
        chunk[8] &= ~WEBP_METADATA_FLAGS
      }
      chunks.push(chunk)
    }

    offset = chunkEnd
  }

  const outputSize = 12 + chunks.reduce((sum, chunk) => sum + chunk.length, 0)
  const output = new Uint8Array(outputSize)
  output.set([ 82, 73, 70, 70 ], 0) // RIFF
  new DataView(output.buffer).setUint32(4, outputSize - 8, true)
  output.set([ 87, 69, 66, 80 ], 8) // WEBP

  let outputOffset = 12
  for (const chunk of chunks) {
    output.set(chunk, outputOffset)
    outputOffset += chunk.length
  }

  return new Blob([output], { type: 'image/webp' })
}

// Encodes opaque-or-transparent RGBA pixels as a lossless WebP without transforms. Used when the
// browser cannot encode WebP (for example Safari), which would otherwise return a PNG from canvas.
// Each pixel stores 3 bytes, so 256px images stay below the 200 KB thumbnail limit. Alpha is
// composited over white because the stream stores opaque pixels.
export function encodeLosslessWebp(width, height, rgba) {
  if (![width, height].every(Number.isInteger) || width < 1 || height < 1 || width > 16384 || height > 16384) {
    throw new Error('Invalid image dimensions')
  }
  if (rgba.length !== width * height * 4) throw new Error('Invalid pixel data')

  const writer = new LsbBitWriter(width * height * 3 + 256)
  writer.write(0x2f, 8) // VP8L signature
  writer.write(width - 1, 14)
  writer.write(height - 1, 14)
  writer.write(0, 1) // alpha hint; the alpha code below is always 255
  writer.write(0, 3) // version
  writer.write(0, 1) // no transforms
  writer.write(0, 1) // no color cache
  writer.write(0, 1) // no meta prefix codes

  writeLiteralCode(writer, 256, 24) // green, with 24 unused length/distance symbols
  writeLiteralCode(writer, 256, 0) // red
  writeLiteralCode(writer, 256, 0) // blue
  writer.write(1, 1) // simple code
  writer.write(0, 1) // one symbol
  writer.write(1, 1) // 8-bit symbol
  writer.write(255, 8) // alpha, read without consuming bits
  writer.write(1, 1) // simple code
  writer.write(0, 1) // one symbol
  writer.write(0, 1) // 1-bit symbol
  writer.write(0, 1) // distance symbol 0, read without consuming bits

  for (let i = 0; i < rgba.length; i += 4) {
    const alpha = rgba[i + 3]
    writer.write(reverseBits8(compositeOnWhite(rgba[i + 1], alpha)), 8)
    writer.write(reverseBits8(compositeOnWhite(rgba[i], alpha)), 8)
    writer.write(reverseBits8(compositeOnWhite(rgba[i + 2], alpha)), 8)
  }

  const payload = writer.bytes.subarray(0, (writer.bitPosition + 7) >> 3)
  const output = new Uint8Array(20 + payload.length + (payload.length % 2))
  const view = new DataView(output.buffer)
  output.set(encodeTag('RIFF'), 0)
  view.setUint32(4, output.length - 8, true)
  output.set(encodeTag('WEBP'), 8)
  output.set(encodeTag('VP8L'), 12)
  view.setUint32(16, payload.length, true)
  output.set(payload, 20)
  return new Blob([output], { type: 'image/webp' })
}

function writeLiteralCode(writer, literalCount, unusedCount) {
  writer.write(0, 1) // normal prefix code
  writer.write(8, 4) // 12 code-length code lengths
  for (const symbol of VP8L_CODE_LENGTH_ORDER) {
    writer.write(symbol === 0 || symbol === 8 ? 1 : 0, 3)
  }
  writer.write(0, 1) // read every code length
  for (let i = 0; i < literalCount; i++) writer.write(1, 1) // symbol 8: 8-bit literal
  for (let i = 0; i < unusedCount; i++) writer.write(0, 1) // symbol 0: unused
}

function compositeOnWhite(channel, alpha) {
  return Math.floor((channel * alpha + 255 * (255 - alpha) + 127) / 255)
}

function reverseBits8(value) {
  let reversed = 0
  for (let bit = 0; bit < 8; bit++) reversed = (reversed << 1) | ((value >> bit) & 1)
  return reversed
}

function encodeTag(tag) {
  return new TextEncoder().encode(tag)
}

class LsbBitWriter {
  constructor(capacity) {
    this.bytes = new Uint8Array(capacity)
    this.bitPosition = 0
  }

  write(value, count) {
    for (let bit = 0; bit < count; bit++) {
      if ((value >> bit) & 1) this.bytes[this.bitPosition >> 3] |= 1 << (this.bitPosition & 7)
      this.bitPosition++
    }
  }
}

function readTag(bytes, offset) {
  return String.fromCharCode(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
}
