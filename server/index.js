import express from 'express';
import cors from 'cors';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import authRouter, { authMiddleware } from './auth.js';
import chatRouter from './chat.js';
import { attachRealtime, onlineUserIds } from './realtime.js';
import { publicUser } from './db.js';
import db from './db.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 3000);

const app = express();
app.use(cors());
app.use(express.json({ limit: '2mb' }));

// Self-hosted Windows auto-update feed: latest.json + the NSIS installer.
// The desktop app polls GET /update/latest.json and downloads the new exe.
app.use(
  '/update',
  express.static(path.join(__dirname, 'update'), {
    maxAge: 0,
    setHeaders: (res) => res.setHeader('Cache-Control', 'no-store'),
  })
);

app.get('/health', (req, res) => {
  res.json({ ok: true, name: 'commsuite', online: onlineUserIds().length, time: Date.now() });
});

app.use('/api', authRouter);
app.use('/api', authMiddleware, chatRouter);

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: err.message || 'internal error' });
});

const server = http.createServer(app);
attachRealtime(server);

server.listen(PORT, '0.0.0.0', () => {
  const users = db.prepare('SELECT COUNT(*) AS n FROM users').get().n;
  console.log(`Commsuite server on http://0.0.0.0:${PORT}  (users: ${users})`);
  console.log(`WebSocket endpoint: ws://0.0.0.0:${PORT}/ws?token=<jwt>`);
});
