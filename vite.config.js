import { defineConfig } from 'vite'
import { realpathSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Resolve the real path of ./frontend. On Windows a project opened through a junction or
// symlink (e.g. C:\Users\me\hungthq -> C:\hungthq) otherwise gives Vite two different paths
// for the same files, which breaks "Failed to load url /app.js".
const frontendRoot = realpathSync(fileURLToPath(new URL('./frontend', import.meta.url)))

export default defineConfig({
  root: frontendRoot,
  // Keep Vite's dependency cache out of synced folders (Dropbox, OneDrive), which can lock it on Windows.
  cacheDir: join(tmpdir(), 'vite-cache', 'sg-timebank'),
  server: {
    open: true,
    port: 5173,
  },
})
