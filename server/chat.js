import { Router } from 'express';
import crypto from 'node:crypto';
import multer from 'multer';
import path from 'node:path';
import fs from 'node:fs';
import db, {
  uploadsDir,
  ensureConversation,
  conversationParticipants,
  groupMemberRow,
  isBlockedAny,
  markConversationRead,
  publicConversation,
  publicUser,
  publicMessage,
  queueBotUpdates,
  attachmentRowToPublic,
  attachmentIdsForConversation,
  deleteAttachmentsIfUnreferenced,
} from './db.js';
import { notifyUser } from './realtime.js';
import { fileReportIssue, reportingConfigured } from './github.js';

const router = Router();

const upload = multer({
  storage: multer.diskStorage({
    destination: uploadsDir,
    filename: (req, file, cb) => cb(null, crypto.randomUUID() + path.extname(file.originalname)),
  }),
  limits: { fileSize: 100 * 1024 * 1024 },
});

function loadUser(id) {
  return db.prepare('SELECT * FROM users WHERE id = ?').get(id);
}

function assertParticipant(conversation, userId) {
  if (!conversationParticipants(conversation).includes(userId)) return false;
  return true;
}

function groupRole(conversationId, userId) {
  return groupMemberRow(conversationId, userId)?.role ?? null;
}

/// Pushes [payload] to every member of a group except [exceptUserId].
function broadcastGroup(conversation, payload, exceptUserId) {
  for (const uid of conversationParticipants(conversation)) {
    if (uid === exceptUserId) continue;
    notifyUser(uid, payload);
  }
}

function getConversationOr404(id) {
  return db.prepare('SELECT * FROM conversations WHERE id = ?').get(String(id || ''));
}

/// Loads a message plus its conversation, verifying the caller participates.
/// On failure responds with 404 and returns null.
function getMessageFor(req, res) {
  const me = req.user.sub;
  const msg = db.prepare('SELECT * FROM messages WHERE id = ?').get(String(req.params.id || ''));
  if (!msg) {
    res.status(404).json({ error: 'message not found' });
    return null;
  }
  const conversation = db.prepare('SELECT * FROM conversations WHERE id = ?').get(msg.conversation_id);
  if (!conversation || !assertParticipant(conversation, me)) {
    res.status(404).json({ error: 'conversation not found' });
    return null;
  }
  return { me, msg, conversation };
}

// --- Chat bots ------------------------------------------------------------
// A bot is a real user (role = 'bot') with an entry in `bots`. The owner can
// add keyword replies and attach one mini-app; the server answers messages in
// any conversation the bot participates in.

const MINI_APPS = new Set(['none', 'json', 'base64', 'uuid']);
const BOT_MODES = new Set(['builtin', 'api']);

function botRowFor(id) {
  return db.prepare('SELECT * FROM bots WHERE user_id = ?').get(String(id || ''));
}

function botRepliesFor(botId) {
  return db
    .prepare('SELECT * FROM bot_replies WHERE bot_id = ? ORDER BY created_at ASC')
    .all(botId)
    .map((r) => ({ id: r.id, trigger: r.trigger, reply: r.reply }));
}

function botToPublic(row) {
  const user = loadUser(row.user_id);
  return {
    user: publicUser(user),
    description: row.description,
    miniApp: row.mini_app,
    mode: row.mode,
    enabled: !!row.enabled,
    token: row.token,
    replies: botRepliesFor(row.user_id),
    createdAt: row.created_at,
  };
}

function ownedBot(req, res, id) {
  const row = botRowFor(id);
  if (!row || row.owner_id !== req.user.sub) {
    res.status(404).json({ error: 'bot not found' });
    return null;
  }
  return row;
}

function botUsername(name) {
  const base =
    name
      .toLowerCase()
      .replace(/[^a-z0-9_.-]+/g, '_')
      .replace(/^[_.-]+|[_.-]+$/g, '')
      .slice(0, 24) || 'bot';
  const first = `${base.length < 3 ? 'bot' : base}_bot`.slice(0, 32);
  if (!db.prepare('SELECT 1 FROM users WHERE username = ?').get(first)) return first;
  let username;
  do {
    username = `${base.slice(0, 24)}_${crypto.randomBytes(3).toString('hex')}`.slice(0, 32);
  } while (db.prepare('SELECT 1 FROM users WHERE username = ?').get(username));
  return username;
}

function newBotToken() {
  return `cmsb_${crypto.randomBytes(24).toString('hex')}`;
}

function miniAppHint(miniApp) {
  switch (miniApp) {
    case 'json':
      return 'Send JSON and I will format it, e.g. {"hello":"world"}';
    case 'base64':
      return 'Use /b64 <text> to encode or /unb64 <text> to decode.';
    case 'uuid':
      return 'Send /uuid or /uuid 5 to generate random UUIDs.';
    default:
      return null;
  }
}

function miniAppReply(miniApp, text) {
  const trimmed = text.trim();

  if (miniApp === 'json') {
    const hasCommand = /^\/?json\s+/i.test(trimmed);
    const source = hasCommand
      ? trimmed.replace(/^\/?json\s+/i, '').trim()
      : trimmed;
    if (!hasCommand && !/^[[{]/.test(source)) return null;
    try {
      return JSON.stringify(JSON.parse(source), null, 2).slice(0, 8000);
    } catch (e) {
      return `Invalid JSON: ${e.message}`;
    }
  }

  if (miniApp === 'base64') {
    let match = trimmed.match(/^\/(?:b64|base64)\s+([\s\S]+)$/i);
    if (match) {
      return Buffer.from(match[1], 'utf8').toString('base64').slice(0, 8000);
    }
    match = trimmed.match(/^\/(?:unb64|base64decode)\s+([\s\S]+)$/i);
    if (match) {
      try {
        return Buffer.from(match[1].trim(), 'base64').toString('utf8').slice(0, 8000);
      } catch (e) {
        return `Invalid Base64: ${e.message}`;
      }
    }
    return null;
  }

  if (miniApp === 'uuid') {
    const match = trimmed.match(/^\/?uuid(?:\s+(\d+))?$/i);
    if (!match) return null;
    const count = Math.min(Math.max(parseInt(match[1] || '5', 10) || 5, 1), 10);
    return Array.from({ length: count }, () => crypto.randomUUID()).join('\n');
  }

  return null;
}

function botHelpText(bot) {
  const parts = [`Hi! I'm @${bot.username}, an automated bot.`];
  const hint = miniAppHint(bot.mini_app);
  if (hint) parts.push(hint);
  const rules = botRepliesFor(bot.user_id);
  if (rules.length) {
    parts.push(`Try: ${rules.map((r) => `“${r.trigger}”`).join(', ')}`);
  }
  if (parts.length === 1) parts.push('My owner has not added any replies yet.');
  return parts.join('\n\n');
}

function computeBotReply(bot, conversation, body) {
  const text = String(body || '').trim();
  if (!text) return null;
  const lower = text.toLowerCase();

  for (const rule of botRepliesFor(bot.user_id)) {
    const trigger = rule.trigger.trim().toLowerCase();
    if (trigger && lower.includes(trigger)) return rule.reply.slice(0, 8000);
  }

  const mini = miniAppReply(bot.mini_app, text);
  if (mini) return mini;

  if (['/help', 'help', '/start', 'start'].includes(lower)) {
    return botHelpText(bot);
  }

  // A brand-new bot with no rules/mini-app should still explain itself in DMs.
  if (
    conversation.kind !== 'group' &&
    botRepliesFor(bot.user_id).length === 0 &&
    (!bot.mini_app || bot.mini_app === 'none')
  ) {
    return botHelpText(bot);
  }
  return null;
}

function sendBotMessage(conversation, bot, text) {
  const row = {
    id: crypto.randomUUID(),
    conversation_id: conversation.id,
    sender_id: bot.user_id,
    kind: 'text',
    body: text,
    attachment_id: null,
    created_at: Date.now(),
    read_at: null,
    reply_to: null,
  };
  db.prepare(
    `INSERT INTO messages (id, conversation_id, sender_id, kind, body, attachment_id, created_at, read_at, reply_to)
     VALUES (@id, @conversation_id, @sender_id, @kind, @body, @attachment_id, @created_at, @read_at, @reply_to)`
  ).run(row);
  const message = publicMessage(row);
  for (const uid of conversationParticipants(conversation)) {
    if (uid !== bot.user_id) {
      notifyUser(uid, {
        type: 'message',
        conversationId: conversation.id,
        message,
      });
    }
  }
}

/// Answers [body] with every enabled bot that participates in [conversation].
function runBotReplies(conversation, senderId, body) {
  // Never let bots talk to each other: two bots in one group would otherwise
  // ping-pong forever.
  const sender = db.prepare('SELECT role FROM users WHERE id = ?').get(senderId);
  if (!sender || sender.role === 'bot') return;

  const participants = conversationParticipants(conversation);
  if (participants.length === 0) return;
  const placeholders = participants.map(() => '?').join(',');
  const bots = db
    .prepare(
      `SELECT b.*, u.username
       FROM bots b JOIN users u ON u.id = b.user_id
       WHERE b.enabled = 1 AND b.mode = 'builtin' AND b.user_id IN (${placeholders})`
    )
    .all(...participants);
  for (const bot of bots) {
    if (bot.user_id === senderId) continue;
    const reply = computeBotReply(bot, conversation, body);
    if (reply) sendBotMessage(conversation, bot, reply);
  }
}

router.get('/bots', (req, res) => {
  const rows = db
    .prepare('SELECT * FROM bots WHERE owner_id = ? ORDER BY created_at DESC')
    .all(req.user.sub);
  res.json({ bots: rows.map(botToPublic) });
});

router.post('/bots', (req, res) => {
  if (req.user.bot)
    return res.status(403).json({ error: 'bots cannot create bots' });
  const name = String(req.body?.name || '').trim();
  if (name.length < 1 || name.length > 48)
    return res.status(400).json({ error: 'bot name must be 1-48 characters' });
  const description = String(req.body?.description || '').trim().slice(0, 300);
  const requested = String(req.body?.miniApp || 'none');
  const miniApp = MINI_APPS.has(requested) ? requested : 'none';
  const requestedMode = String(req.body?.mode || 'api');
  const mode = BOT_MODES.has(requestedMode) ? requestedMode : 'api';
  const now = Date.now();
  const id = crypto.randomUUID();
  const username = botUsername(name);
  db.prepare(
    `INSERT INTO users (id, username, display_name, bio, role, is_verified, password_hash, created_at)
     VALUES (?, ?, ?, ?, 'bot', 0, '!bot', ?)`
  ).run(id, username, name, description, now);
  db.prepare(
    `INSERT INTO bots (user_id, owner_id, token, description, mini_app, mode, enabled, created_at)
     VALUES (?, ?, ?, ?, ?, ?, 1, ?)`
  ).run(id, req.user.sub, newBotToken(), description, miniApp, mode, now);
  res.status(201).json({ bot: botToPublic(botRowFor(id)) });
});

router.patch('/bots/:id', (req, res) => {
  const bot = ownedBot(req, res, req.params.id);
  if (!bot) return;

  if (req.body?.name !== undefined) {
    const name = String(req.body.name).trim();
    if (name.length < 1 || name.length > 48)
      return res.status(400).json({ error: 'bot name must be 1-48 characters' });
    db.prepare('UPDATE users SET display_name = ? WHERE id = ?').run(name, bot.user_id);
  }

  const sets = [];
  const params = [];
  if (req.body?.description !== undefined) {
    const description = String(req.body.description).trim().slice(0, 300);
    sets.push('description = ?');
    params.push(description);
    db.prepare('UPDATE users SET bio = ? WHERE id = ?').run(description, bot.user_id);
  }
  if (req.body?.miniApp !== undefined) {
    const requested = String(req.body.miniApp);
    if (!MINI_APPS.has(requested))
      return res.status(400).json({ error: 'unknown mini-app' });
    sets.push('mini_app = ?');
    params.push(requested);
  }
  if (req.body?.mode !== undefined) {
    const requested = String(req.body.mode);
    if (!BOT_MODES.has(requested))
      return res.status(400).json({ error: 'unknown bot mode' });
    sets.push('mode = ?');
    params.push(requested);
  }
  if (req.body?.enabled !== undefined) {
    sets.push('enabled = ?');
    params.push(req.body.enabled === false ? 0 : 1);
  }
  if (sets.length > 0) {
    db.prepare(`UPDATE bots SET ${sets.join(', ')} WHERE user_id = ?`).run(
      ...params,
      bot.user_id
    );
  }
  res.json({ bot: botToPublic(botRowFor(bot.user_id)) });
});

router.post('/bots/:id/token', (req, res) => {
  const bot = ownedBot(req, res, req.params.id);
  if (!bot) return;
  db.prepare('UPDATE bots SET token = ? WHERE user_id = ?').run(
    newBotToken(),
    bot.user_id
  );
  res.json({ bot: botToPublic(botRowFor(bot.user_id)) });
});

router.delete('/bots/:id', (req, res) => {
  const bot = ownedBot(req, res, req.params.id);
  if (!bot) return;
  const botId = bot.user_id;

  const conversations = db
    .prepare(
      `SELECT DISTINCT c.* FROM conversations c
       WHERE (c.kind != 'group' AND (c.user_low = ? OR c.user_high = ?))
          OR (c.kind = 'group' AND EXISTS (
                SELECT 1 FROM group_members gm
                WHERE gm.conversation_id = c.id AND gm.user_id = ?))`
    )
    .all(botId, botId, botId);

  for (const conversation of conversations) {
    if (conversation.kind === 'group') {
      db.prepare('DELETE FROM messages WHERE conversation_id = ? AND sender_id = ?').run(
        conversation.id,
        botId
      );
      db.prepare('DELETE FROM group_members WHERE conversation_id = ? AND user_id = ?').run(
        conversation.id,
        botId
      );
    } else {
      db.prepare('DELETE FROM messages WHERE conversation_id = ?').run(conversation.id);
      db.prepare('DELETE FROM group_members WHERE conversation_id = ?').run(conversation.id);
      db.prepare('DELETE FROM conversations WHERE id = ?').run(conversation.id);
    }
  }

  db.prepare('DELETE FROM bots WHERE user_id = ?').run(botId);
  db.prepare('DELETE FROM users WHERE id = ?').run(botId);
  res.json({ ok: true });
});

router.post('/bots/:id/replies', (req, res) => {
  const bot = ownedBot(req, res, req.params.id);
  if (!bot) return;
  const trigger = String(req.body?.trigger || '').trim().slice(0, 80);
  const reply = String(req.body?.reply || '').trim().slice(0, 8000);
  if (!trigger || !reply)
    return res.status(400).json({ error: 'trigger and reply are required' });
  db.prepare(
    `INSERT INTO bot_replies (id, bot_id, trigger, reply, created_at)
     VALUES (?, ?, ?, ?, ?)`
  ).run(crypto.randomUUID(), bot.user_id, trigger, reply, Date.now());
  res.status(201).json({ bot: botToPublic(botRowFor(bot.user_id)) });
});

router.delete('/bots/:id/replies/:replyId', (req, res) => {
  const bot = ownedBot(req, res, req.params.id);
  if (!bot) return;
  db.prepare('DELETE FROM bot_replies WHERE id = ? AND bot_id = ?').run(
    req.params.replyId,
    bot.user_id
  );
  res.json({ bot: botToPublic(botRowFor(bot.user_id)) });
});


router.get('/users', (req, res) => {
  const query = String(req.query.query || '').trim();
  const me = req.user.sub;
  let rows;
  if (query) {
    rows = db
      .prepare(
        `SELECT * FROM users
         WHERE id != ? AND (username LIKE ? OR display_name LIKE ?)
         ORDER BY display_name COLLATE NOCASE LIMIT 100`
      )
      .all(me, `%${query}%`, `%${query}%`);
  } else {
    rows = db
      .prepare('SELECT * FROM users WHERE id != ? ORDER BY display_name COLLATE NOCASE LIMIT 100')
      .all(me);
  }
  res.json({ users: rows.map(publicUser) });
});

router.get('/users/:id', (req, res) => {
  const user = loadUser(req.params.id);
  if (!user) return res.status(404).json({ error: 'user not found' });
  res.json({ user: publicUser(user) });
});

router.get('/blocks', (req, res) => {
  const rows = db
    .prepare('SELECT blocked FROM blocks WHERE blocked_by = ? ORDER BY created_at DESC')
    .all(req.user.sub);
  res.json({ blockedIds: rows.map((r) => r.blocked) });
});

router.post('/block', (req, res) => {
  const targetId = String(req.body?.targetId || '');
  const peer = loadUser(targetId);
  if (!peer) return res.status(404).json({ error: 'user not found' });
  if (targetId === req.user.sub) return res.status(400).json({ error: 'cannot block yourself' });

  if (req.body?.blocked === true) {
    db.prepare(
      'INSERT OR IGNORE INTO blocks (blocked_by, blocked, created_at) VALUES (?, ?, ?)'
    ).run(req.user.sub, targetId, Date.now());
  } else if (req.body?.blocked === false) {
    db.prepare('DELETE FROM blocks WHERE blocked_by = ? AND blocked = ?').run(
      req.user.sub,
      targetId
    );
  } else {
    return res.status(400).json({ error: 'blocked must be true or false' });
  }
  res.json({ ok: true });
});

router.post('/report', (req, res) => {
  if (req.user.bot) return res.status(403).json({ error: 'bots cannot report users' });
  const targetId = String(req.body?.targetId || '');
  const peer = loadUser(targetId);
  if (!peer) return res.status(404).json({ error: 'user not found' });
  if (targetId === req.user.sub) return res.status(400).json({ error: 'cannot report yourself' });

  const reporter = loadUser(req.user.sub);
  const reason = String(req.body?.reason || '').slice(0, 600);
  const createdAt = Date.now();
  const result = db
    .prepare(
      'INSERT OR IGNORE INTO reports (reporter_id, target_id, reason, created_at) VALUES (?, ?, ?, ?)'
    )
    .run(req.user.sub, targetId, reason, createdAt);
  res.json({ ok: true });

  // Best-effort mirror of a fresh report into the project's GitHub issue
  // tracker. A duplicate report (ignored above) does not open a second issue,
  // and a GitHub failure never affects the stored report or the response.
  if (result.changes > 0 && reportingConfigured()) {
    fileReportIssue({ reporter, target: peer, reason, createdAt })
      .then((issue) => {
        if (issue.number) console.log(`Report @${reporter.username} -> @${peer.username}: issue #${issue.number}`);
      })
      .catch((err) => console.error('Report -> GitHub issue failed:', err.message));
  }
});

const requireMod = (req, res, next) => {
  const row = db.prepare('SELECT role FROM users WHERE id = ?').get(req.user.sub);
  if (row && row.role === 'mod') return next();
  return res.status(403).json({ error: 'forbidden' });
};

router.get('/reports', requireMod, (req, res) => {
  const rows = db
    .prepare(
      `SELECT r.reporter_id, r.target_id, r.reason, r.created_at,
              ru.username AS reporter_username, ru.display_name AS reporter_display,
              tu.username AS target_username, tu.display_name AS target_display
       FROM reports r
       JOIN users ru ON ru.id = r.reporter_id
       JOIN users tu ON tu.id = r.target_id
       ORDER BY r.created_at DESC`
    )
    .all();
  res.json({
    reports: rows.map((r) => ({
      reporterId: r.reporter_id,
      reporterUsername: r.reporter_username,
      reporterDisplay: r.reporter_display,
      targetId: r.target_id,
      targetUsername: r.target_username,
      targetDisplay: r.target_display,
      reason: r.reason,
      createdAt: r.created_at,
    })),
  });
});

router.delete('/reports/:reporterId/:targetId', requireMod, (req, res) => {
  const result = db
    .prepare('DELETE FROM reports WHERE reporter_id = ? AND target_id = ?')
    .run(req.params.reporterId, req.params.targetId);
  res.json({ ok: true, deleted: result.changes > 0 });
});

router.post('/ban', requireMod, (req, res) => {
  const targetId = String(req.body?.targetId || '');
  const peer = loadUser(targetId);
  if (!peer) return res.status(404).json({ error: 'user not found' });
  if (peer.role === 'mod') return res.status(400).json({ error: 'cannot ban a moderator' });
  if (peer.role === 'bot') return res.status(400).json({ error: 'cannot ban a bot' });
  const banned = req.body?.banned !== false;
  db.prepare('UPDATE users SET role = ? WHERE id = ?').run(banned ? 'banned' : 'user', targetId);
  if (banned) notifyUser(targetId, { type: 'banned' });
  res.json({ ok: true, role: banned ? 'banned' : 'user' });
});

router.post('/verified', requireMod, (req, res) => {
  const targetId = String(req.body?.targetId || '');
  const peer = loadUser(targetId);
  if (!peer) return res.status(404).json({ error: 'user not found' });
  const verified = req.body?.verified !== false;
  db.prepare('UPDATE users SET is_verified = ? WHERE id = ?').run(verified ? 1 : 0, targetId);
  res.json({ ok: true, isVerified: !!verified });
});

router.get('/banned', requireMod, (req, res) => {
  const rows = db
    .prepare("SELECT * FROM users WHERE role = 'banned' ORDER BY created_at DESC")
    .all();
  res.json({ users: rows.map(publicUser) });
});

const RPS_MOVES = ['rock', 'paper', 'scissors'];
const BEATS = { rock: 'scissors', scissors: 'paper', paper: 'rock' };

function insertGameMessage(conversationId, senderId, payload) {
  const row = {
    id: crypto.randomUUID(),
    conversation_id: conversationId,
    sender_id: senderId,
    kind: 'game',
    body: JSON.stringify(payload),
    attachment_id: null,
    created_at: Date.now(),
    read_at: null,
  };
  db.prepare(
    `INSERT INTO messages (id, conversation_id, sender_id, kind, body, attachment_id, created_at, read_at)
     VALUES (@id, @conversation_id, @sender_id, @kind, @body, @attachment_id, @created_at, @read_at)`
  ).run(row);
  return publicMessage(row);
}

function notifyGame(conversationId, gameId, event) {
  const conversation = db.prepare('SELECT * FROM conversations WHERE id = ?').get(conversationId);
  if (!conversation) return;
  for (const uid of conversationParticipants(conversation)) {
    notifyUser(uid, { type: 'game', conversationId, gameId, event });
  }
}

function findActiveGame(conversationId) {
  return db
    .prepare(
      `SELECT * FROM games WHERE conversation_id = ? AND status = 'active' ORDER BY created_at DESC LIMIT 1`
    )
    .get(conversationId);
}

function publicGame(game, me) {
  const mine = game.a_user === me;
  return {
    id: game.id,
    type: game.type,
    mine,
    myMoved: mine ? game.a_input != null : game.b_input != null,
    peerMoved: mine ? game.b_input != null : game.a_input != null,
    peerId: mine ? game.b_user : game.a_user,
    mySecret: game.type === 'guess' && mine ? Number(game.secret) : null,
    guesses: game.guess_count,
    status: game.status,
  };
}

router.get('/conversations/:id/games', (req, res) => {
  const me = req.user.sub;
  const conversation = db.prepare('SELECT * FROM conversations WHERE id = ?').get(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });
  if (conversation.kind === 'group')
    return res.status(400).json({ error: 'can only play games in a 1:1 chat' });

  const game = findActiveGame(conversation.id);
  res.json({ game: game ? publicGame(game, me) : null });
});

router.post('/conversations/:id/games', (req, res) => {
  const me = req.user.sub;
  const conversation = db.prepare('SELECT * FROM conversations WHERE id = ?').get(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });
  if (conversation.kind === 'group')
    return res.status(400).json({ error: 'can only play games in a 1:1 chat' });

  const peerId = conversationParticipants(conversation).find((uid) => uid !== me);
  if (!peerId) return res.status(400).json({ error: 'no peer in conversation' });
  if (isBlockedAny(me, peerId)) return res.status(403).json({ error: 'blocked' });

  const type = req.body?.type;
  if (type !== 'rps' && type !== 'guess')
    return res.status(400).json({ error: 'type must be rps or guess' });
  if (findActiveGame(conversation.id))
    return res.status(409).json({ error: 'a game is already active in this conversation' });

  let secret = null;
  if (type === 'guess') {
    secret = Number(req.body?.secret);
    if (!Number.isInteger(secret) || secret < 1 || secret > 100)
      return res.status(400).json({ error: 'secret must be an integer between 1 and 100' });
  }

  const game = {
    id: crypto.randomUUID(),
    conversation_id: conversation.id,
    type,
    a_user: me,
    b_user: peerId,
    a_input: null,
    b_input: null,
    secret: secret != null ? String(secret) : null,
    guess_count: 0,
    status: 'active',
    created_at: Date.now(),
  };
  db.prepare(
    `INSERT INTO games (id, conversation_id, type, a_user, b_user, a_input, b_input, secret, guess_count, status, created_at)
     VALUES (@id, @conversation_id, @type, @a_user, @b_user, @a_input, @b_input, @secret, @guess_count, @status, @created_at)`
  ).run(game);

  insertGameMessage(conversation.id, me, { type, phase: 'invite', id: game.id });
  notifyGame(conversation.id, game.id, 'started');
  res.status(201).json({ game: publicGame(game, me) });
});

router.post('/games/:id/moves', (req, res) => {
  const me = req.user.sub;
  const game = db.prepare('SELECT * FROM games WHERE id = ?').get(req.params.id);
  if (!game) return res.status(404).json({ error: 'game not found' });
  const conversation = db.prepare('SELECT * FROM conversations WHERE id = ?').get(game.conversation_id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });
  if (game.status !== 'active') return res.status(400).json({ error: 'game is not active' });

  const mine = game.a_user === me;

  if (game.type === 'rps') {
    const move = String(req.body?.move || '');
    if (!RPS_MOVES.includes(move))
      return res.status(400).json({ error: 'move must be rock, paper or scissors' });
    if (mine ? game.a_input != null : game.b_input != null)
      return res.status(400).json({ error: 'you already picked' });

    if (mine) db.prepare('UPDATE games SET a_input = ? WHERE id = ?').run(move, game.id);
    else db.prepare('UPDATE games SET b_input = ? WHERE id = ?').run(move, game.id);

    const updated = db.prepare('SELECT * FROM games WHERE id = ?').get(game.id);
    notifyGame(conversation.id, game.id, 'moved');

    if (updated.a_input && updated.b_input) {
      const winner =
        updated.a_input === updated.b_input
          ? 'draw'
          : BEATS[updated.a_input] === updated.b_input
            ? updated.a_user
            : updated.b_user;
      insertGameMessage(conversation.id, updated.a_user, {
        type: 'rps',
        phase: 'result',
        id: game.id,
        a: updated.a_user,
        b: updated.b_user,
        aMove: updated.a_input,
        bMove: updated.b_input,
        winner,
      });
      db.prepare("UPDATE games SET status = 'done' WHERE id = ?").run(game.id);
      notifyGame(conversation.id, game.id, 'finished');
      return res.json({ ok: true, event: 'finished' });
    }
    return res.json({ ok: true, event: 'waiting' });
  }

  // guess
  if (game.type === 'guess') {
    if (game.a_input === 'forfeit') return res.status(400).json({ error: 'game has ended' });

    if (mine) {
      if (req.body?.move !== 'forfeit')
        return res.status(400).json({ error: 'waiting for a guess from your opponent' });
      db.prepare("UPDATE games SET a_input = 'forfeit', status = 'done' WHERE id = ?").run(game.id);
      insertGameMessage(conversation.id, me, {
        type: 'guess',
        phase: 'result',
        id: game.id,
        secret: Number(game.secret),
        guesses: game.guess_count,
        winner: null,
        forfeited: true,
      });
      notifyGame(conversation.id, game.id, 'finished');
      return res.json({ ok: true, event: 'finished' });
    }

    const guess = Number(req.body?.move);
    if (!Number.isInteger(guess) || guess < 1 || guess > 100)
      return res.status(400).json({ error: 'guess must be an integer between 1 and 100' });

    db.prepare(
      'UPDATE games SET b_input = ?, guess_count = guess_count + 1 WHERE id = ?'
    ).run(String(guess), game.id);
    const updated = db.prepare('SELECT * FROM games WHERE id = ?').get(game.id);

    const secret = Number(game.secret);
    if (guess === secret) {
      db.prepare("UPDATE games SET status = 'done' WHERE id = ?").run(game.id);
      insertGameMessage(conversation.id, me, {
        type: 'guess',
        phase: 'result',
        id: game.id,
        secret,
        guesses: updated.guess_count,
        winner: game.b_user,
      });
      notifyGame(conversation.id, game.id, 'finished');
      return res.json({ ok: true, event: 'finished' });
    }

    insertGameMessage(conversation.id, me, {
      type: 'guess',
      phase: 'hint',
      id: game.id,
      guess,
      hint: guess < secret ? 'higher' : 'lower',
    });
    notifyGame(conversation.id, game.id, 'hint');
    return res.json({ ok: true, event: 'hint', hint: guess < secret ? 'higher' : 'lower' });
  }

  return res.status(400).json({ error: 'unsupported game type' });
});

router.post('/conversations/:id/flip', (req, res) => {
  const me = req.user.sub;
  const conversation = db.prepare('SELECT * FROM conversations WHERE id = ?').get(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });
  if (conversation.kind === 'group')
    return res.status(400).json({ error: 'can only play games in a 1:1 chat' });

  const peerId = conversationParticipants(conversation).find((uid) => uid !== me);
  if (!peerId) return res.status(400).json({ error: 'no peer in conversation' });
  if (isBlockedAny(me, peerId)) return res.status(403).json({ error: 'blocked' });

  const call = String(req.body?.call || '');
  if (call !== 'heads' && call !== 'tails')
    return res.status(400).json({ error: 'call must be heads or tails' });

  const flip = Math.random() < 0.5 ? 'heads' : 'tails';
  const gameId = crypto.randomUUID();
  const message = insertGameMessage(conversation.id, me, {
    type: 'flip',
    id: gameId,
    call,
    flip,
    win: call === flip,
  });
  notifyGame(conversation.id, gameId, 'flip');
  res.status(201).json({ message, flip, win: call === flip });
});

router.get('/conversations', (req, res) => {
  const me = req.user.sub;
  // DMs match on the user pair; groups match through group_members. Group rows
  // store user_low = creator, user_high = group-id (unique sentinel that keeps
  // the UNIQUE(user_low,user_high) constraint happy without a table rebuild).
  const rows = db
    .prepare(
      `SELECT c.*
       FROM conversations c
       WHERE (c.kind = 'group' AND EXISTS (
                SELECT 1 FROM group_members gm
                WHERE gm.conversation_id = c.id AND gm.user_id = @me
              ))
          OR (c.kind != 'group' AND (c.user_low = @me OR c.user_high = @me))
       ORDER BY c.created_at DESC`
    )
    .all({ me });

  res.json({ conversations: rows.map((c) => publicConversation(c, me)) });
});

router.post('/conversations', (req, res) => {
  const peerId = String(req.body?.peerId || '');
  const peer = loadUser(peerId);
  if (!peer) return res.status(404).json({ error: 'user not found' });
  if (peerId === req.user.sub) return res.status(400).json({ error: 'cannot chat with yourself' });
  const conversation = ensureConversation(req.user.sub, peerId);
  res.json({
    conversation: {
      id: conversation.id,
      kind: conversation.kind,
      peer: publicUser(peer),
      lastMessage: null,
      unread: 0,
      createdAt: conversation.created_at,
    },
  });
});

const MAX_GROUP_MEMBERS = 99;

router.post('/conversations/group', (req, res) => {
  const me = req.user.sub;
  const name = String(req.body?.name || '').trim();
  if (name.length < 1 || name.length > 64)
    return res.status(400).json({ error: 'group name must be 1-64 characters' });
  const description = String(req.body?.description || '').trim().slice(0, 300);
  const memberIds = Array.isArray(req.body?.memberIds) ? req.body.memberIds.map(String) : [];
  const ids = [...new Set(memberIds.filter((id) => id && id !== me))];
  if (ids.length === 0) return res.status(400).json({ error: 'add at least one member' });
  if (ids.length > MAX_GROUP_MEMBERS)
    return res.status(400).json({ error: `a group can have at most ${MAX_GROUP_MEMBERS} members` });
  for (const id of ids) {
    const u = loadUser(id);
    if (!u) return res.status(404).json({ error: 'user not found' });
    if (u.role === 'banned') return res.status(403).json({ error: 'cannot add a banned user' });
  }

  const id = crypto.randomUUID();
  const now = Date.now();
  db.prepare(
    `INSERT INTO conversations (id, user_low, user_high, kind, name, description, created_at)
     VALUES (@id, @user_low, @user_high, 'group', @name, @description, @created_at)`
  ).run({
    id,
    user_low: me,
    user_high: id, // unique sentinel so UNIQUE(user_low, user_high) stays satisfied
    name,
    description,
    created_at: now,
  });
  const insertMember = db.prepare(
    `INSERT INTO group_members (conversation_id, user_id, role, muted, last_read_at, created_at)
     VALUES (?, ?, ?, 0, ?, ?)`
  );
  insertMember.run(id, me, 'owner', now, now);
  for (const uid of ids) insertMember.run(id, uid, 'member', now, now);

  const conversation = getConversationOr404(id);
  broadcastGroup(
    conversation,
    { type: 'group-updated', conversationId: conversation.id, name },
    null
  );
  res.status(201).json({ conversation: publicConversation(conversation, me) });
});

/// Opens (or reuses) a support conversation between the caller and every
/// moderator. The request becomes the first message so the ticket is visible
/// in the normal chat UI; moderators are invited as regular group members.
router.post('/support', (req, res) => {
  if (req.user.bot) return res.status(403).json({ error: 'bots cannot open support tickets' });
  const me = req.user.sub;
  const meRow = loadUser(me);
  if (!meRow) return res.status(404).json({ error: 'user not found' });

  const subject = String(req.body?.subject || '').trim().slice(0, 120);
  const text = String(req.body?.message || '').trim().slice(0, 8000);
  if (!text) return res.status(400).json({ error: 'describe the issue first' });

  const now = Date.now();
  const name = `Support · @${meRow.username}`.slice(0, 64);
  const mods = db
    .prepare("SELECT id FROM users WHERE role = 'mod' AND id != ?")
    .all(me);

  let conversation = db
    .prepare(
      `SELECT * FROM conversations
       WHERE kind = 'group' AND user_low = ? AND name = ?
       ORDER BY created_at DESC LIMIT 1`
    )
    .get(me, name);

  const insertMember = db.prepare(
    `INSERT OR IGNORE INTO group_members (conversation_id, user_id, role, muted, last_read_at, created_at)
     VALUES (?, ?, ?, 0, ?, ?)`
  );

  if (!conversation) {
    const id = crypto.randomUUID();
    db.prepare(
      `INSERT INTO conversations (id, user_low, user_high, kind, name, description, created_at)
       VALUES (@id, @user_low, @user_high, 'group', @name, @description, @created_at)`
    ).run({
      id,
      user_low: me,
      user_high: id,
      name,
      description: 'Commsuite technical support',
      created_at: now,
    });
    insertMember.run(id, me, 'owner', now, now);
    conversation = getConversationOr404(id);
  }

  for (const mod of mods) insertMember.run(conversation.id, mod.id, 'member', now, now);

  const body = subject ? `Subject: ${subject}\n\n${text}` : text;
  const row = {
    id: crypto.randomUUID(),
    conversation_id: conversation.id,
    sender_id: me,
    kind: 'text',
    body,
    attachment_id: null,
    created_at: now,
    read_at: null,
    reply_to: null,
  };
  db.prepare(
    `INSERT INTO messages (id, conversation_id, sender_id, kind, body, attachment_id, created_at, read_at, reply_to)
     VALUES (@id, @conversation_id, @sender_id, @kind, @body, @attachment_id, @created_at, @read_at, @reply_to)`
  ).run(row);
  const message = publicMessage(row);

  // Moderators who were just invited need the group in their list as well as
  // the ticket message itself.
  broadcastGroup(
    conversation,
    { type: 'group-updated', conversationId: conversation.id, name },
    me
  );
  for (const uid of conversationParticipants(conversation)) {
    if (uid !== me) {
      notifyUser(uid, {
        type: 'message',
        conversationId: conversation.id,
        message,
      });
    }
  }

  res.status(201).json({
    conversation: publicConversation(conversation, me),
    invited: mods.length,
    message,
  });
});

router.get('/conversations/:id', (req, res) => {
  const me = req.user.sub;
  const conversation = getConversationOr404(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });
  res.json({ conversation: publicConversation(conversation, me) });
});

router.patch('/conversations/:id', (req, res) => {
  const me = req.user.sub;
  const conversation = getConversationOr404(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });
  if (conversation.kind !== 'group') return res.status(400).json({ error: 'not a group' });
  const actor = groupRole(conversation.id, me);
  if (actor !== 'owner' && actor !== 'admin')
    return res.status(403).json({ error: 'only the owner or admins can edit the group' });

  const sets = [];
  const params = [];
  if (req.body?.name !== undefined) {
    const name = String(req.body.name).trim();
    if (name.length < 1 || name.length > 64)
      return res.status(400).json({ error: 'group name must be 1-64 characters' });
    sets.push('name = ?');
    params.push(name);
  }
  if (req.body?.description !== undefined) {
    const description = String(req.body.description).trim().slice(0, 300);
    sets.push('description = ?');
    params.push(description);
  }
  if (sets.length === 0) return res.status(400).json({ error: 'nothing to update' });
  params.push(conversation.id);
  db.prepare(`UPDATE conversations SET ${sets.join(', ')} WHERE id = ?`).run(...params);

  const updated = getConversationOr404(conversation.id);
  broadcastGroup(
    updated,
    { type: 'group-updated', conversationId: updated.id, name: updated.name },
    null
  );
  res.json({ conversation: publicConversation(updated, me) });
});

router.post('/conversations/:id/members', (req, res) => {
  const me = req.user.sub;
  const conversation = getConversationOr404(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });
  if (conversation.kind !== 'group') return res.status(400).json({ error: 'not a group' });
  const actor = groupRole(conversation.id, me);
  if (actor !== 'owner' && actor !== 'admin')
    return res.status(403).json({ error: 'only the owner or admins can add members' });

  const targetId = String(req.body?.userId || '');
  const target = loadUser(targetId);
  if (!target) return res.status(404).json({ error: 'user not found' });
  if (target.role === 'banned') return res.status(403).json({ error: 'cannot add a banned user' });
  if (targetId === me) return res.status(400).json({ error: 'you are already a member' });
  if (groupMemberRow(conversation.id, targetId))
    return res.status(409).json({ error: 'already a member' });
  const count = db
    .prepare('SELECT COUNT(*) AS n FROM group_members WHERE conversation_id = ?')
    .get(conversation.id).n;
  if (count >= MAX_GROUP_MEMBERS)
    return res.status(400).json({ error: `a group can have at most ${MAX_GROUP_MEMBERS} members` });

  const now = Date.now();
  db.prepare(
    `INSERT INTO group_members (conversation_id, user_id, role, muted, last_read_at, created_at)
     VALUES (?, ?, 'member', 0, ?, ?)`
  ).run(conversation.id, targetId, now, now);

  const updated = getConversationOr404(conversation.id);
  notifyUser(targetId, {
    type: 'group-added',
    conversationId: updated.id,
    conversation: publicConversation(updated, targetId),
  });
  broadcastGroup(
    updated,
    { type: 'group-updated', conversationId: updated.id },
    targetId
  );
  res.json({ conversation: publicConversation(updated, me) });
});

router.delete('/conversations/:id/members/:userId', (req, res) => {
  const me = req.user.sub;
  const conversation = getConversationOr404(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });
  if (conversation.kind !== 'group') return res.status(400).json({ error: 'not a group' });

  const targetId = req.params.userId;
  const actor = groupMemberRow(conversation.id, me);
  const target = groupMemberRow(conversation.id, targetId);
  if (!target) return res.status(404).json({ error: 'not a member' });
  if (targetId !== me) {
    if (!actor || (actor.role !== 'owner' && actor.role !== 'admin'))
      return res.status(403).json({ error: 'only the owner or admins can remove members' });
    if (target.role === 'owner')
      return res.status(400).json({ error: 'the owner cannot be removed - leave or delete the group' });
    if (target.role === 'admin' && actor.role !== 'owner')
      return res.status(403).json({ error: 'only the owner can remove admins' });
  }

  // Owner leaving transfers ownership; the last member leaving deletes the group.
  let deleted = false;
  if (target.role === 'owner') {
    const next =
      db
        .prepare(
          `SELECT * FROM group_members
           WHERE conversation_id = ? AND role = 'admin' AND user_id != ?
           ORDER BY created_at ASC LIMIT 1`
        )
        .get(conversation.id, targetId) ||
      db
        .prepare(
          `SELECT * FROM group_members
           WHERE conversation_id = ? AND user_id != ?
           ORDER BY created_at ASC LIMIT 1`
        )
        .get(conversation.id, targetId);
    if (next) {
      db.prepare('UPDATE group_members SET role = ? WHERE conversation_id = ? AND user_id = ?').run(
        'owner',
        conversation.id,
        next.user_id
      );
    } else {
      const orphaned = attachmentIdsForConversation(conversation.id);
      db.prepare('DELETE FROM conversations WHERE id = ?').run(conversation.id);
      deleteAttachmentsIfUnreferenced(orphaned);
      deleted = true;
    }
  }
  if (!deleted) {
    db.prepare('DELETE FROM group_members WHERE conversation_id = ? AND user_id = ?').run(
      conversation.id,
      targetId
    );
  }

  // Always tell the removed user so their client can drop the chat.
  notifyUser(targetId, { type: 'group-removed', conversationId: conversation.id });

  if (deleted) {
    res.json({ ok: true, conversation: null });
    return;
  }
  const updated = getConversationOr404(conversation.id);
  broadcastGroup(
    updated,
    { type: 'group-updated', conversationId: updated.id },
    targetId
  );
  res.json({ ok: true, conversation: publicConversation(updated, me) });
});

router.patch('/conversations/:id/members/:userId', (req, res) => {
  const me = req.user.sub;
  const conversation = getConversationOr404(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });
  if (conversation.kind !== 'group') return res.status(400).json({ error: 'not a group' });
  if (groupRole(conversation.id, me) !== 'owner')
    return res.status(403).json({ error: 'only the owner can change member roles' });

  const targetId = req.params.userId;
  const target = groupMemberRow(conversation.id, targetId);
  if (!target) return res.status(404).json({ error: 'not a member' });
  if (target.role === 'owner') return res.status(400).json({ error: 'cannot change the owner role' });

  const role = req.body?.role;
  if (role !== 'admin' && role !== 'member')
    return res.status(400).json({ error: 'role must be admin or member' });
  db.prepare('UPDATE group_members SET role = ? WHERE conversation_id = ? AND user_id = ?').run(
    role,
    conversation.id,
    targetId
  );

  const updated = getConversationOr404(conversation.id);
  broadcastGroup(
    updated,
    { type: 'group-updated', conversationId: updated.id },
    null
  );
  res.json({ conversation: publicConversation(updated, me) });
});

router.post('/conversations/:id/mute', (req, res) => {
  const me = req.user.sub;
  const conversation = getConversationOr404(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });
  if (conversation.kind !== 'group') return res.status(400).json({ error: 'not a group' });

  const muted = req.body?.muted === true;
  db.prepare('UPDATE group_members SET muted = ? WHERE conversation_id = ? AND user_id = ?').run(
    muted ? 1 : 0,
    conversation.id,
    me
  );
  res.json({ conversation: publicConversation(getConversationOr404(conversation.id), me) });
});

router.delete('/conversations/:id', (req, res) => {
  const me = req.user.sub;
  const conversation = getConversationOr404(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });
  if (conversation.kind !== 'group') return res.status(400).json({ error: 'not a group' });
  if (groupRole(conversation.id, me) !== 'owner')
    return res.status(403).json({ error: 'only the owner can delete the group' });

  const orphaned = attachmentIdsForConversation(conversation.id);
  db.prepare('DELETE FROM conversations WHERE id = ?').run(conversation.id);
  deleteAttachmentsIfUnreferenced(orphaned);
  broadcastGroup(
    conversation,
    { type: 'group-deleted', conversationId: conversation.id },
    null
  );
  res.json({ ok: true });
});

router.get('/conversations/:id/messages', (req, res) => {
  const me = req.user.sub;
  const conversation = db.prepare('SELECT * FROM conversations WHERE id = ?').get(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });

  const limit = Math.min(Number(req.query.limit || 50), 200);
  const before = req.query.before ? Number(req.query.before) : Date.now();

  const rows = db
    .prepare(
      `SELECT * FROM messages
       WHERE conversation_id = ? AND created_at < ?
       ORDER BY created_at DESC LIMIT ?`
    )
    .all(conversation.id, before, limit);

  markConversationRead(conversation, me);

  res.json({ messages: rows.reverse().map((r) => publicMessage(r)) });
});

router.post('/conversations/:id/messages', (req, res) => {
  const me = req.user.sub;
  const conversation = db.prepare('SELECT * FROM conversations WHERE id = ?').get(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });

  const peerId = conversationParticipants(conversation).find((uid) => uid !== me);
  if (conversation.kind !== 'group' && peerId && isBlockedAny(me, peerId))
    return res.status(403).json({ error: 'blocked' });

  const kind = req.body?.kind === 'file' ? 'file' : 'text';
  const body = req.body?.body != null ? String(req.body.body).slice(0, 8000) : '';
  const attachmentId = req.body?.attachmentId ? String(req.body.attachmentId) : null;
  const replyTo = req.body?.replyTo ? String(req.body.replyTo) : null;

  if (replyTo) {
    const reply = db
      .prepare('SELECT id FROM messages WHERE id = ? AND conversation_id = ?')
      .get(replyTo, conversation.id);
    if (!reply) return res.status(400).json({ error: 'reply message not found' });
  }

  if (kind === 'file') {
    if (!attachmentId)
      return res.status(400).json({ error: 'attachmentId required for file messages' });
    const att = db.prepare('SELECT * FROM attachments WHERE id = ?').get(attachmentId);
    if (!att) return res.status(400).json({ error: 'attachment not found' });
  } else if (!body.trim()) {
    return res.status(400).json({ error: 'message body required' });
  }

  const row = {
    id: crypto.randomUUID(),
    conversation_id: conversation.id,
    sender_id: me,
    kind,
    body: kind === 'file' ? body || null : body,
    attachment_id: kind === 'file' ? attachmentId : null,
    created_at: Date.now(),
    read_at: null,
    reply_to: replyTo,
  };
  db.prepare(
    `INSERT INTO messages (id, conversation_id, sender_id, kind, body, attachment_id, created_at, read_at, reply_to)
     VALUES (@id, @conversation_id, @sender_id, @kind, @body, @attachment_id, @created_at, @read_at, @reply_to)`
  ).run(row);

  const message = publicMessage(row);
  const event = { type: 'message', conversationId: conversation.id, message };
  for (const uid of conversationParticipants(conversation)) {
    if (uid !== me) notifyUser(uid, event); // skip sender: it already appends from the HTTP response
  }

  if (kind === 'text') runBotReplies(conversation, me, body);
  queueBotUpdates(conversation, me, message.id);

  res.status(201).json({ message });
});

router.patch('/messages/:id', (req, res) => {
  const ctx = getMessageFor(req, res);
  if (!ctx) return;
  const { me, msg, conversation } = ctx;
  if (msg.sender_id !== me)
    return res.status(403).json({ error: 'only the sender can edit a message' });
  if (msg.kind !== 'text') return res.status(400).json({ error: 'only text messages can be edited' });
  if (msg.deleted) return res.status(400).json({ error: 'message deleted' });

  const body = String(req.body?.body ?? '').slice(0, 8000);
  if (!body.trim()) return res.status(400).json({ error: 'message body required' });

  db.prepare('UPDATE messages SET body = ?, edited_at = ? WHERE id = ?').run(body, Date.now(), msg.id);
  const updated = publicMessage(db.prepare('SELECT * FROM messages WHERE id = ?').get(msg.id));
  broadcastGroup(conversation, { type: 'message-updated', conversationId: conversation.id, message: updated }, me);
  res.json({ message: updated });
});

router.delete('/messages/:id', (req, res) => {
  const ctx = getMessageFor(req, res);
  if (!ctx) return;
  const { me, msg, conversation } = ctx;
  if (msg.sender_id !== me)
    return res.status(403).json({ error: 'only the sender can delete a message' });
  if (msg.deleted) return res.status(400).json({ error: 'message already deleted' });

  const attachmentId = msg.attachment_id;
  db.prepare(
    'UPDATE messages SET deleted = 1, body = NULL, attachment_id = NULL, pinned_at = NULL WHERE id = ?'
  ).run(msg.id);
  deleteAttachmentsIfUnreferenced([attachmentId]);
  const updated = publicMessage(db.prepare('SELECT * FROM messages WHERE id = ?').get(msg.id));
  broadcastGroup(conversation, { type: 'message-deleted', conversationId: conversation.id, message: updated }, me);
  res.json({ message: updated });
});

router.post('/messages/:id/forward', (req, res) => {
  const ctx = getMessageFor(req, res);
  if (!ctx) return;
  const { me, msg } = ctx;
  if (msg.deleted) return res.status(400).json({ error: 'cannot forward a deleted message' });

  const targetId = String(req.body?.conversationId || '');
  const conversation = db.prepare('SELECT * FROM conversations WHERE id = ?').get(targetId);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });
  const peerId = conversationParticipants(conversation).find((uid) => uid !== me);
  if (conversation.kind !== 'group' && peerId && isBlockedAny(me, peerId))
    return res.status(403).json({ error: 'blocked' });

  const row = {
    id: crypto.randomUUID(),
    conversation_id: conversation.id,
    sender_id: me,
    kind: msg.kind,
    body: msg.body,
    attachment_id: msg.attachment_id,
    created_at: Date.now(),
    read_at: null,
    forwarded_from: msg.id,
  };
  db.prepare(
    `INSERT INTO messages (id, conversation_id, sender_id, kind, body, attachment_id, created_at, read_at, forwarded_from)
     VALUES (@id, @conversation_id, @sender_id, @kind, @body, @attachment_id, @created_at, @read_at, @forwarded_from)`
  ).run(row);

  const message = publicMessage(row);
  const event = { type: 'message', conversationId: conversation.id, message };
  for (const uid of conversationParticipants(conversation)) {
    if (uid !== me) notifyUser(uid, event);
  }
  res.status(201).json({ message });
});

router.post('/messages/:id/pin', (req, res) => {
  const ctx = getMessageFor(req, res);
  if (!ctx) return;
  const { me, msg, conversation } = ctx;
  if (msg.deleted) return res.status(400).json({ error: 'message deleted' });

  const pinned = req.body?.pinned === true;
  db.prepare('UPDATE messages SET pinned_at = ? WHERE id = ?').run(pinned ? Date.now() : null, msg.id);
  const updated = publicMessage(db.prepare('SELECT * FROM messages WHERE id = ?').get(msg.id));
  broadcastGroup(
    conversation,
    { type: 'message-pinned', conversationId: conversation.id, message: updated },
    me
  );
  res.json({ message: updated });
});

router.post('/messages/:id/reactions', (req, res) => {
  const ctx = getMessageFor(req, res);
  if (!ctx) return;
  const { me, msg, conversation } = ctx;
  if (msg.deleted) return res.status(400).json({ error: 'message deleted' });

  const emoji = String(req.body?.emoji ?? '').slice(0, 16);
  if (!emoji) return res.status(400).json({ error: 'emoji required' });

  let reactions = {};
  try {
    reactions = JSON.parse(msg.reactions || '{}');
  } catch {
    reactions = {};
  }
  const ids = Array.isArray(reactions[emoji]) ? reactions[emoji] : [];
  if (ids.includes(me)) {
    reactions[emoji] = ids.filter((u) => u !== me);
  } else {
    reactions[emoji] = [...ids, me];
  }
  if (reactions[emoji].length === 0) delete reactions[emoji];

  db.prepare('UPDATE messages SET reactions = ? WHERE id = ?').run(JSON.stringify(reactions), msg.id);
  const updated = publicMessage(db.prepare('SELECT * FROM messages WHERE id = ?').get(msg.id));
  broadcastGroup(
    conversation,
    { type: 'message-reactions', conversationId: conversation.id, message: updated },
    me
  );
  res.json({ message: updated });
});

router.get('/conversations/:id/pinned', (req, res) => {
  const me = req.user.sub;
  const conversation = db.prepare('SELECT * FROM conversations WHERE id = ?').get(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });

  const rows = db
    .prepare(
      `SELECT * FROM messages
       WHERE conversation_id = ? AND pinned_at IS NOT NULL
       ORDER BY pinned_at DESC`
    )
    .all(conversation.id);
  res.json({ messages: rows.map((r) => publicMessage(r)) });
});

router.delete('/conversations/:id/messages', (req, res) => {
  const me = req.user.sub;
  const conversation = db.prepare('SELECT * FROM conversations WHERE id = ?').get(req.params.id);
  if (!conversation || !assertParticipant(conversation, me))
    return res.status(404).json({ error: 'conversation not found' });

  const attachmentIds = attachmentIdsForConversation(conversation.id);
  db.prepare('DELETE FROM messages WHERE conversation_id = ?').run(conversation.id);
  deleteAttachmentsIfUnreferenced(attachmentIds);
  res.json({ ok: true });
});

router.post('/attachments', upload.single('file'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'file required (multipart field name: file)' });
  const row = {
    id: crypto.randomUUID(),
    owner_id: req.user.sub,
    name: Buffer.from(req.file.originalname, 'latin1').toString('utf8') || req.file.filename,
    mime: req.file.mimetype || 'application/octet-stream',
    size: req.file.size,
    path: req.file.path,
    created_at: Date.now(),
  };
  db.prepare(
    `INSERT INTO attachments (id, owner_id, name, mime, size, path, created_at)
     VALUES (@id, @owner_id, @name, @mime, @size, @path, @created_at)`
  ).run(row);
  res.status(201).json({ attachment: attachmentRowToPublic(row) });
});

router.get('/attachments/:id', (req, res) => {
  const row = db.prepare('SELECT * FROM attachments WHERE id = ?').get(req.params.id);
  if (!row || !fs.existsSync(row.path))
    return res.status(404).json({ error: 'attachment not found' });
  res.setHeader('Content-Type', row.mime);
  res.setHeader(
    'Content-Disposition',
    `attachment; filename*=UTF-8''${encodeURIComponent(row.name)}`
  );
  res.sendFile(path.resolve(row.path));
});

export default router;
