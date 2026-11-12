import './main.css'
import { Elm } from './src/Main.elm'
import siteConfig from 'virtual:site-config'
import { getInitAuth, wirePocketBaseAuthPorts, triggerBackgroundAuthRefresh } from './packages/app-toolkit/js/pocketbase-auth.js'
import { appSettings, pickLang, showLanguage } from './packages/site-config/browser.mjs'
import { encodeLosslessWebp, stripWebpMetadata, thumbnailDimensions, validateCropRegion } from './photo-pipeline.mjs'
import { installCropGestures } from './crop-gestures.mjs'

const settings = appSettings(siteConfig, pickLang(siteConfig))
const pbBaseUrl = import.meta.env.VITE_POCKETBASE_URL || settings.pocketbase_url
const initAuth = getInitAuth()
const localPasswordAuth = import.meta.env.DEV && ['localhost', '127.0.0.1', '0.0.0.0', '[::1]'].includes(new URL(pbBaseUrl).hostname)

const app = Elm.Main.init({
  node: document.getElementById('app'),
  flags: {
    pbBaseUrl,
    authToken: initAuth.authToken,
    authModel: initAuth.authModel,
    localPasswordAuth,
    siteConfig,
    requestedLang: pickLang(siteConfig),
  },
})

installCropGestures(document, (gesture) => app.ports.cropGesture.send(gesture))

document.addEventListener('dragstart', (event) => {
  const target = event.target
  const handle = target instanceof Element ? target.closest('[data-set-drag-handle]') : null
  const index = handle?.getAttribute('data-set-index')
  if (index === null || index === undefined || !event.dataTransfer) return

  event.dataTransfer.setData('text/plain', index)
  event.dataTransfer.effectAllowed = 'move'
}, true)

const SET_SEARCH_DEBOUNCE_MS = 1000
const MAX_SET_IMAGE_BYTES = 1_000_000
const MAX_LIST_PHOTO_BYTES = 20_000_000
const MAX_THUMBNAIL_BYTES = 200_000
const CROP_PREVIEW_MAX_DIMENSION = 1024
const LIST_PHOTO_SLOTS = ['photo', 'photo_01', 'photo_02', 'photo_03', 'photo_04', 'photo_05']
const setSearchTimers = new Map()
let pendingListPhoto = null
app.ports.scheduleSetSearch.subscribe((payload) => {
  const previous = setSearchTimers.get(payload.index)
  if (previous) clearTimeout(previous)
  const timer = setTimeout(() => {
    setSearchTimers.delete(payload.index)
    app.ports.setSearchReady.send(payload)
  }, SET_SEARCH_DEBOUNCE_MS)
  setSearchTimers.set(payload.index, timer)
})

async function decodeThumbnailImage(blob) {
  if (typeof createImageBitmap === 'function') {
    try {
      const image = await createImageBitmap(blob)
      return { image, release: () => image.close() }
    } catch (_) {
      // Some browsers cannot decode formats such as HEIC through createImageBitmap,
      // even when their native image decoder can display them.
    }
  }

  const objectUrl = URL.createObjectURL(blob)
  const image = new Image()
  try {
    if (typeof image.decode === 'function') {
      image.src = objectUrl
      await image.decode()
    } else {
      await new Promise((resolve, reject) => {
        image.onload = resolve
        image.onerror = () => reject(new Error('Image decoding failed'))
        image.src = objectUrl
      })
    }
    return { image, release: () => URL.revokeObjectURL(objectUrl) }
  } catch (error) {
    URL.revokeObjectURL(objectUrl)
    throw error
  }
}

function drawRegionToCanvas(image, region, width, height) {
  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  const context = canvas.getContext('2d')
  if (!context) throw new Error('Canvas unavailable')
  context.drawImage(image, region.x, region.y, region.width, region.height, 0, 0, width, height)
  return canvas
}

async function encodeCanvasWebp(canvas) {
  let encoded = null
  if (typeof canvas.toBlob === 'function') {
    try {
      encoded = await new Promise((resolve) => canvas.toBlob(resolve, 'image/webp', 0.82))
    } catch (_) {
      // Use the bounded lossless encoder when the browser cannot encode a canvas to WebP.
    }
  }
  const webp = encoded?.type === 'image/webp'
    ? encoded
    : encodeLosslessWebp(canvas.width, canvas.height, canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data)

  const sanitized = await stripWebpMetadata(webp)
  if (sanitized.size === 0 || sanitized.size > MAX_THUMBNAIL_BYTES) throw new Error('WebP thumbnail is too large')
  return sanitized
}

function decodedImageSize(image) {
  return { width: image.width || image.naturalWidth, height: image.height || image.naturalHeight }
}

async function encodeWebpThumbnail(sourceBlob, maxSourceBytes) {
  if (sourceBlob.size === 0 || sourceBlob.size > maxSourceBytes) throw new Error('Invalid source image size')

  const decoded = await decodeThumbnailImage(sourceBlob)
  try {
    const source = decodedImageSize(decoded.image)
    const dimensions = thumbnailDimensions(source.width, source.height)
    const canvas = drawRegionToCanvas(decoded.image, { x: 0, y: 0, ...source }, dimensions.width, dimensions.height)
    return await encodeCanvasWebp(canvas)
  } finally {
    decoded.release()
  }
}

async function findStoredThumbnail(collection, code) {
  try {
    return await collection.getFirstListItem(`code="${code}"`)
  } catch (error) {
    if (error?.status === 404) return null
    throw error
  }
}

app.ports.processSetThumbnail.subscribe(async (payload) => {
  let imageUrl = null
  try {
    if (!/^\d{1,6}-\d{1,3}$/.test(payload.code)) throw new Error('Invalid set code')

    const PocketBase = (await import('pocketbase')).default
    const pb = new PocketBase(payload.pbBaseUrl)
    pb.authStore.save(payload.token, null)
    const collection = pb.collection('table_thumbnails')
    let record = await findStoredThumbnail(collection, payload.code)

      if (record?.thumbnail) {
        imageUrl = pb.files.getURL(record, record.thumbnail)
      } else {
      const sourceEndpoint = new URL('/api/set-lists/thumbnail-source', payload.pbBaseUrl)
      sourceEndpoint.searchParams.set('url', payload.imageUrl)
      const sourceResponse = await fetch(sourceEndpoint, {
        headers: { Authorization: payload.token },
        })
        if (!sourceResponse.ok) throw new Error('Thumbnail source unavailable')
        const sourceBlob = await sourceResponse.blob()
        const webp = await encodeWebpThumbnail(sourceBlob, MAX_SET_IMAGE_BYTES)
        const file = new File([webp], `set-${payload.code}.webp`, { type: 'image/webp' })
        try {
          record = await collection.create({ code: payload.code, thumbnail: file })
        } catch (error) {
          // If another editor stored the same set concurrently, reuse that file.
          record = await findStoredThumbnail(collection, payload.code)
          if (!record) throw error
        }
        if (record?.thumbnail) imageUrl = pb.files.getURL(record, record.thumbnail)
    }
  } catch (_) {
    // Keep the set metadata even if thumbnail conversion or storage is unavailable.
  }

  app.ports.setThumbnailProcessed.send({
    index: payload.index,
    requestId: payload.requestId,
    code: payload.code,
    imageUrl,
  })
})

async function authenticatedPocketBase(pbBaseUrl, token) {
  const PocketBase = (await import('pocketbase')).default
  const pb = new PocketBase(pbBaseUrl)
  pb.authStore.save(token, null)
  return pb
}

app.ports.prepareListPhoto.subscribe(async (payload) => {
  const input = document.getElementById(payload.inputId)
  let previewUrl = ''
  let width = 0
  let height = 0
  let errorCode = ''
  let failureStage = 'validation'
  pendingListPhoto = null

  try {
    if (!/^[a-z0-9]{10,20}$/i.test(payload.listId)) throw new Error('Invalid list id')
    if (!LIST_PHOTO_SLOTS.includes(payload.slot)) throw new Error('Invalid photo slot')
    const sourceFile = input?.files?.[0]
    if (!sourceFile || (sourceFile.type && !sourceFile.type.startsWith('image/'))) {
      errorCode = 'unsupported-image'
      throw new Error('Invalid photo type')
    }
    if (sourceFile.size > MAX_LIST_PHOTO_BYTES) {
      errorCode = 'photo-too-large'
      throw new Error('Photo too large')
    }

    failureStage = 'image processing'
    const decoded = await decodeThumbnailImage(sourceFile)
    try {
      const source = decodedImageSize(decoded.image)
      const preview = thumbnailDimensions(source.width, source.height, CROP_PREVIEW_MAX_DIMENSION)
      const canvas = drawRegionToCanvas(decoded.image, { x: 0, y: 0, ...source }, preview.width, preview.height)
      previewUrl = canvas.toDataURL('image/webp', 0.9)
      width = preview.width
      height = preview.height
      pendingListPhoto = { listId: payload.listId, slot: payload.slot, canvas }
    } finally {
      decoded.release()
    }
  } catch (error) {
    console.error(`List photo ${failureStage} failed`, error)
    if (!errorCode) errorCode = 'processing-failed'
  } finally {
    if (input) input.value = ''
  }

  app.ports.listPhotoPrepared.send({ listId: payload.listId, slot: payload.slot, previewUrl, width, height, error: errorCode })
})

app.ports.cancelListPhotoPreparation.subscribe((payload) => {
  if (pendingListPhoto?.listId === payload.listId) pendingListPhoto = null
})

app.ports.applyListPhoto.subscribe(async (payload) => {
  const pending = pendingListPhoto
  pendingListPhoto = null
  let photo = ''
  let fileToken = ''
  let errorCode = ''
  let failureStage = 'image processing'

  try {
    if (!/^[a-z0-9]{10,20}$/i.test(payload.listId)) throw new Error('Invalid list id')
    if (!LIST_PHOTO_SLOTS.includes(payload.slot)) throw new Error('Invalid photo slot')
    if (!pending || pending.listId !== payload.listId || pending.slot !== payload.slot) throw new Error('Prepared photo is missing')

    const region = validateCropRegion(pending.canvas.width, pending.canvas.height, payload.crop)
    const output = thumbnailDimensions(region.width, region.height)
    const webp = await encodeCanvasWebp(drawRegionToCanvas(pending.canvas, region, output.width, output.height))
    const file = new File([webp], `list-${payload.slot.replace('_', '-')}.webp`, { type: 'image/webp' })
    const formData = new FormData()
    formData.append(payload.slot, file)

    failureStage = 'PocketBase upload'
    const pb = await authenticatedPocketBase(payload.pbBaseUrl, payload.token)
    const record = await pb.collection('table_catalogs').update(payload.listId, formData)
    photo = typeof record[payload.slot] === 'string' ? record[payload.slot] : ''
    if (photo) {
      try {
        fileToken = await pb.files.getToken()
      } catch (_) {
        // Published lists can still serve their protected photo under the public view rule.
      }
    }
  } catch (error) {
    console.error(`List photo ${failureStage} failed`, error)
    if (!errorCode) errorCode = 'processing-failed'
  }

  app.ports.listPhotoProcessed.send({ listId: payload.listId, slot: payload.slot, photo, fileToken, error: errorCode })
})

app.ports.clearListPhoto.subscribe(async (payload) => {
  let error = ''
  try {
    if (!/^[a-z0-9]{10,20}$/i.test(payload.listId)) throw new Error('Invalid list id')
    if (!LIST_PHOTO_SLOTS.includes(payload.slot)) throw new Error('Invalid photo slot')

    const pb = await authenticatedPocketBase(payload.pbBaseUrl, payload.token)
    await pb.collection('table_catalogs').update(payload.listId, { [payload.slot]: '' })
  } catch (cause) {
    console.error('List photo removal failed', cause)
    error = 'removal-failed'
  }

  app.ports.listPhotoCleared.send({ listId: payload.listId, slot: payload.slot, error })
})

app.ports.requestListPhotoFileToken.subscribe(async (payload) => {
  let token = ''
  try {
    const pb = await authenticatedPocketBase(payload.pbBaseUrl, payload.token)
    token = await pb.files.getToken()
  } catch (_) {
    // Public published photos are also authorized by the collection's view rule.
  }
  app.ports.listPhotoFileTokenReceived.send({ listId: payload.listId, token })
})

app.ports.setDocumentLang.subscribe((lang) => showLanguage(siteConfig, lang))
app.ports.printDocument.subscribe(() => window.print())
app.ports.applyMarkdownFormatting.subscribe(({ id, prefix, suffix, linePrefix }) => {
  const textarea = document.getElementById(id)
  if (!textarea) return
  const start = textarea.selectionStart
  const end = textarea.selectionEnd
  const selected = textarea.value.slice(start, end)
  const isLineFormat = Boolean(linePrefix)
  const replacement = isLineFormat
    ? selected.split('\n').map((line) => linePrefix + line).join('\n')
    : prefix + selected + suffix
  textarea.setRangeText(replacement, start, end, 'preserve')
  if (isLineFormat) {
    textarea.setSelectionRange(start, start + replacement.length)
  } else {
    textarea.setSelectionRange(start + prefix.length, start + prefix.length + selected.length)
  }
  textarea.dispatchEvent(new Event('input', { bubbles: true }))
  textarea.focus()
})
wirePocketBaseAuthPorts(app, { loadPocketBase: () => import('pocketbase').then((module) => module.default) })
app.ports.localPasswordLogin.subscribe(async ({ email, password }) => {
  try {
    const PocketBase = (await import('pocketbase')).default
    const pb = new PocketBase(pbBaseUrl)
    const authData = await pb.collection('users').authWithPassword(email, password)
    const record = authData.record
    app.ports.localPasswordLoginResult.send({
      token: authData.token,
      model: JSON.stringify({ id: record.id, name: record.name || '', email: record.email || '' }),
      error: '',
    })
  } catch (error) {
    app.ports.localPasswordLoginResult.send({
      token: '',
      model: '{}',
      error: error?.response?.message || error?.message || 'Login failed',
    })
  }
})
triggerBackgroundAuthRefresh(pbBaseUrl, initAuth, {
  loadPocketBase: () => import('pocketbase').then((module) => module.default),
})

// Keep keyboard focus inside the mobile navigation's modal drawer.
document.addEventListener('keydown', (event) => {
  if (event.key !== 'Tab') return

  const drawer = document.getElementById('mobile-nav')
  if (!drawer || drawer.hasAttribute('inert') || drawer.getClientRects().length === 0) return

  const focusable = Array.from(
    drawer.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'),
  ).filter((element) => element.getClientRects().length > 0 && !element.closest('[inert]'))

  if (focusable.length === 0) {
    event.preventDefault()
    drawer.focus()
    return
  }

  const first = focusable[0]
  const last = focusable[focusable.length - 1]
  const focusIsOutsideDrawer = !drawer.contains(document.activeElement)

  if (event.shiftKey && (document.activeElement === first || focusIsOutsideDrawer)) {
    event.preventDefault()
    last.focus()
  } else if (!event.shiftKey && (document.activeElement === last || focusIsOutsideDrawer)) {
    event.preventDefault()
    first.focus()
  }
}, true)
