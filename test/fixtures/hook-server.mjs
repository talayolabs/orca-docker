// Fake Orca hook listener: records every POST to a JSONL file. Usage: node hook-server.mjs <port> <out.jsonl>
import { createServer } from 'node:http'
import { appendFileSync } from 'node:fs'

const [port, out] = process.argv.slice(2)
createServer((req, res) => {
  let body = ''
  req.on('data', (c) => (body += c))
  req.on('end', () => {
    appendFileSync(out, JSON.stringify({ url: req.url, headers: req.headers, body }) + '\n')
    res.writeHead(200).end('{}')
  })
}).listen(Number(port), '127.0.0.1', () => console.log(`listening ${port}`))
