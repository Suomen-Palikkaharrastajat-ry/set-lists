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
