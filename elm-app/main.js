import './main.css'
import { Elm } from './src/Main.elm'
import siteConfig from 'virtual:site-config'
import { getInitAuth, wirePocketBaseAuthPorts, triggerBackgroundAuthRefresh } from './packages/app-toolkit/js/pocketbase-auth.js'
import { appSettings, pickLang, showLanguage } from './packages/site-config/browser.mjs'

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

const setSearchTimers = new Map()
app.ports.scheduleSetSearch.subscribe((payload) => {
  const previous = setSearchTimers.get(payload.index)
  if (previous) clearTimeout(previous)
  const timer = setTimeout(() => {
    setSearchTimers.delete(payload.index)
    app.ports.setSearchReady.send(payload)
  }, 1000)
  setSearchTimers.set(payload.index, timer)
})

async function decodeThumbnailImage(blob) {
  if (typeof createImageBitmap === 'function') {
    const image = await createImageBitmap(blob)
    return { image, release: () => image.close() }
  }
  const objectUrl = URL.createObjectURL(blob)
  const image = new Image()
  image.src = objectUrl
  try {
    await image.decode()
    return { image, release: () => URL.revokeObjectURL(objectUrl) }
  } catch (error) {
    URL.revokeObjectURL(objectUrl)
    throw error
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
      if (sourceBlob.size === 0 || sourceBlob.size > 1_000_000) throw new Error('Invalid thumbnail size')

      const decoded = await decodeThumbnailImage(sourceBlob)
      try {
        const image = decoded.image
        const sourceWidth = image.width || image.naturalWidth
        const sourceHeight = image.height || image.naturalHeight
        if (!sourceWidth || !sourceHeight) throw new Error('Invalid thumbnail dimensions')
        const scale = Math.min(1, 256 / sourceWidth, 256 / sourceHeight)
        const canvas = document.createElement('canvas')
        canvas.width = Math.max(1, Math.round(sourceWidth * scale))
        canvas.height = Math.max(1, Math.round(sourceHeight * scale))
        const context = canvas.getContext('2d')
        if (!context) throw new Error('Canvas unavailable')
        context.drawImage(image, 0, 0, canvas.width, canvas.height)
        const webp = await new Promise((resolve) => canvas.toBlob(resolve, 'image/webp', 0.82))
        if (!webp || webp.type !== 'image/webp' || webp.size > 200_000) throw new Error('WebP conversion failed')

        const file = new File([webp], `set-${payload.code}.webp`, { type: 'image/webp' })
        try {
          record = await collection.create({ code: payload.code, thumbnail: file })
        } catch (error) {
          // If another editor stored the same set concurrently, reuse that file.
          record = await findStoredThumbnail(collection, payload.code)
          if (!record) throw error
        }
      } finally {
        decoded.release()
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
