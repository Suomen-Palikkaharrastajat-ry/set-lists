import './main.css'
import { Elm } from './src/Main.elm'
import siteConfig from 'virtual:site-config'
import { getInitAuth, wirePocketBaseAuthPorts, triggerBackgroundAuthRefresh } from './packages/app-toolkit/js/pocketbase-auth.js'
import { appSettings, pickLang, showLanguage } from './packages/site-config/browser.mjs'
import { stripWebpMetadata, thumbnailDimensions } from './photo-pipeline.mjs'

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
const setSearchTimers = new Map()
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

async function encodeWebpThumbnail(sourceBlob, maxSourceBytes) {
  if (sourceBlob.size === 0 || sourceBlob.size > maxSourceBytes) throw new Error('Invalid source image size')

  const decoded = await decodeThumbnailImage(sourceBlob)
  try {
    const image = decoded.image
    const sourceWidth = image.width || image.naturalWidth
    const sourceHeight = image.height || image.naturalHeight
    const dimensions = thumbnailDimensions(sourceWidth, sourceHeight)
    const canvas = document.createElement('canvas')
    canvas.width = dimensions.width
    canvas.height = dimensions.height
    const context = canvas.getContext('2d')
    if (!context) throw new Error('Canvas unavailable')
    context.drawImage(image, 0, 0, canvas.width, canvas.height)
    const encoded = await new Promise((resolve) => canvas.toBlob(resolve, 'image/webp', 0.82))
    if (!encoded || encoded.type !== 'image/webp') throw new Error('WebP conversion failed')

    const sanitized = await stripWebpMetadata(encoded)
    if (sanitized.size === 0 || sanitized.size > MAX_THUMBNAIL_BYTES) throw new Error('WebP thumbnail is too large')
    return sanitized
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

app.ports.processListPhoto.subscribe(async (payload) => {
  const input = document.getElementById(payload.inputId)
  let photo = ''
  let fileToken = ''
  let errorCode = ''
  let failureStage = 'validation'

  try {
    if (!/^[a-z0-9]{10,20}$/i.test(payload.listId)) throw new Error('Invalid list id')
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
    const webp = await encodeWebpThumbnail(sourceFile, MAX_LIST_PHOTO_BYTES)
    const file = new File([webp], 'list-cover.webp', { type: 'image/webp' })
    const formData = new FormData()
    formData.append('photo', file)

    failureStage = 'PocketBase upload'
    const PocketBase = (await import('pocketbase')).default
    const pb = new PocketBase(payload.pbBaseUrl)
    pb.authStore.save(payload.token, null)
    const record = await pb.collection('table_catalogs').update(payload.listId, formData)
    photo = typeof record.photo === 'string' ? record.photo : ''
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
  } finally {
    if (input) input.value = ''
  }

  app.ports.listPhotoProcessed.send({ listId: payload.listId, photo, fileToken, error: errorCode })
})

app.ports.clearListPhoto.subscribe(async (payload) => {
  let error = ''
  try {
    if (!/^[a-z0-9]{10,20}$/i.test(payload.listId)) throw new Error('Invalid list id')

    const PocketBase = (await import('pocketbase')).default
    const pb = new PocketBase(payload.pbBaseUrl)
    pb.authStore.save(payload.token, null)
    await pb.collection('table_catalogs').update(payload.listId, { photo: '' })
  } catch (cause) {
    console.error('List cover removal failed', cause)
    error = 'removal-failed'
  }

  app.ports.listPhotoCleared.send({ listId: payload.listId, error })
})

app.ports.requestListPhotoFileToken.subscribe(async (payload) => {
  let token = ''
  try {
    const PocketBase = (await import('pocketbase')).default
    const pb = new PocketBase(payload.pbBaseUrl)
    pb.authStore.save(payload.token, null)
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
