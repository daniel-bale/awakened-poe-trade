import { build } from 'esbuild'
import { mkdir, stat } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const directory = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(directory, '../..')
const renderer = path.join(root, 'renderer/src')
const output = path.join(root, 'native-macos/Sources/TradeCore/Resources/trade-core.js')
await mkdir(path.dirname(output), { recursive: true })

// Keep native execution independent of browser globals, Vue, HTTP, and Electron.
// Parsing, preset creation, and query construction remain the original modules.
const boundaries = new Map([
  [path.join(renderer, 'assets/data'), path.join(directory, 'src/data.ts')],
  [path.join(renderer, 'web/background/IPC'), path.join(directory, 'src/platform.ts')],
  [path.join(renderer, 'web/background/Leagues'), path.join(directory, 'src/platform.ts')],
  [path.join(renderer, 'web/price-check/trade/common'), path.join(directory, 'src/platform.ts')],
  [path.join(renderer, 'web/price-check/trade/RateLimiter'), path.join(directory, 'src/platform.ts')],
  [path.join(renderer, 'web/price-check/trade/Cache'), path.join(directory, 'src/platform.ts')]
])

await build({
  entryPoints: [path.join(directory, 'src/index.ts')],
  outfile: output,
  bundle: true,
  format: 'iife',
  globalName: 'NativeTrade',
  platform: 'browser',
  target: 'safari15',
  minify: true,
  legalComments: 'inline',
  nodePaths: [path.join(directory, 'node_modules')],
  loader: { '.ndjson': 'text' },
  plugins: [{
    name: 'native-platform-boundary',
    setup (builder) {
      builder.onResolve({ filter: /^(?:@\/|\.)/ }, async args => {
        const resolved = args.path.startsWith('@/')
          ? path.join(renderer, args.path.slice(2))
          : path.resolve(args.resolveDir, args.path)
        const boundary = boundaries.get(resolved.replace(/\.[cm]?[jt]s$/, ''))
        if (boundary) return { path: boundary, sideEffects: false }
        if (args.path.startsWith('@/')) {
          for (const candidate of [resolved, `${resolved}.ts`, `${resolved}.js`, path.join(resolved, 'index.ts')]) {
            if (await stat(candidate).then(s => s.isFile(), () => false)) return { path: candidate }
          }
        }
      })
    }
  }]
})
console.log(`Built ${path.relative(root, output)}`)
