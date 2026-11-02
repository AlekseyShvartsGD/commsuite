import { Router } from 'express';
import crypto from 'node:crypto';
import db, {
  findConversation,
  isBlockedAny,
  publicUser,
} from './db.js';
import { notifyUser, onlineUserIds } from './realtime.js';

// Server-relayed live streams. Media always flows through the TURN relay; this
// router owns the *channel* side of a broadcast: the persistent profile, the
// live directory, viewership limits, the dedicated stream chat, moderators and
// bans. Signalling itself stays on the websocket and is validated against the
// rows created here.
const router = Router();

const MAX_VIEWERS = 8;
const VISIBILITIES = new Set(['public', 'unlisted', 'contacts']);
const MAX_TITLE = 80;
const MAX_DESCRIPTION = 500;
const MAX_GAME = 60;

const selectChannel = db.prepare('SELECT * FROM stream_channels WHERE user_id = ?');
const selectSession = db.prepare('SELECT * FROM stream_sessions WHERE id = ?');
const selectLiveByBroadcaster = db.prepare(
  "SELECT * FROM stream_sessions WHERE broadcaster_id = ? AND status = 'live'"
);
const countViewers = db.prepare('SELECT COUNT(*) AS n FROM stream_viewers WHERE stream_id = ?');
const isViewer = db.prepare(
  'SELECT 1 FROM stream_viewers WHERE stream_id = ? AND user_id = ?'
);
const isChannelMod = db.prepare(
  'SELECT 1 FROM stream_mods WHERE broadcaster_id = ? AND user_id = ?'
);
const isChannelBanned = db.prepare(
  'SELECT 1 FROM stream_bans WHERE broadcaster_id = ? AND user_id = ?'
);

const clamp = (value, max) => String(value ?? '').trim().slice(0, max);

function ensureChannel(userId) {
  const row = selectChannel.get(userId);
  if (row) return row;
  const created = {
    user_id: userId,
    title: '',
    description: '',
    game: '',
    visibility: 'public',
    slow_mode: 0,
    updated_at: Date.now(),
  };
  db.prepare(
    `INSERT INTO stream_channels
       (user_id, title, description, game, visibility, slow_mode, updated_at)
     VALUES (@user_id, @title, @description, @game, @visibility, @slow_mode, @updated_at)`
  ).run(created);
  return selectChannel.get(userId);
}

function userRow(id) {
  return db.prepare('SELECT * FROM users WHERE id = ?').get(id);
}

function isMod(broadcasterId, userId) {
  return !!isChannelMod.get(broadcasterId, userId);
}

function isBanned(broadcasterId, userId) {
  return !!isChannelBanned.get(broadcasterId, userId);
}

/// A DM or group both accounts belong to. "Contacts" visibility means there is
/// at least one conversation connecting viewer and broadcaster.
function hasSharedConversation(a, b) {
  if (findConversation(a, b)) return true;
  return !!db
    .prepare(
      `SELECT 1 FROM group_members mine
       JOIN group_members theirs ON theirs.conversation_id = mine.conversation_id
       WHERE mine.user_id = ? AND theirs.user_id = ? LIMIT 1`
    )
    .get(a, b);
}

function canSee(me, session) {
  if (session.broadcaster_id === me) return true;
  if (isBlockedAny(me, session.broadcaster_id)) return false;
  if (isBanned(session.broadcaster_id, me)) return false;
  if (session.visibility === 'public') return true;
  if (session.visibility === 'contacts') return hasSharedConversation(me, session.broadcaster_id);
  return false; // unlisted: reachable by link/id only
}

function publicStream(session, me) {
  const broadcaster = userRow(session.broadcaster_id);
  const viewers = countViewers.get(session.id).n;
  const mine = session.broadcaster_id === me;
  return {
    id: session.id,
    title: session.title,
    description: session.description,
    game: session.game,
    visibility: session.visibility,
    slowMode: session.slow_mode,
    viewerCount: viewers,
    maxViewers: MAX_VIEWERS,
    startedAt: session.started_at,
    endedAt: session.ended_at ?? null,
    status: session.status,
    chatId: session.chat_id ?? null,
    broadcaster: publicUser(broadcaster),
    isMine: mine,
    canManage: mine || isMod(session.broadcaster_id, me),
    isMod: isMod(session.broadcaster_id, me),
    isViewer: !!isViewer.get(session.id, me),
  };
}

function notifyViewers(session, payload, exceptUserId) {
  for (const row of db.prepare('SELECT user_id FROM stream_viewers WHERE stream_id = ?').all(session.id)) {
    if (row.user_id === exceptUserId) continue;
    notifyUser(row.user_id, payload);
  }
}

function addChatMember(chatId, userId, role = 'member') {
  if (!chatId) return;
  db.prepare(
    `INSERT INTO group_members (conversation_id, user_id, role, created_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT (conversation_id, user_id) DO UPDATE SET role = excluded.role`
  ).run(chatId, userId, role, Date.now());
}

function removeChatMember(chatId, userId) {
  if (!chatId) return;
  db.prepare('DELETE FROM group_members WHERE conversation_id = ? AND user_id = ?').run(
    chatId,
    userId
  );
  notifyUser(userId, { type: 'group-removed', conversationId: chatId });
}

/// Creates the dedicated group chat for a broadcast. The broadcaster owns it;
/// viewers are added on join and removed when they leave, get kicked or banned.
function createStreamChat(broadcasterId, title, description) {
  const id = crypto.randomUUID();
  const name = (title || 'Live stream').slice(0, 64);
  db.prepare(
    `INSERT INTO conversations
       (id, user_low, user_high, kind, name, description, created_at)
     VALUES (?, ?, ?, 'group', ?, ?, ?)`
  ).run(id, id, id, name, description.slice(0, 300), Date.now());
  addChatMember(id, broadcasterId, 'owner');
  for (const mod of db
    .prepare('SELECT user_id FROM stream_mods WHERE broadcaster_id = ?')
    .all(broadcasterId)) {
    addChatMember(id, mod.user_id, 'admin');
  }
  return id;
}

function removeViewer(session, userId) {
  db.prepare('DELETE FROM stream_viewers WHERE stream_id = ? AND user_id = ?').run(
    session.id,
    userId
  );
  removeChatMember(session.chat_id, userId);
}

/// Ends a broadcast: closes the directory entry, empties the chat down to the
/// broadcaster (history stays readable for them) and tells every viewer.
function endSession(session, reason) {
  if (session.status !== 'live') return false;
  db.prepare("UPDATE stream_sessions SET status = 'ended', ended_at = ? WHERE id = ?").run(
    Date.now(),
    session.id
  );
  for (const row of db.prepare('SELECT user_id FROM stream_viewers WHERE stream_id = ?').all(session.id)) {
    notifyUser(row.user_id, { type: 'stream-ended', streamId: session.id, reason });
    removeChatMember(session.chat_id, row.user_id);
  }
  db.prepare('DELETE FROM stream_viewers WHERE stream_id = ?').run(session.id);
  // Moderators who never joined stop seeing the channel chat once it is over.
  for (const mod of db
    .prepare('SELECT user_id FROM stream_mods WHERE broadcaster_id = ?')
    .all(session.broadcaster_id)) {
    removeChatMember(session.chat_id, mod.user_id);
  }
  return true;
}

function requireSession(id) {
  return selectSession.get(String(id || ''));
}

function canManageStream(session, userId) {
  return session.broadcaster_id === userId || isMod(session.broadcaster_id, userId);
}

// ---- channel profile ------------------------------------------------------

router.get('/streams/mine', (req, res) => {
  const me = req.user.sub;
  const channel = ensureChannel(me);
  const live = selectLiveByBroadcaster.get(me);
  res.json({
    channel: {
      title: channel.title,
      description: channel.description,
      game: channel.game,
      visibility: channel.visibility,
      slowMode: channel.slow_mode,
    },
    live: live ? publicStream(live, me) : null,
  });
});

router.patch('/streams/channel', (req, res) => {
  const me = req.user.sub;
  const channel = ensureChannel(me);

  const title = req.body?.title === undefined ? channel.title : clamp(req.body.title, MAX_TITLE);
  const description =
    req.body?.description === undefined
      ? channel.description
      : clamp(req.body.description, MAX_DESCRIPTION);
  const game = req.body?.game === undefined ? channel.game : clamp(req.body.game, MAX_GAME);
  let visibility = channel.visibility;
  if (req.body?.visibility !== undefined) {
    visibility = String(req.body.visibility);
    if (!VISIBILITIES.has(visibility))
      return res.status(400).json({ error: 'visibility must be public, unlisted or contacts' });
  }
  let slowMode = channel.slow_mode;
  if (req.body?.slowMode !== undefined) {
    slowMode = Number(req.body.slowMode);
    if (![0, 3, 10, 30].includes(slowMode))
      return res.status(400).json({ error: 'slow mode must be 0, 3, 10 or 30 seconds' });
  }

  db.prepare(
    `UPDATE stream_channels
        SET title = ?, description = ?, game = ?, visibility = ?, slow_mode = ?, updated_at = ?
      WHERE user_id = ?`
  ).run(title, description, game, visibility, slowMode, Date.now(), me);

  // A profile edit during a broadcast applies to the live session too, so the
  // directory entry never shows a stale game or title.
  const live = selectLiveByBroadcaster.get(me);
  if (live) {
    db.prepare(
      `UPDATE stream_sessions
          SET title = ?, description = ?, game = ?, visibility = ?, slow_mode = ?
        WHERE id = ?`
    ).run(title, description, game, visibility, slowMode, live.id);
    const updated = selectSession.get(live.id);
    notifyViewers(updated, { type: 'stream-updated', stream: publicStream(updated, me) });
  }

  res.json({
    channel: { title, description, game, visibility, slowMode },
    live: live ? publicStream(selectSession.get(live.id), me) : null,
  });
});

// ---- directory ------------------------------------------------------------

router.get('/streams', (req, res) => {
  const me = req.user.sub;
  const rows = db
    .prepare(
      `SELECT s.*, u.username, u.display_name, u.is_verified, u.role AS user_role
         FROM stream_sessions s JOIN users u ON u.id = s.broadcaster_id
        WHERE s.status = 'live'`
    )
    .all();
  const visible = rows.filter((row) => canSee(me, row)).map((row) => publicStream(row, me));
  visible.sort((a, b) => b.viewerCount - a.viewerCount || b.startedAt - a.startedAt);
  res.json({ streams: visible });
});

router.get('/streams/games', (req, res) => {
  const rows = db
    .prepare(
      `SELECT game, MAX(started_at) AS last
         FROM stream_sessions
        WHERE game != ''
        GROUP BY game
        ORDER BY last DESC
        LIMIT 20`
    )
    .all();
  res.json({ games: rows.map((r) => r.game) });
});

router.get('/streams/:id', (req, res) => {
  const me = req.user.sub;
  const session = requireSession(req.params.id);
  if (!session) return res.status(404).json({ error: 'stream not found' });
  if (session.status !== 'live') {
    if (session.broadcaster_id !== me && !isViewer.get(session.id, me))
      return res.status(404).json({ error: 'stream ended' });
  } else if (!canSee(me, session)) {
    return res.status(403).json({ error: 'stream is private' });
  }
  res.json({ stream: publicStream(session, me) });
});

// ---- going live -----------------------------------------------------------

router.post('/streams', (req, res) => {
  const me = req.user.sub;
  const channel = ensureChannel(me);

  if (selectLiveByBroadcaster.get(me))
    return res.status(409).json({ error: 'already live' });

  const title = clamp(req.body?.title ?? channel.title, MAX_TITLE);
  if (!title) return res.status(400).json({ error: 'set a stream title first' });
  const description = clamp(req.body?.description ?? channel.description, MAX_DESCRIPTION);
  const game = clamp(req.body?.game ?? channel.game, MAX_GAME);
  let visibility = String(req.body?.visibility ?? channel.visibility);
  if (!VISIBILITIES.has(visibility))
    return res.status(400).json({ error: 'invalid visibility' });
  const slowMode = Number(req.body?.slowMode ?? channel.slow_mode);
  if (![0, 3, 10, 30].includes(slowMode))
    return res.status(400).json({ error: 'invalid slow mode' });

  const id = crypto.randomUUID();
  const chatId = createStreamChat(me, title, game ? `${game} · ${description}` : description);
  db.prepare(
    `INSERT INTO stream_sessions
       (id, broadcaster_id, title, description, game, visibility, slow_mode, chat_id, status, started_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'live', ?)`
  ).run(id, me, title, description, game, visibility, slowMode, chatId, Date.now());
  // Keep the saved profile in step with what actually went live.
  db.prepare(
    `UPDATE stream_channels
        SET title = ?, description = ?, game = ?, visibility = ?, slow_mode = ?, updated_at = ?
      WHERE user_id = ?`
  ).run(title, description, game, visibility, slowMode, Date.now(), me);

  const session = selectSession.get(id);
  res.status(201).json({ stream: publicStream(session, me), chatId });
});

// ---- watching -------------------------------------------------------------

router.post('/streams/:id/join', (req, res) => {
  const me = req.user.sub;
  const session = requireSession(req.params.id);
  if (!session) return res.status(404).json({ error: 'stream not found' });
  if (session.status !== 'live') return res.status(410).json({ error: 'stream ended' });
  if (session.broadcaster_id === me)
    return res.status(400).json({ error: 'broadcaster cannot join as a viewer' });
  if (isBanned(session.broadcaster_id, me))
    return res.status(403).json({ error: 'you are banned from this channel' });
  if (isBlockedAny(me, session.broadcaster_id))
    return res.status(403).json({ error: 'blocked' });
  if (session.visibility === 'contacts' && !hasSharedConversation(me, session.broadcaster_id))
    return res.status(403).json({ error: 'stream is limited to contacts' });

  const already = !!isViewer.get(session.id, me);
  if (!already && countViewers.get(session.id).n >= MAX_VIEWERS)
    return res.status(409).json({ error: 'stream is full', maxViewers: MAX_VIEWERS });

  if (!already) {
    db.prepare('INSERT INTO stream_viewers (stream_id, user_id, joined_at) VALUES (?, ?, ?)').run(
      session.id,
      me,
      Date.now()
    );
  }
  addChatMember(session.chat_id, me, 'member');
  // Surface the stream chat in the viewer's conversation list immediately.
  notifyUser(me, { type: 'group-added', conversationId: session.chat_id });

  if (!already) {
    notifyUser(session.broadcaster_id, {
      type: 'stream-viewer-joined',
      streamId: session.id,
      viewer: publicUser(userRow(me)),
      viewerCount: countViewers.get(session.id).n,
    });
  }

  const updated = selectSession.get(session.id);
  res.json({ stream: publicStream(updated, me), chatId: updated.chat_id });
});

router.post('/streams/:id/leave', (req, res) => {
  const me = req.user.sub;
  const session = requireSession(req.params.id);
  if (!session) return res.status(404).json({ error: 'stream not found' });
  if (!isViewer.get(session.id, me)) return res.json({ ok: true });
  removeViewer(session, me);
  notifyUser(session.broadcaster_id, {
    type: 'stream-viewer-left',
    streamId: session.id,
    userId: me,
    viewerCount: countViewers.get(session.id).n,
  });
  res.json({ ok: true });
});

router.post('/streams/:id/end', (req, res) => {
  const me = req.user.sub;
  const session = requireSession(req.params.id);
  if (!session) return res.status(404).json({ error: 'stream not found' });
  if (session.broadcaster_id !== me)
    return res.status(403).json({ error: 'only the broadcaster can end the stream' });
  const ended = endSession(session, 'ended');
  res.json({ ok: true, ended });
});

// ---- management: viewers, kick, ban, mods --------------------------------

router.get('/streams/:id/viewers', (req, res) => {
  const me = req.user.sub;
  const session = requireSession(req.params.id);
  if (!session) return res.status(404).json({ error: 'stream not found' });
  if (!canManageStream(session, me))
    return res.status(403).json({ error: 'not allowed' });
  const online = new Set(onlineUserIds());
  const rows = db
    .prepare(
      `SELECT v.user_id, v.joined_at, u.username, u.display_name, u.is_verified
         FROM stream_viewers v JOIN users u ON u.id = v.user_id
        WHERE v.stream_id = ?
        ORDER BY v.joined_at ASC`
    )
    .all(session.id);
  res.json({
    viewers: rows.map((r) => ({
      ...publicUser({
        id: r.user_id,
        username: r.username,
        display_name: r.display_name,
        is_verified: r.is_verified,
        created_at: r.joined_at,
      }),
      joinedAt: r.joined_at,
      online: online.has(r.user_id),
    })),
    maxViewers: MAX_VIEWERS,
  });
});

router.post('/streams/:id/kick', (req, res) => {
  const me = req.user.sub;
  const session = requireSession(req.params.id);
  if (!session) return res.status(404).json({ error: 'stream not found' });
  if (!canManageStream(session, me))
    return res.status(403).json({ error: 'not allowed' });
  const target = String(req.body?.userId || '');
  if (!target || target === session.broadcaster_id)
    return res.status(400).json({ error: 'invalid target' });
  if (!isViewer.get(session.id, target))
    return res.status(404).json({ error: 'not watching' });

  removeViewer(session, target);
  notifyUser(target, { type: 'stream-kicked', streamId: session.id, reason: 'kicked' });
  notifyUser(session.broadcaster_id, {
    type: 'stream-viewer-left',
    streamId: session.id,
    userId: target,
    viewerCount: countViewers.get(session.id).n,
  });
  res.json({ ok: true });
});

router.post('/streams/:id/ban', (req, res) => {
  const me = req.user.sub;
  const session = requireSession(req.params.id);
  if (!session) return res.status(404).json({ error: 'stream not found' });
  if (!canManageStream(session, me))
    return res.status(403).json({ error: 'not allowed' });
  const target = String(req.body?.userId || '');
  if (!target || target === session.broadcaster_id)
    return res.status(400).json({ error: 'invalid target' });

  db.prepare(
    'INSERT OR IGNORE INTO stream_bans (broadcaster_id, user_id, created_at) VALUES (?, ?, ?)'
  ).run(session.broadcaster_id, target, Date.now());

  if (isViewer.get(session.id, target)) {
    removeViewer(session, target);
    notifyUser(target, { type: 'stream-kicked', streamId: session.id, reason: 'banned' });
    notifyUser(session.broadcaster_id, {
      type: 'stream-viewer-left',
      streamId: session.id,
      userId: target,
      viewerCount: countViewers.get(session.id).n,
    });
  }
  res.json({ ok: true });
});

router.delete('/streams/:id/ban/:userId', (req, res) => {
  const me = req.user.sub;
  const session = requireSession(req.params.id);
  if (!session) return res.status(404).json({ error: 'stream not found' });
  if (!canManageStream(session, me))
    return res.status(403).json({ error: 'not allowed' });
  db.prepare('DELETE FROM stream_bans WHERE broadcaster_id = ? AND user_id = ?').run(
    session.broadcaster_id,
    String(req.params.userId)
  );
  res.json({ ok: true });
});

router.get('/streams/:id/bans', (req, res) => {
  const me = req.user.sub;
  const session = requireSession(req.params.id);
  if (!session) return res.status(404).json({ error: 'stream not found' });
  if (!canManageStream(session, me))
    return res.status(403).json({ error: 'not allowed' });
  const rows = db
    .prepare(
      `SELECT b.user_id, b.created_at, u.username, u.display_name
         FROM stream_bans b JOIN users u ON u.id = b.user_id
        WHERE b.broadcaster_id = ?
        ORDER BY b.created_at DESC`
    )
    .all(session.broadcaster_id);
  res.json({
    bans: rows.map((r) => ({
      ...publicUser({
        id: r.user_id,
        username: r.username,
        display_name: r.display_name,
        created_at: r.created_at,
      }),
      bannedAt: r.created_at,
    })),
  });
});

router.get('/streams/:id/mods', (req, res) => {
  const me = req.user.sub;
  const session = requireSession(req.params.id);
  if (!session) return res.status(404).json({ error: 'stream not found' });
  if (!canManageStream(session, me))
    return res.status(403).json({ error: 'not allowed' });
  const rows = db
    .prepare(
      `SELECT m.user_id, m.created_at, u.username, u.display_name
         FROM stream_mods m JOIN users u ON u.id = m.user_id
        WHERE m.broadcaster_id = ?
        ORDER BY m.created_at ASC`
    )
    .all(session.broadcaster_id);
  res.json({
    mods: rows.map((r) =>
      publicUser({
        id: r.user_id,
        username: r.username,
        display_name: r.display_name,
        created_at: r.created_at,
      })
    ),
  });
});

router.post('/streams/:id/mods', (req, res) => {
  const me = req.user.sub;
  const session = requireSession(req.params.id);
  if (!session) return res.status(404).json({ error: 'stream not found' });
  if (session.broadcaster_id !== me)
    return res.status(403).json({ error: 'only the broadcaster can appoint moderators' });
  const target = String(req.body?.userId || '');
  const targetRow = userRow(target);
  if (!targetRow || targetRow.role === 'bot')
    return res.status(400).json({ error: 'invalid target' });
  if (target === me) return res.status(400).json({ error: 'you are the broadcaster' });

  db.prepare(
    'INSERT OR IGNORE INTO stream_mods (broadcaster_id, user_id, created_at) VALUES (?, ?, ?)'
  ).run(me, target, Date.now());
  if (session.status === 'live') {
    addChatMember(session.chat_id, target, 'admin');
    notifyUser(target, { type: 'group-added', conversationId: session.chat_id });
  }
  notifyUser(target, { type: 'stream-modded', broadcasterId: me });
  res.json({ ok: true });
});

router.delete('/streams/:id/mods/:userId', (req, res) => {
  const me = req.user.sub;
  const session = requireSession(req.params.id);
  if (!session) return res.status(404).json({ error: 'stream not found' });
  if (session.broadcaster_id !== me)
    return res.status(403).json({ error: 'only the broadcaster can remove moderators' });
  const target = String(req.params.userId);
  db.prepare('DELETE FROM stream_mods WHERE broadcaster_id = ? AND user_id = ?').run(me, target);
  if (session.chat_id && isViewer.get(session.id, target)) {
    addChatMember(session.chat_id, target, 'member');
  }
  notifyUser(target, { type: 'stream-unmodded', broadcasterId: me });
  res.json({ ok: true });
});

export { MAX_VIEWERS, endSession };
export default router;
