const WEBP_METADATA_CHUNKS = new Set(['ICCP', 'EXIF', 'XMP '])
const WEBP_METADATA_FLAGS = 0x20 | 0x08 | 0x04

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

function readTag(bytes, offset) {
  return String.fromCharCode(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
}
