import { defineConfig } from 'vite'
import tailwindcss from '@tailwindcss/vite'
import elmTailwind from 'elm-tailwind-classes/vite'
import elm from 'vite-plugin-elm'
import siteConfig from './packages/site-config/vite.mjs'

export default defineConfig({
  plugins: [siteConfig(), elmTailwind(), elm(), tailwindcss()],
  publicDir: 'public',
  build: { outDir: '../dist', emptyOutDir: true },
  base: '/',
  cacheDir: '.vite',
})
