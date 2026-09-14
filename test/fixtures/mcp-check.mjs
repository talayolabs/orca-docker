// Runs inside the container: speaks MCP over stdio to the computer-use server and exercises
// screenshot + list_windows. Exits non-zero on any failure.
import { spawn } from 'node:child_process'

const proc = spawn('node', ['/opt/orca-docker/mcp/computer-use/server.mjs'], { stdio: ['pipe', 'pipe', 'inherit'] })
let buf = ''
const pending = new Map()
proc.stdout.on('data', (d) => {
  buf += d
  let i
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim()
    buf = buf.slice(i + 1)
    if (!line) continue
    const msg = JSON.parse(line)
    if (msg.id !== undefined && pending.has(msg.id)) {
      pending.get(msg.id)(msg)
      pending.delete(msg.id)
    }
  }
})
let nextId = 1
const call = (method, params) =>
  new Promise((resolve, reject) => {
    const id = nextId++
    pending.set(id, (m) => (m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result)))
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
    setTimeout(() => reject(new Error(`timeout: ${method}`)), 20000)
  })

const assert = (c, m) => { if (!c) { console.error('FAIL:', m); process.exit(1) } }

const init = await call('initialize', {
  protocolVersion: '2025-06-18',
  capabilities: {},
  clientInfo: { name: 'smoke', version: '0' }
})
assert(init.serverInfo?.name === 'orca-docker-computer', 'serverInfo')
proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n')

const tools = (await call('tools/list', {})).tools.map((t) => t.name)
for (const t of ['screenshot', 'click', 'type', 'key', 'list_windows', 'open', 'publish']) assert(tools.includes(t), `tool ${t}`)

if (process.argv[2] === '--publish') {
  // Exercises the publish tool end to end (needs the host wrapper attached to answer).
  const pub = await call('tools/call', { name: 'publish', arguments: { commit_message: 'mcp publish smoke' } })
  const txt = pub.content[0].text
  assert(!pub.isError && txt.includes('published'), `publish tool: ${txt}`)
}

const shot = await call('tools/call', { name: 'screenshot', arguments: {} })
const img = shot.content.find((c) => c.type === 'image')
assert(img && img.mimeType === 'image/png' && img.data.length > 1000, 'screenshot image')

const size = JSON.parse((await call('tools/call', { name: 'screen_size', arguments: {} })).content[0].text)
assert(size.width > 0 && size.height > 0, 'screen_size')

await call('tools/call', { name: 'mouse_move', arguments: { x: 10, y: 10 } })
const pos = JSON.parse((await call('tools/call', { name: 'cursor_position', arguments: {} })).content[0].text)
assert(pos.x === 10 && pos.y === 10, `cursor moved (${pos.x},${pos.y})`)

const wins = (await call('tools/call', { name: 'list_windows', arguments: {} })).content[0].text
assert(wins.includes('xfce4-panel'), 'xfce panel window listed')

console.log(`mcp ok: ${tools.length} tools, screen ${size.width}x${size.height}, screenshot ${img.data.length}b`)
proc.kill()
process.exit(0)
