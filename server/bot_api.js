import { Router } from 'express';
import crypto from 'node:crypto';
import db, {
  conversationParticipants,
  isBlockedAny,
  publicMessage,
} from './db.js';
import { notifyUser } from './realtime.js';

/// Public bot API, modelled on the Telegram Bot API.
///
/// Authenticate with `Authorization: Bearer cmsb_…` (the token shown in
/// Developer tools). A bot can use the regular user endpoints too, but these
/// three are the convenient loop for an external program:
///
///   GET  /api/bot/me
///   GET  /api/bot/updates?offset=<id>&timeout=<seconds>
///   POST /api/bot/sendMessage { conversationId, text, replyTo? }
const router = Router();

router.use((req, res, next) => {
  if (!req.user.bot)
    return res.status(403).json({ error: 'a bot token is required' });
  next();
});

function botUser(id) {
  return db.prepare('SELECT * FROM users WHERE id = ?').get(id);
}

router.get('/me', (req, res) => {
  const user = botUser(req.user.sub);
  if (!user) return res.status(401).json({ error: 'unknown bot' });
  res.json({
    id: user.id,
    username: user.username,
    displayName: user.display_name,
    bio: user.bio,
  });
});

router.get('/updates', async (req, res, next) => {
  const botId = req.user.sub;
  const offset = Math.max(parseInt(req.query.offset || '0', 10) || 0, 0);
  const timeout = Math.min(
    Math.max(parseInt(req.query.timeout || '0', 10) || 0, 0),
    50
  );
  const limit = Math.min(
    Math.max(parseInt(req.query.limit || '100', 10) || 100, 1),
    100
  );

  // Like getUpdates in Telegram: passing the last seen update id confirms it.
  if (offset > 0) {
    db.prepare('DELETE FROM bot_updates WHERE bot_id = ? AND id <= ?').run(
      botId,
      offset
    );
  }

  const select = db.prepare(
    `SELECT u.id AS update_id, u.conversation_id, m.*
     FROM bot_updates u JOIN messages m ON m.id = u.message_id
     WHERE u.bot_id = ? AND u.id > ?
     ORDER BY u.id ASC LIMIT ?`
  );

  const deadline = Date.now() + timeout * 1000;
  try {
    for (;;) {
      const rows = select.all(botId, offset, limit);
      if (rows.length > 0 || Date.now() >= deadline) {
        return res.json({
          updates: rows.map((row) => ({
            updateId: row.update_id,
            conversationId: row.conversation_id,
            message: publicMessage(row),
          })),
        });
      }
      await new Promise((resolve) => setTimeout(resolve, 300));
    }
  } catch (e) {
    next(e);
  }
});

router.post('/sendMessage', (req, res) => {
  const botId = req.user.sub;
  const conversationId = String(req.body?.conversationId || '');
  const conversation = db
    .prepare('SELECT * FROM conversations WHERE id = ?')
    .get(conversationId);
  if (!conversation || !conversationParticipants(conversation).includes(botId))
    return res.status(404).json({ error: 'conversation not found' });

  const peerId = conversationParticipants(conversation).find(
    (uid) => uid !== botId
  );
  if (conversation.kind !== 'group' && peerId && isBlockedAny(botId, peerId))
    return res.status(403).json({ error: 'blocked' });

  const text =
    req.body?.text != null ? String(req.body.text).slice(0, 8000) : '';
  if (!text.trim()) return res.status(400).json({ error: 'text required' });

  let replyTo = null;
  if (req.body?.replyTo) {
    replyTo = String(req.body.replyTo);
    const reply = db
      .prepare('SELECT id FROM messages WHERE id = ? AND conversation_id = ?')
      .get(replyTo, conversation.id);
    if (!reply)
      return res.status(400).json({ error: 'reply message not found' });
  }

  const row = {
    id: crypto.randomUUID(),
    conversation_id: conversation.id,
    sender_id: botId,
    kind: 'text',
    body: text,
    attachment_id: null,
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
    if (uid !== botId) notifyUser(uid, event);
  }
  res.status(201).json({ message });
});

export default router;
