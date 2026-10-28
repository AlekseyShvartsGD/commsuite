import { Router } from 'express';
import { fileCrashIssue, reportingConfigured } from './github.js';

const MAX_LOG = 20000;
const MAX_PER_WINDOW = 20;
const WINDOW_MS = 10 * 60 * 1000;

const router = Router();

// Public endpoint, so keep a tiny in-memory throttle per IP to stop it being
// used to spam the issue tracker.
const hits = new Map();
function throttled(ip) {
  const now = Date.now();
  const entry = hits.get(ip) ?? { count: 0, reset: now + WINDOW_MS };
  if (now > entry.reset) {
    entry.count = 0;
    entry.reset = now + WINDOW_MS;
  }
  entry.count += 1;
  hits.set(ip, entry);
  return entry.count > MAX_PER_WINDOW;
}

function cleanSpecs(specs) {
  if (!specs || typeof specs !== 'object') return {};
  const out = {};
  for (const [key, value] of Object.entries(specs)) {
    if (value === null || value === undefined) continue;
    const k = String(key).slice(0, 40).trim();
    const v = String(value).slice(0, 300).trim();
    if (k && v) out[k] = v;
  }
  return out;
}

// POST /api/crash-report — the app's launch-time crash dialog calls this to
// file the crash (timestamp + log + device specs) as a GitHub issue.
router.post('/crash-report', (req, res) => {
  const body = req.body ?? {};
  const log = String(body.log || '').slice(0, MAX_LOG);
  if (!log.trim()) return res.status(400).json({ error: 'log required' });
  if (throttled(req.ip)) return res.status(429).json({ error: 'too many reports' });

  const report = {
    timestamp: String(body.timestamp || new Date().toISOString()).slice(0, 40),
    log,
    platform: String(body.platform || '').slice(0, 200),
    appVersion: String(body.appVersion || '').slice(0, 60),
    username: String(body.username || '').slice(0, 60),
    specs: cleanSpecs(body.specs),
  };
  res.json({ ok: true });

  if (reportingConfigured()) {
    fileCrashIssue(report)
      .then((issue) => {
        if (issue.number) console.log(`Crash report -> issue #${issue.number}`);
      })
      .catch((err) => console.error('Crash report -> GitHub issue failed:', err.message));
  }
});

export default router;
