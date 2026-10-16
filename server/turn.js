import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Router } from 'express';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Long-term Cloudflare TURN key. Kept out of git: either exported as env vars
// on the server process, or dropped into turn/cloudflare.json. The file is
// re-read on demand (mtime-cached) so rotating a key needs no service restart.
const CONFIG_PATH =
  process.env.COMMSUITE_TURN_CONFIG || path.join(__dirname, 'turn', 'cloudflare.json');

let fileCache = { mtime: 0, value: null };

function loadConfigFile() {
  try {
    const st = fs.statSync(CONFIG_PATH);
    if (fileCache.value && st.mtimeMs === fileCache.mtime) return fileCache.value;
    const raw = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
    fileCache = { mtime: st.mtimeMs, value: raw };
    return raw;
  } catch {
    return null;
  }
}

function resolveCreds() {
  const keyId = process.env.CLOUDFLARE_TURN_KEY_ID;
  const apiToken = process.env.CLOUDFLARE_TURN_API_TOKEN;
  if (keyId && apiToken) {
    return { keyId, apiToken, ttl: Number(process.env.CLOUDFLARE_TURN_TTL || 86400) };
  }
  const cfg = loadConfigFile();
  if (cfg && cfg.keyId && cfg.apiToken) {
    return { keyId: cfg.keyId, apiToken: cfg.apiToken, ttl: Number(cfg.ttl || 86400) };
  }
  return null;
}

let cache = { keyId: null, iceServers: null, expiresAt: 0 };
let inflight = null;

async function generate(keyId, apiToken, ttl) {
  const url =
    `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(keyId)}/credentials/generate-ice-servers`;
  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ ttl }),
  });
  const text = await resp.text();
  if (!resp.ok) {
    throw new Error(`Cloudflare TURN ${resp.status}: ${text.slice(0, 300)}`);
  }
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    throw new Error('Cloudflare TURN: invalid JSON response');
  }
  return data.iceServers || [];
}

const router = Router();

// Short-lived Cloudflare TURN credentials for authenticated clients. Returns an
// `iceServers` array ready to hand to RTCPeerConnection.
router.get('/turn', async (req, res) => {
  const creds = resolveCreds();
  if (!creds) {
    return res.status(404).json({ error: 'TURN not configured' });
  }
  const now = Date.now();
  if (cache.iceServers && cache.keyId === creds.keyId && now < cache.expiresAt) {
    return res.json({ iceServers: cache.iceServers, ttl: creds.ttl });
  }
  try {
    if (!inflight || inflight.keyId !== creds.keyId) {
      const promise = generate(creds.keyId, creds.apiToken, creds.ttl)
        .then((servers) => {
          cache = {
            keyId: creds.keyId,
            iceServers: servers,
            expiresAt: Date.now() + Math.max(0, creds.ttl - 300) * 1000,
          };
          return servers;
        })
        .finally(() => {
          if (inflight && inflight.promise === promise) inflight = null;
        });
      inflight = { keyId: creds.keyId, promise };
    }
    const servers = await inflight.promise;
    res.json({ iceServers: servers, ttl: creds.ttl });
  } catch (e) {
    res.status(502).json({ error: String((e && e.message) || e) });
  }
});

export default router;
