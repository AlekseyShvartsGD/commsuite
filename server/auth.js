import { Router } from 'express';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import db, { dataDir, publicUser } from './db.js';
import {
  generateRecoveryCodes,
  generateSecret,
  normalizeRecoveryCode,
  otpauthUrl,
  verifyTotp,
} from './totp.js';

const secretFile = path.join(dataDir, 'jwt.secret');
let JWT_SECRET;
if (fs.existsSync(secretFile)) {
  JWT_SECRET = fs.readFileSync(secretFile, 'utf8').trim();
} else {
  JWT_SECRET = crypto.randomBytes(48).toString('hex');
  fs.writeFileSync(secretFile, JWT_SECRET, { mode: 0o600 });
}

const TOKEN_TTL = '120d';

// A signed, short-lived challenge proves the password step succeeded without
// creating a session yet. The attempt counter is memory-only: restarting the
// server simply forces people to enter their password again.
const TWO_FACTOR_TTL = '5m';
const TWO_FACTOR_MAX_ATTEMPTS = 5;
const twoFactorAttempts = new Map(); // challenge -> { count, expires }

function pruneChallenges(now = Date.now()) {
  if (twoFactorAttempts.size < 200) return;
  for (const [challenge, entry] of twoFactorAttempts) {
    if (entry.expires <= now) twoFactorAttempts.delete(challenge);
  }
}

/// Recovery codes are bcrypt-hashed at rest. Marking the row used atomically
/// makes every code single-use even if two requests race.
function consumeRecoveryCode(userId, code) {
  const normalized = normalizeRecoveryCode(code);
  if (!normalized) return false;
  const rows = db
    .prepare(
      'SELECT id, code_hash FROM totp_recovery_codes WHERE user_id = ? AND used_at IS NULL'
    )
    .all(userId);
  for (const row of rows) {
    if (!bcrypt.compareSync(normalized, row.code_hash)) continue;
    const result = db
      .prepare('UPDATE totp_recovery_codes SET used_at = ? WHERE id = ? AND used_at IS NULL')
      .run(Date.now(), row.id);
    return result.changes > 0;
  }
  return false;
}

export function signToken(user) {
  return jwt.sign(
    { sub: user.id, username: user.username, displayName: user.display_name },
    JWT_SECRET,
    { expiresIn: TOKEN_TTL }
  );
}

export function verifyToken(token) {
  return jwt.verify(token, JWT_SECRET);
}

export function resolveToken(token) {
  if (token.startsWith('cmsb_')) {
    const row = db
      .prepare(
        `SELECT u.*, b.enabled AS bot_enabled
         FROM bots b JOIN users u ON u.id = b.user_id
         WHERE b.token = ?`
      )
      .get(token);
    if (!row || !row.bot_enabled) throw new Error('invalid bot token');
    return {
      sub: row.id,
      username: row.username,
      displayName: row.display_name,
      bot: true,
    };
  }
  return verifyToken(token);
}

export function authMiddleware(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: 'unauthorized' });
  try {
    req.user = resolveToken(token);
    const row = db.prepare('SELECT role FROM users WHERE id = ?').get(req.user.sub);
    if (!row) return res.status(401).json({ error: 'unknown user' });
    if (row.role === 'banned') return res.status(403).json({ error: 'account banned' });
    next();
  } catch {
    res.status(401).json({ error: 'invalid or expired token' });
  }
}

const USERNAME_RE = /^[a-z0-9_.-]{3,32}$/;

const router = Router();

router.post('/register', (req, res) => {
  const username = String(req.body?.username || '')
    .trim()
    .toLowerCase();
  const displayName = String(req.body?.displayName || req.body?.username || '').trim();
  const bio = String(req.body?.bio || '').trim().slice(0, 300);
  const password = String(req.body?.password || '');

  if (!USERNAME_RE.test(username))
    return res.status(400).json({
      error: 'username must be 3-32 chars: a-z, 0-9, underscore, dot, dash',
    });
  if (password.length < 6)
    return res.status(400).json({ error: 'password must be at least 6 characters' });
  if (displayName.length < 1 || displayName.length > 64)
    return res.status(400).json({ error: 'display name must be 1-64 characters' });

  const exists = db.prepare('SELECT id FROM users WHERE username = ?').get(username);
  if (exists) return res.status(409).json({ error: 'username already taken' });

  const row = {
    id: crypto.randomUUID(),
    username,
    display_name: displayName,
    bio,
    password_hash: bcrypt.hashSync(password, 10),
    created_at: Date.now(),
  };
  db.prepare(
    `INSERT INTO users (id, username, display_name, bio, password_hash, created_at)
     VALUES (@id, @username, @display_name, @bio, @password_hash, @created_at)`
  ).run(row);

  res.status(201).json({ token: signToken(row), user: publicUser(row) });
});

router.post('/login', (req, res) => {
  const username = String(req.body?.username || '').trim().toLowerCase();
  const password = String(req.body?.password || '');
  const row = db.prepare('SELECT * FROM users WHERE username = ?').get(username);
  if (!row)
    return res.status(401).json({ error: 'invalid username or password' });
  if (row.role === 'bot')
    return res.status(403).json({ error: 'bot accounts cannot sign in' });
  if (!bcrypt.compareSync(password, row.password_hash))
    return res.status(401).json({ error: 'invalid username or password' });
  if (row.role === 'banned')
    return res.status(403).json({ error: 'account banned' });
  if (row.totp_enabled) {
    pruneChallenges();
    const challenge = jwt.sign(
      { sub: row.id, purpose: '2fa' },
      JWT_SECRET,
      { expiresIn: TWO_FACTOR_TTL }
    );
    return res.json({ twoFactorRequired: true, challenge });
  }
  res.json({ token: signToken(row), user: publicUser(row) });
});

router.post('/login/2fa', (req, res) => {
  const challenge = String(req.body?.challenge || '');
  const code = String(req.body?.code || '').trim();
  if (!challenge || !code)
    return res.status(400).json({ error: 'two-factor code required' });
  let payload;
  try {
    payload = jwt.verify(challenge, JWT_SECRET);
  } catch {
    return res.status(401).json({ error: 'sign-in expired, enter your password again' });
  }
  if (payload.purpose !== '2fa' || !payload.sub)
    return res.status(400).json({ error: 'invalid sign-in challenge' });
  const row = db.prepare('SELECT * FROM users WHERE id = ?').get(payload.sub);
  if (!row || !row.totp_enabled || !row.totp_secret)
    return res.status(401).json({ error: 'two-factor authentication is not enabled' });
  if (row.role === 'banned')
    return res.status(403).json({ error: 'account banned' });

  const now = Date.now();
  const attempt = twoFactorAttempts.get(challenge);
  if (attempt && attempt.expires > now && attempt.count >= TWO_FACTOR_MAX_ATTEMPTS) {
    return res.status(429).json({ error: 'too many attempts, enter your password again' });
  }
  const totpOk = verifyTotp(row.totp_secret, code);
  const recoveryOk = !totpOk && consumeRecoveryCode(row.id, code);
  if (!totpOk && !recoveryOk) {
    const expires = payload.exp ? payload.exp * 1000 : now + 5 * 60 * 1000;
    const count = attempt && attempt.expires > now ? attempt.count : 0;
    twoFactorAttempts.set(challenge, { count: count + 1, expires });
    return res.status(401).json({ error: 'invalid two-factor code' });
  }
  twoFactorAttempts.delete(challenge);
  res.json({
    token: signToken(row),
    user: publicUser(row),
    recoveryCodeUsed: recoveryOk,
  });
});

// ---- two-factor authentication management ---------------------------------

router.get('/2fa/status', authMiddleware, (req, res) => {
  const row = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.sub);
  if (!row) return res.status(401).json({ error: 'unknown user' });
  const remaining = db
    .prepare(
      'SELECT COUNT(*) AS n FROM totp_recovery_codes WHERE user_id = ? AND used_at IS NULL'
    )
    .get(row.id).n;
  res.json({
    enabled: !!row.totp_enabled,
    remainingRecoveryCodes: remaining,
  });
});

router.post('/2fa/setup', authMiddleware, (req, res) => {
  const row = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.sub);
  if (!row) return res.status(401).json({ error: 'unknown user' });
  if (row.totp_enabled)
    return res.status(409).json({ error: 'two-factor authentication is already enabled' });
  const secret = generateSecret();
  db.prepare('UPDATE users SET totp_secret = ? WHERE id = ?').run(secret, row.id);
  res.json({
    secret,
    otpauthUrl: otpauthUrl({ secret, account: row.username }),
  });
});

router.post('/2fa/enable', authMiddleware, (req, res) => {
  const code = String(req.body?.code || '').trim();
  const row = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.sub);
  if (!row) return res.status(401).json({ error: 'unknown user' });
  if (row.totp_enabled)
    return res.status(409).json({ error: 'two-factor authentication is already enabled' });
  if (!row.totp_secret)
    return res.status(400).json({ error: 'start two-factor setup first' });
  if (!verifyTotp(row.totp_secret, code))
    return res.status(401).json({ error: 'invalid two-factor code' });

  const codes = generateRecoveryCodes(10);
  const hashes = codes.map((code) => bcrypt.hashSync(normalizeRecoveryCode(code), 10));
  const enable = db.transaction(() => {
    const at = Date.now();
    db.prepare('DELETE FROM totp_recovery_codes WHERE user_id = ?').run(row.id);
    const insert = db.prepare(
      'INSERT INTO totp_recovery_codes (user_id, code_hash, created_at) VALUES (?, ?, ?)'
    );
    for (const hash of hashes) insert.run(row.id, hash, at);
    db.prepare('UPDATE users SET totp_enabled = 1 WHERE id = ?').run(row.id);
  });
  enable();
  res.json({ recoveryCodes: codes });
});

router.post('/2fa/disable', authMiddleware, (req, res) => {
  const password = String(req.body?.password || '');
  const code = String(req.body?.code || '').trim();
  const row = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.sub);
  if (!row) return res.status(401).json({ error: 'unknown user' });
  if (!row.totp_enabled)
    return res.status(400).json({ error: 'two-factor authentication is not enabled' });
  if (!bcrypt.compareSync(password, row.password_hash))
    return res.status(401).json({ error: 'invalid password' });
  const totpOk = verifyTotp(row.totp_secret, code);
  const recoveryOk = !totpOk && consumeRecoveryCode(row.id, code);
  if (!totpOk && !recoveryOk)
    return res.status(401).json({ error: 'invalid two-factor code' });
  const disable = db.transaction(() => {
    db.prepare('UPDATE users SET totp_enabled = 0, totp_secret = NULL WHERE id = ?').run(row.id);
    db.prepare('DELETE FROM totp_recovery_codes WHERE user_id = ?').run(row.id);
  });
  disable();
  res.json({ ok: true });
});

router.get('/me', authMiddleware, (req, res) => {
  const row = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.sub);
  if (!row) return res.status(401).json({ error: 'unknown user' });
  res.json({ user: publicUser(row) });
});

router.patch('/me', authMiddleware, (req, res) => {
  const bio = String(req.body?.bio ?? '').trim().slice(0, 300);
  db.prepare('UPDATE users SET bio = ? WHERE id = ?').run(bio, req.user.sub);
  const row = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.sub);
  res.json({ user: publicUser(row) });
});

export default router;
