import { Router } from 'express';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import db, { dataDir, publicUser } from './db.js';

const secretFile = path.join(dataDir, 'jwt.secret');
let JWT_SECRET;
if (fs.existsSync(secretFile)) {
  JWT_SECRET = fs.readFileSync(secretFile, 'utf8').trim();
} else {
  JWT_SECRET = crypto.randomBytes(48).toString('hex');
  fs.writeFileSync(secretFile, JWT_SECRET, { mode: 0o600 });
}

const TOKEN_TTL = '120d';

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

export function authMiddleware(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: 'unauthorized' });
  try {
    req.user = verifyToken(token);
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
  if (!row || !bcrypt.compareSync(password, row.password_hash))
    return res.status(401).json({ error: 'invalid username or password' });
  if (row.role === 'banned')
    return res.status(403).json({ error: 'account banned' });
  res.json({ token: signToken(row), user: publicUser(row) });
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
