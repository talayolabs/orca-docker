#!/usr/bin/env node
// Minimal computer-use MCP server for an X11 desktop (Xvfb + xdotool + scrot + wmctrl).
// Runs inside the orca-docker container and is attached to the agent via `claude --mcp-config`.
import { execFile, spawn } from 'node:child_process'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { z } from 'zod'

const execFileAsync = promisify(execFile)
const DISPLAY = process.env.DISPLAY || ':99'
const SCREENSHOT_MAX_WIDTH = Number(process.env.ORCA_DOCKER_SCREENSHOT_MAX_WIDTH || 1280)

async function run(cmd, args, options = {}) {
  const { stdout } = await execFileAsync(cmd, args, {
    env: { ...process.env, DISPLAY },
    maxBuffer: 16 * 1024 * 1024,
    ...options
  })
  return stdout.trim()
}

const xdotool = (...args) => run('xdotool', args)

async function screenSize() {
  const out = await xdotool('getdisplaygeometry')
  const [w, h] = out.split(/\s+/).map(Number)
  return { width: w, height: h }
}

async function screenshot() {
  const dir = await mkdtemp(join(tmpdir(), 'shot-'))
  const raw = join(dir, 'raw.png')
  const out = join(dir, 'out.png')
  try {
    await run('scrot', ['--overwrite', raw])
    await run('convert', [raw, '-resize', `${SCREENSHOT_MAX_WIDTH}x>`, out])
    const buf = await readFile(out)
    const { width, height } = await screenSize()
    return {
      content: [
        { type: 'image', data: buf.toString('base64'), mimeType: 'image/png' },
        {
          type: 'text',
          text: `Screen ${width}x${height}. Image may be downscaled to ${SCREENSHOT_MAX_WIDTH}px wide; coordinates you pass to other tools are in real screen pixels.`
        }
      ]
    }
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}

const text = (t) => ({ content: [{ type: 'text', text: t }] })

function detach(cmd, args) {
  const child = spawn(cmd, args, { env: { ...process.env, DISPLAY }, detached: true, stdio: 'ignore' })
  child.unref()
}

const server = new McpServer({ name: 'orca-docker-computer', version: '0.1.0' })

server.registerTool(
  'screenshot',
  { description: 'Capture the current desktop screen as a PNG image.', inputSchema: {} },
  screenshot
)

server.registerTool(
  'screen_size',
  { description: 'Get the desktop resolution in pixels.', inputSchema: {} },
  async () => text(JSON.stringify(await screenSize()))
)

server.registerTool(
  'cursor_position',
  { description: 'Get the current mouse position.', inputSchema: {} },
  async () => {
    const out = await xdotool('getmouselocation', '--shell')
    const m = Object.fromEntries(out.split('\n').map((l) => l.split('=')))
    return text(JSON.stringify({ x: Number(m.X), y: Number(m.Y) }))
  }
)

server.registerTool(
  'mouse_move',
  { description: 'Move the mouse to absolute screen coordinates.', inputSchema: { x: z.number().int(), y: z.number().int() } },
  async ({ x, y }) => {
    await xdotool('mousemove', String(x), String(y))
    return text(`moved to ${x},${y}`)
  }
)

const buttonSchema = z.enum(['left', 'middle', 'right']).default('left')
const BUTTON = { left: '1', middle: '2', right: '3' }

server.registerTool(
  'click',
  {
    description: 'Click at screen coordinates (or at the current position if x/y omitted).',
    inputSchema: {
      x: z.number().int().optional(),
      y: z.number().int().optional(),
      button: buttonSchema,
      count: z.number().int().min(1).max(3).default(1).describe('1 = single, 2 = double, 3 = triple')
    }
  },
  async ({ x, y, button, count }) => {
    if (x !== undefined && y !== undefined) await xdotool('mousemove', String(x), String(y))
    await xdotool('click', '--repeat', String(count), '--delay', '60', BUTTON[button])
    return text(`${button} click x${count}${x !== undefined ? ` at ${x},${y}` : ''}`)
  }
)

server.registerTool(
  'drag',
  {
    description: 'Press the left button at (x1,y1), move to (x2,y2), release.',
    inputSchema: { x1: z.number().int(), y1: z.number().int(), x2: z.number().int(), y2: z.number().int() }
  },
  async ({ x1, y1, x2, y2 }) => {
    await xdotool('mousemove', String(x1), String(y1), 'mousedown', '1', 'mousemove', String(x2), String(y2), 'mouseup', '1')
    return text(`dragged ${x1},${y1} -> ${x2},${y2}`)
  }
)

server.registerTool(
  'scroll',
  {
    description: 'Scroll at the given position (or current position).',
    inputSchema: {
      x: z.number().int().optional(),
      y: z.number().int().optional(),
      direction: z.enum(['up', 'down', 'left', 'right']),
      amount: z.number().int().min(1).max(50).default(3).describe('number of wheel clicks')
    }
  },
  async ({ x, y, direction, amount }) => {
    if (x !== undefined && y !== undefined) await xdotool('mousemove', String(x), String(y))
    const btn = { up: '4', down: '5', left: '6', right: '7' }[direction]
    await xdotool('click', '--repeat', String(amount), '--delay', '30', btn)
    return text(`scrolled ${direction} x${amount}`)
  }
)

server.registerTool(
  'type',
  {
    description: 'Type literal text into the focused window (use `key` for shortcuts and special keys).',
    inputSchema: { text: z.string().min(1) }
  },
  async ({ text: t }) => {
    await xdotool('type', '--delay', '12', '--', t)
    return text(`typed ${t.length} chars`)
  }
)

server.registerTool(
  'key',
  {
    description:
      'Press a key or key combination using xdotool key syntax, e.g. "Return", "ctrl+l", "alt+Tab", "ctrl+shift+t". Multiple keys may be space-separated to press in sequence.',
    inputSchema: { keys: z.string().min(1) }
  },
  async ({ keys }) => {
    await xdotool('key', '--delay', '40', ...keys.split(/\s+/))
    return text(`pressed ${keys}`)
  }
)

server.registerTool(
  'list_windows',
  { description: 'List open windows (id, desktop, title).', inputSchema: {} },
  async () => text((await run('wmctrl', ['-l'])) || '(no windows)')
)

server.registerTool(
  'focus_window',
  {
    description: 'Raise and focus a window by id (from list_windows) or by title substring.',
    inputSchema: { id: z.string().optional(), title: z.string().optional() }
  },
  async ({ id, title }) => {
    if (id) await run('wmctrl', ['-ia', id])
    else if (title) await run('wmctrl', ['-a', title])
    else throw new Error('id or title required')
    return text(`focused ${id ?? title}`)
  }
)

server.registerTool(
  'open',
  {
    description: 'Open a URL or file with the desktop default handler (URLs open in Chromium).',
    inputSchema: { target: z.string().min(1) }
  },
  async ({ target }) => {
    const isUrl = /^[a-z][a-z0-9+.-]*:\/\//i.test(target)
    detach(isUrl ? 'chromium-wrapper' : 'xdg-open', isUrl ? ['--new-window', target] : [target])
    return text(`opened ${target}`)
  }
)

server.registerTool(
  'launch',
  {
    description: 'Launch a desktop application in the background on the virtual display, e.g. "xfce4-terminal" or "chromium-wrapper https://example.com".',
    inputSchema: { command: z.string().min(1) }
  },
  async ({ command }) => {
    detach('sh', ['-c', command])
    return text(`launched: ${command}`)
  }
)

server.registerTool(
  'publish',
  {
    description:
      'Publish the current branch of the repository to the host: its new commits are fetched into the host repository and pushed to origin (a pull request may be created depending on configuration). Nothing else leaves this container. Optionally commit all uncommitted changes first with the given message.',
    inputSchema: { commit_message: z.string().min(1).optional() }
  },
  async ({ commit_message }) => {
    const args = ['publish']
    if (commit_message) args.push('--commit', commit_message)
    try {
      const { stdout, stderr } = await execFileAsync('orca-docker', args, {
        cwd: process.env.ORCA_DOCKER_REPO || process.cwd(),
        env: process.env,
        timeout: 180_000
      })
      return text((stderr + stdout).trim() || 'published')
    } catch (err) {
      const out = `${err.stderr ?? ''}${err.stdout ?? ''}`.trim()
      return { isError: true, content: [{ type: 'text', text: out || String(err) }] }
    }
  }
)

const transport = new StdioServerTransport()
await server.connect(transport)
