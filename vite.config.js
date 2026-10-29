import { defineConfig } from 'vite'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

export default defineConfig({
  root: './frontend',
  // Keep Vite's dependency cache out of synced folders (Dropbox, OneDrive), which can lock it on Windows.
  cacheDir: join(tmpdir(), 'vite-cache', 'sg-timebank'),
  server: {
    open: true,
    port: 5173,
  },
})
