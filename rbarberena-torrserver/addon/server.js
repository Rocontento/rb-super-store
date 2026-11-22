// Stremio addon: asks Torrentio for torrents and returns them as direct HTTP
// links to this Umbrel's TorrServer, so clients without a torrent engine
// (NuvioTV, Omni…) can play them without a debrid service.
//
//   /manifest.json                  plain Torrentio
//   /<torrentio-config>/manifest.json  same config segment as a configured
//                                      Torrentio URL (providers, quality…)
const http = require('node:http');

const PORT = Number(process.env.PORT) || 8294;
const TORRENTIO = (process.env.TORRENTIO_URL || 'https://torrentio.strem.fun').replace(/\/+$/, '');
const TS_PORT = process.env.TORRSERVER_PORT || '8293';
// Unset = same host the client used to reach this addon, so the Apple TV
// gets an address it can already reach (LAN IP, umbrel.local, Tailscale…).
const TS_URL = process.env.TORRSERVER_URL;

const CONFIG_RE = /^[A-Za-z0-9=,|%._~-]+$/;
const ID_RE = /^tt\d+(:\d+:\d+)?$/;

const manifest = {
  id: 'com.rbarberena.torrserver',
  version: '1.0.0',
  name: 'TorrServer (Umbrel)',
  description: 'Torrentio sin debrid: los torrents se reproducen a través del TorrServer de tu Umbrel.',
  resources: ['stream'],
  types: ['movie', 'series'],
  idPrefixes: ['tt'],
  catalogs: [],
};

function torrserverBase(req) {
  if (TS_URL) return TS_URL.replace(/\/+$/, '');
  const host = (req.headers.host || 'localhost').replace(/:\d+$/, '');
  return `http://${host}:${TS_PORT}`;
}

function toStream(s, base) {
  if (!s.infoHash) return null;
  const hints = s.behaviorHints || {};
  // Torrentio's fileIdx is 0-based; TorrServer's index is 1-based.
  const index = Number.isInteger(s.fileIdx) ? s.fileIdx + 1 : 1;
  const name = encodeURIComponent(hints.filename || 'video');
  return {
    name: s.name,
    title: s.title,
    url: `${base}/stream/${name}?link=${s.infoHash}&index=${index}&play`,
    behaviorHints: { ...hints, notWebReady: true },
  };
}

async function streams(config, type, id, req) {
  const prefix = config ? `/${config}` : '';
  const res = await fetch(`${TORRENTIO}${prefix}/stream/${type}/${id}.json`, {
    signal: AbortSignal.timeout(25000),
  });
  if (!res.ok) throw new Error(`Torrentio HTTP ${res.status}`);
  const data = await res.json();
  const base = torrserverBase(req);
  return (data.streams || []).map((s) => toStream(s, base)).filter(Boolean);
}

function send(res, code, body) {
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'max-age=300',
  });
  res.end(JSON.stringify(body));
}

const server = http.createServer(async (req, res) => {
  const parts = decodeURIComponent(new URL(req.url, 'http://x').pathname)
    .split('/')
    .filter(Boolean);
  // Optional leading Torrentio config segment.
  const config = parts.length && parts[0].includes('=') ? parts.shift() : '';
  if (config && !CONFIG_RE.test(config)) return send(res, 400, { error: 'bad config' });

  if (parts.length === 1 && parts[0] === 'manifest.json') return send(res, 200, manifest);

  if (parts.length === 3 && parts[0] === 'stream') {
    const type = parts[1];
    const id = parts[2].replace(/\.json$/, '');
    if (!['movie', 'series'].includes(type) || !ID_RE.test(id)) return send(res, 404, { streams: [] });
    try {
      return send(res, 200, { streams: await streams(config, type, id, req) });
    } catch (err) {
      console.error(`stream ${type}/${id}: ${err.message}`);
      return send(res, 200, { streams: [] });
    }
  }
  send(res, 404, { error: 'not found' });
});

server.listen(PORT, '0.0.0.0', () => console.log(`addon on :${PORT}/manifest.json`));
