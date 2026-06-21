// Tiny preview server for openchoreo-import. Serves <preview>/current/content/
// wrapped in a frame (../assets/frames/<NAME>.html, picked by an `oc-frame` directive),
// auto-injecting tokens/components/helper. WebSocket pushes {type:'reload'} on change. Node stdlib only.

'use strict';
const crypto = require('crypto');
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = process.env.OC_PREVIEW_DIR;
if (!ROOT) { console.error('OC_PREVIEW_DIR not set'); process.exit(1); }
const RUNS_DIR     = path.join(ROOT, 'runs');
const CURRENT_LINK = path.join(ROOT, 'current');
const SERVER_STATE = path.join(ROOT, 'server-state');
const PORT      = parseInt(process.env.OC_PORT || '0', 10);
const OWNER_PID = parseInt(process.env.OC_OWNER_PID || '0', 10);

const ASSETS_DIR    = path.join(__dirname, '..', 'assets');
const FRAME_DEFAULT = path.join(ASSETS_DIR, 'frame.html');
const FRAMES_DIR    = path.join(ASSETS_DIR, 'frames');
const HELPER_JS     = path.join(ASSETS_DIR, 'helper.js');
const TOKENS_CSS    = path.join(ASSETS_DIR, 'tokens.css');
const COMPONENTS_CSS = path.join(ASSETS_DIR, 'components.css');
const LOGO_SVG      = path.join(ASSETS_DIR, 'logo.svg');
const VENDOR_CD     = path.join(ASSETS_DIR, 'vendor', 'cell-diagram');

fs.mkdirSync(SERVER_STATE, { recursive: true });
fs.mkdirSync(RUNS_DIR, { recursive: true });

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript; charset=utf-8',
  '.mjs':  'application/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.md':   'text/markdown; charset=utf-8',
  '.svg':  'image/svg+xml',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.gif':  'image/gif',
  '.ico':  'image/x-icon',
};

function currentRunDir() {
  try { return fs.realpathSync(CURRENT_LINK); }
  catch (e) { return null; }
}

const TOKENS_INJECTION = '<link rel="stylesheet" href="/__tokens.css">';
const COMPONENTS_INJECTION = '<link rel="stylesheet" href="/__components.css">';
const HELPER_INJECTION = '<script src="/__helper.js" defer></script>';
function injectAssets(html) {
  if (!html.includes('/__tokens.css')) {
    if (html.includes('</head>')) html = html.replace('</head>', '  ' + TOKENS_INJECTION + '\n</head>');
    else html = TOKENS_INJECTION + '\n' + html;
  }
  if (!html.includes('/__components.css')) {
    if (html.includes('</head>')) html = html.replace('</head>', '  ' + COMPONENTS_INJECTION + '\n</head>');
    else html = COMPONENTS_INJECTION + '\n' + html;
  }
  if (!html.includes('/__helper.js')) {
    if (html.includes('</body>')) html = html.replace('</body>', '  ' + HELPER_INJECTION + '\n</body>');
    else html = html + '\n' + HELPER_INJECTION;
  }
  return html;
}

const WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const OP = { TEXT: 0x1, CLOSE: 0x8, PING: 0x9, PONG: 0xA };

function acceptKey(clientKey) {
  return crypto.createHash('sha1').update(clientKey + WS_MAGIC).digest('base64');
}
function encodeFrame(opcode, payload) {
  const fin = 0x80, len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[0] = fin | opcode;
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = fin | opcode;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = fin | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payload]);
}
function decodeFrame(buf) {
  if (buf.length < 2) return null;
  const second = buf[1];
  const opcode = buf[0] & 0x0F;
  const masked = (second & 0x80) !== 0;
  let len = second & 0x7F;
  let off = 2;
  if (!masked) throw new Error('client frames must be masked');
  if (len === 126) { if (buf.length < 4) return null; len = buf.readUInt16BE(2); off = 4; }
  else if (len === 127) { if (buf.length < 10) return null; len = Number(buf.readBigUInt64BE(2)); off = 10; }
  const total = off + 4 + len;
  if (buf.length < total) return null;
  const mask = buf.subarray(off, off + 4);
  const data = Buffer.alloc(len);
  for (let i = 0; i < len; i++) data[i] = buf[off + 4 + i] ^ mask[i % 4];
  return { opcode, payload: data, consumed: total };
}

const clients = new Set();
function broadcastReload() {
  const frame = encodeFrame(OP.TEXT, Buffer.from(JSON.stringify({ type: 'reload' })));
  for (const sock of clients) {
    try { sock.write(frame); } catch (e) { clients.delete(sock); }
  }
}
function handleClientEvent(text) {
  let event;
  try { event = JSON.parse(text); } catch (e) { return; }
  const run = currentRunDir();
  if (!run) return;
  const stateDir = path.join(run, 'state');
  fs.mkdirSync(stateDir, { recursive: true });
  const line = JSON.stringify({ ts: new Date().toISOString(), ...event }) + '\n';
  fs.appendFileSync(path.join(stateDir, 'events.jsonl'), line);
}

function handleUpgrade(req, sock) {
  const key = req.headers['sec-websocket-key'];
  if (!key) { sock.destroy(); return; }
  sock.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    'Sec-WebSocket-Accept: ' + acceptKey(key) + '\r\n\r\n'
  );
  let buf = Buffer.alloc(0);
  clients.add(sock);
  sock.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length > 0) {
      let f;
      try { f = decodeFrame(buf); }
      catch (e) { try { sock.end(encodeFrame(OP.CLOSE, Buffer.alloc(0))); } catch (_) {} clients.delete(sock); return; }
      if (!f) break;
      buf = buf.subarray(f.consumed);
      if (f.opcode === OP.TEXT)  handleClientEvent(f.payload.toString());
      else if (f.opcode === OP.PING) { try { sock.write(encodeFrame(OP.PONG, f.payload)); } catch (_) {} }
      else if (f.opcode === OP.CLOSE) { try { sock.end(encodeFrame(OP.CLOSE, Buffer.alloc(0))); } catch (_) {} clients.delete(sock); return; }
    }
  });
  sock.on('close', () => clients.delete(sock));
  sock.on('error', () => clients.delete(sock));
}

let contentWatcher = null;
let watchedIndex = null;
let watchTimer = null;
function fireContentChange(run) {
  clearTimeout(watchTimer);
  watchTimer = setTimeout(() => {
    try {
      const evFile = path.join(run, 'state', 'events.jsonl');
      if (fs.existsSync(evFile)) fs.truncateSync(evFile, 0);
    } catch (e) {}
    broadcastReload();
  }, 120);
}
function rearmContentWatcher() {
  if (contentWatcher) { try { contentWatcher.close(); } catch (e) {} contentWatcher = null; }
  if (watchedIndex)   { try { fs.unwatchFile(watchedIndex); } catch (e) {} watchedIndex = null; }
  const run = currentRunDir();
  if (!run) return;
  const contentDir = path.join(run, 'content');
  try {
    fs.mkdirSync(contentDir, { recursive: true });
    contentWatcher = fs.watch(contentDir, { persistent: true }, () => fireContentChange(run));
    watchedIndex = path.join(contentDir, 'index.html');
    // fs.watchFile poll backs up fs.watch — macOS fs.watch can miss atomic-write events.
    fs.watchFile(watchedIndex, { interval: 1500, persistent: true }, (curr, prev) => {
      if (curr.mtime.getTime() !== prev.mtime.getTime() || curr.size !== prev.size) fireContentChange(run);
    });
  } catch (e) { console.error('content watcher failed:', e.message); }
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  if (req.method === 'GET' && url === '/__helper.js') {
    fs.readFile(HELPER_JS, (err, data) => {
      if (err) { res.writeHead(500); res.end('helper missing'); return; }
      res.writeHead(200, { 'Content-Type': MIME['.js'], 'Content-Length': data.length, 'Cache-Control': 'no-store' });
      res.end(data);
    });
    return;
  }

  if (req.method === 'GET' && url === '/__tokens.css') {
    fs.readFile(TOKENS_CSS, (err, data) => {
      if (err) { res.writeHead(500); res.end('tokens missing'); return; }
      res.writeHead(200, { 'Content-Type': MIME['.css'], 'Content-Length': data.length, 'Cache-Control': 'no-store' });
      res.end(data);
    });
    return;
  }

  if (req.method === 'GET' && url === '/__components.css') {
    fs.readFile(COMPONENTS_CSS, (err, data) => {
      if (err) { res.writeHead(500); res.end('components missing'); return; }
      res.writeHead(200, { 'Content-Type': MIME['.css'], 'Content-Length': data.length, 'Cache-Control': 'no-store' });
      res.end(data);
    });
    return;
  }

  if (req.method === 'GET' && url === '/__logo.svg') {
    fs.readFile(LOGO_SVG, (err, data) => {
      if (err) { res.writeHead(500); res.end('logo missing'); return; }
      res.writeHead(200, { 'Content-Type': MIME['.svg'], 'Content-Length': data.length, 'Cache-Control': 'no-store' });
      res.end(data);
    });
    return;
  }

  // Served under /__cd/ so the bundle's `auto` publicPath resolves relative asset URLs.
  if (req.method === 'GET' && url.startsWith('/__cd/')) {
    const file = path.normalize(path.join(VENDOR_CD, url.slice('/__cd/'.length)));
    const rel = path.relative(VENDOR_CD, file);
    if (rel.startsWith('..') || path.isAbsolute(rel)) { res.writeHead(403); res.end(); return; }
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); res.end('not found'); return; }
      const ext = path.extname(file).toLowerCase();
      res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream', 'Content-Length': data.length, 'Cache-Control': 'no-store' });
      res.end(data);
    });
    return;
  }

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405); res.end('method not allowed'); return;
  }

  const run = currentRunDir();
  if (!run) { res.writeHead(503); res.end('no current run'); return; }
  const contentDir = path.join(run, 'content');
  let urlPath = url === '/' ? '/index.html' : url;
  const filePath = path.normalize(path.join(contentDir, urlPath));
  const contentRel = path.relative(contentDir, filePath);
  if (contentRel.startsWith('..') || path.isAbsolute(contentRel)) { res.writeHead(403); res.end(); return; }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      if (url === '/' || urlPath === '/index.html') {
        const html = injectAssets(
          '<!doctype html><html><head><meta charset="utf-8"><title>Not ready yet</title>' +
          '<style>body{font-family:var(--font-sans,system-ui,sans-serif);background:var(--bg-soft,#f8fafc);' +
          'color:var(--ink-mute,#64748b);display:flex;align-items:center;justify-content:center;' +
          'min-height:100vh;margin:0;font-size:.92rem}div{text-align:center;max-width:420px;padding:2rem}' +
          '</style></head><body>' +
          '<div>The agent has not written content yet. This page will reload when it does.</div>' +
          '</body></html>'
        );
        const buf = Buffer.from(html, 'utf8');
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': buf.length, 'Cache-Control': 'no-store' });
        if (req.method === 'HEAD') { res.end(); return; }
        res.end(buf);
        return;
      }
      res.writeHead(404, { 'Content-Type': 'text/plain' }); res.end('not found'); return;
    }
    const ext = path.extname(filePath).toLowerCase();
    const mime = MIME[ext] || 'application/octet-stream';

    if (ext === '.html') {
      const text = data.toString('utf8');
      const isFullDoc = /^\s*<(!doctype|html)\b/i.test(text);
      let html;
      if (!isFullDoc) {
        try {
          const head = text.slice(0, 500);
          const m = head.match(/<!--\s*oc-frame:\s*([a-z0-9_-]+)\s*-->/i);
          let framePath = FRAME_DEFAULT;
          if (m) {
            const candidate = path.join(FRAMES_DIR, m[1] + '.html');
            if (candidate.startsWith(FRAMES_DIR) && fs.existsSync(candidate)) framePath = candidate;
          }
          const frame = fs.readFileSync(framePath, 'utf8');
          html = frame.replace('<!-- CONTENT -->', text);
        } catch (e) {
          console.error('frame load failed:', e.message);
          html = text;
        }
      } else {
        html = text;
      }
      html = injectAssets(html);
      const buf = Buffer.from(html, 'utf8');
      res.writeHead(200, { 'Content-Type': mime, 'Content-Length': buf.length, 'Cache-Control': 'no-store' });
      if (req.method === 'HEAD') { res.end(); return; }
      res.end(buf);
      return;
    }

    res.writeHead(200, { 'Content-Type': mime, 'Content-Length': data.length, 'Cache-Control': 'no-store' });
    if (req.method === 'HEAD') { res.end(); return; }
    res.end(data);
  });
});

server.on('upgrade', handleUpgrade);

server.listen(PORT, '127.0.0.1', () => {
  const port = server.address().port;
  const url = `http://127.0.0.1:${port}`;
  const info = {
    url, pid: process.pid, port,
    started_at: new Date().toISOString(),
    preview_dir: ROOT,
    owner_pid: OWNER_PID || null,
  };
  fs.writeFileSync(path.join(SERVER_STATE, 'server-info.json'), JSON.stringify(info, null, 2));
  rearmContentWatcher();
  process.stdout.write(JSON.stringify({ event: 'server-started', url, port, pid: process.pid }) + '\n');
});

if (OWNER_PID > 0) {
  // process.kill(pid, 0) probes existence without signaling: no throw = alive;
  // EPERM = alive but owned by another user; ESRCH = dead.
  setInterval(() => {
    try { process.kill(OWNER_PID, 0); }
    catch (e) {
      if (e.code === 'EPERM') return;
      console.error(`owner pid ${OWNER_PID} is gone — exiting`);
      process.exit(0);
    }
  }, 60_000).unref();
}

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT',  () => process.exit(0));
