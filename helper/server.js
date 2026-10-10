// Local helper server for the IMD protocol payment flow.
// - Serves the page and the bundled client from ./public
// - Proxies the few api.imd.fun routes the page needs (the API refuses cross-origin browser calls)
// - Holds the IMD "request token" (a random bearer that lets you read your own orders later) in ./.token
// It never sees a private key: every signature happens in your browser wallet.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8787);
const IMD_API = process.env.IMD_API || 'https://api.imd.fun';
const TOKEN_FILE = path.join(__dirname, '.token');

function token() {
  if (!fs.existsSync(TOKEN_FILE)) fs.writeFileSync(TOKEN_FILE, crypto.randomBytes(32).toString('hex'));
  return fs.readFileSync(TOKEN_FILE, 'utf8').trim();
}

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css', '.json': 'application/json' };

async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks).toString('utf8');
}

async function proxy(req, res, method, apiPath, { auth = false, body = null, headers = {} } = {}) {
  const h = { 'content-type': 'application/json', ...headers };
  if (auth) h.authorization = `Bearer ${token()}`;
  const r = await fetch(IMD_API + apiPath, { method, headers: h, body: body == null ? undefined : body });
  const text = await r.text();
  res.writeHead(r.status, { 'content-type': 'application/json', 'x-upstream-status': String(r.status) });
  res.end(text);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const p = url.pathname;
    if (p.startsWith('/api/')) {
      if (p === '/api/capabilities' && req.method === 'GET') return proxy(req, res, 'GET', '/requests/capabilities');
      if (p === '/api/check' && req.method === 'POST') return proxy(req, res, 'POST', '/requests/check', { body: await readBody(req) });
      if (p === '/api/quote' && req.method === 'POST') return proxy(req, res, 'POST', '/requests/quote', { auth: true, body: await readBody(req) });
      const sub = p.match(/^\/api\/submit\/([A-Za-z0-9_-]+)$/);
      if (sub && req.method === 'POST') {
        const body = await readBody(req);
        const headers = {};
        const sig = req.headers['payment-signature'];
        if (sig) headers['PAYMENT-SIGNATURE'] = Array.isArray(sig) ? sig[0] : sig;
        return proxy(req, res, 'POST', `/requests/${sub[1]}/submit`, { auth: true, body: body || null, headers });
      }
      const ord = p.match(/^\/api\/requests\/([A-Za-z0-9_-]+)$/);
      if (ord && req.method === 'GET') return proxy(req, res, 'GET', `/requests/${ord[1]}`, { auth: true });
      const job = p.match(/^\/api\/jobs\/([A-Za-z0-9_-]+)$/);
      if (job && req.method === 'GET') return proxy(req, res, 'GET', `/jobs/${job[1]}`);
      const launch = p.match(/^\/api\/launches\/([A-Za-z0-9_-]+)$/);
      if (launch && req.method === 'GET') return proxy(req, res, 'GET', `/launches/${launch[1]}`);
      res.writeHead(404, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ error: 'unknown route' }));
    }
    if (p === '/jobs' && req.method === 'GET') {
      // the saved job bodies, for the page's presets
      const dir = path.join(__dirname, '..', 'jobs');
      const files = fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => f.endsWith('.json')) : [];
      const out = {};
      for (const f of files) out[f] = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify(out));
    }
    const file = path.join(__dirname, 'public', p === '/' ? 'index.html' : p);
    if (!file.startsWith(path.join(__dirname, 'public')) || !fs.existsSync(file)) {
      res.writeHead(404);
      return res.end('not found');
    }
    res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  } catch (e) {
    res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: String(e?.message || e) }));
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Marginalia helper on http://127.0.0.1:${PORT}  (proxying ${IMD_API}; token in ${TOKEN_FILE})`);
});
