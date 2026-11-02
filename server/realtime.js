import { WebSocketServer } from 'ws';
import db, {
  conversationParticipants,
  isBlockedAny,
  markConversationRead,
} from './db.js';
import { verifyToken, resolveToken } from './auth.js';

const clients = new Map();

// Live broadcasts are persisted in stream_sessions/stream_viewers; signalling
// needs no in-memory registry, so a server restart cannot strand a peer
// connection pointing at a stream that no longer exists.

export function notifyUser(userId, payload) {
  const sockets = clients.get(userId);
  if (!sockets) return false;
  const data = JSON.stringify(payload);
  for (const ws of sockets) {
    if (ws.readyState === ws.OPEN) ws.send(data);
  }
  return true;
}

export function onlineUserIds() {
  return [...clients.keys()];
}

function addClient(userId, ws) {
  if (!clients.has(userId)) clients.set(userId, new Set());
  clients.get(userId).add(ws);
}

function removeClient(userId, ws) {
  const set = clients.get(userId);
  if (!set) return;
  set.delete(ws);
  if (set.size === 0) {
    clients.delete(userId);
    return true;
  }
  return false;
}

export function attachRealtime(server) {
  const wss = new WebSocketServer({ noServer: true });

  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname !== '/ws') {
      socket.destroy();
      return;
    }
    let user;
    try {
      user = resolveToken(url.searchParams.get('token') || '');
      const banned = db.prepare('SELECT role FROM users WHERE id = ?').get(user.sub);
      if (!banned || banned.role === 'banned') throw new Error('account banned');
    } catch {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.user = user;
      wss.emit('connection', ws, req);
    });
  });

  wss.on('connection', (ws) => {
    const userId = ws.user.sub;
    ws.isAlive = true;
    ws.on('pong', () => {
      ws.isAlive = true;
    });
    addClient(userId, ws);

    ws.send(
      JSON.stringify({
        type: 'hello',
        me: { id: userId, username: ws.user.username, displayName: ws.user.displayName },
        online: onlineUserIds(),
      })
    );

    broadcast({ type: 'presence', userId, online: true }, userId);

    ws.on('message', (raw) => {
      let msg;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        return;
      }
      try {
        handleMessage(ws, msg);
      } catch (err) {
        console.error('ws message error:', err);
        ws.send(JSON.stringify({ type: 'error', message: 'internal error' }));
      }
    });

    ws.on('close', () => {
      const wasLast = removeClient(userId, ws);
      if (wasLast) {
        broadcast({ type: 'presence', userId, online: false }, userId);
        // A broadcaster/viewer that vanished (killed app, lost tunnel) must not
        // leave the other side waiting on a dead peer connection.
        const live = db
          .prepare("SELECT id FROM stream_sessions WHERE broadcaster_id = ? AND status = 'live'")
          .get(userId);
        if (live) endBroadcast(live.id, 'broadcaster-offline');
        for (const row of db
          .prepare(
            `SELECT v.stream_id FROM stream_viewers v
               JOIN stream_sessions s ON s.id = v.stream_id
              WHERE v.user_id = ? AND s.status = 'live'`
          )
          .all(userId)) {
          dropViewer(row.stream_id, userId, 'disconnected');
        }
      }
    });
    ws.on('error', () => {
      // 'close' follows and performs the cleanup; without this handler an
      // error would crash the process.
    });
  });

  function broadcast(payload, exceptUserId) {
    const data = JSON.stringify(payload);
    for (const [uid, sockets] of clients) {
      if (uid === exceptUserId) continue;
      for (const ws of sockets) {
        if (ws.readyState === ws.OPEN) ws.send(data);
      }
    }
  }

  /// Ends a broadcast because its broadcaster went away, not because they
  /// pressed "end". Keeps the DB (and every viewer's UI) consistent.
  function endBroadcast(streamId, reason) {
    const session = db
      .prepare("SELECT * FROM stream_sessions WHERE id = ? AND status = 'live'")
      .get(streamId);
    if (!session) return;
    db.prepare("UPDATE stream_sessions SET status = 'ended', ended_at = ? WHERE id = ?").run(
      Date.now(),
      session.id
    );
    for (const row of db
      .prepare('SELECT user_id FROM stream_viewers WHERE stream_id = ?')
      .all(session.id)) {
      notifyUser(row.user_id, { type: 'stream-ended', streamId: session.id, reason });
      leaveChat(session.chat_id, row.user_id);
    }
    db.prepare('DELETE FROM stream_viewers WHERE stream_id = ?').run(session.id);
    for (const mod of db
      .prepare('SELECT user_id FROM stream_mods WHERE broadcaster_id = ?')
      .all(session.broadcaster_id)) {
      leaveChat(session.chat_id, mod.user_id);
    }
  }

  function leaveChat(chatId, userId) {
    if (!chatId) return;
    db.prepare('DELETE FROM group_members WHERE conversation_id = ? AND user_id = ?').run(
      chatId,
      userId
    );
    notifyUser(userId, { type: 'group-removed', conversationId: chatId });
  }

  /// Drops a viewer whose socket died and tells the broadcaster to tear down
  /// that one peer connection (the other viewers keep watching).
  function dropViewer(streamId, userId, reason) {
    const session = db.prepare('SELECT * FROM stream_sessions WHERE id = ?').get(streamId);
    if (!session) return;
    db.prepare('DELETE FROM stream_viewers WHERE stream_id = ? AND user_id = ?').run(
      streamId,
      userId
    );
    leaveChat(session.chat_id, userId);
    const viewerCount = db
      .prepare('SELECT COUNT(*) AS n FROM stream_viewers WHERE stream_id = ?')
      .get(streamId).n;
    notifyUser(session.broadcaster_id, {
      type: 'stream-viewer-left',
      streamId,
      userId,
      viewerCount,
      reason,
    });
  }

  function isStreamViewer(streamId, userId) {
    return !!db
      .prepare('SELECT 1 FROM stream_viewers WHERE stream_id = ? AND user_id = ?')
      .get(streamId, userId);
  }

  function handleMessage(ws, msg) {
    const from = { id: ws.user.sub, username: ws.user.username, displayName: ws.user.displayName };

    function peerOfConversation(id) {
      const conversation = db
        .prepare('SELECT * FROM conversations WHERE id = ?')
        .get(String(id || ''));
      if (!conversation) return null;
      return conversationParticipants(conversation).find((uid) => uid !== from.id) || null;
    }

    // Messages, typing, files and call signals from a blocked peer must not reach us.
    function blockedFromConversation(id) {
      const peerId = peerOfConversation(id);
      if (!peerId) return false;
      return isBlockedAny(from.id, peerId);
    }

    switch (msg.type) {
      case 'ping': {
        ws.send(JSON.stringify({ type: 'pong', t: Date.now() }));
        break;
      }

      case 'typing': {
        const conversation = db
          .prepare('SELECT * FROM conversations WHERE id = ?')
          .get(String(msg.conversationId || ''));
        if (!conversation || (conversation.kind !== 'group' && blockedFromConversation(conversation.id)))
          return;
        for (const uid of conversationParticipants(conversation)) {
          if (uid === from.id) continue;
          notifyUser(uid, { type: 'typing', conversationId: conversation.id, userId: from.id });
        }
        break;
      }

      case 'file-sending': {
        const conversation = db
          .prepare('SELECT * FROM conversations WHERE id = ?')
          .get(String(msg.conversationId || ''));
        if (!conversation || (conversation.kind !== 'group' && blockedFromConversation(conversation.id)))
          return;
        const name = String(msg.name || '').slice(0, 200);
        for (const uid of conversationParticipants(conversation)) {
          if (uid === from.id) continue;
          notifyUser(uid, {
            type: 'file-sending',
            conversationId: conversation.id,
            userId: from.id,
            name,
          });
        }
        break;
      }

      case 'read': {
        const conversation = db
          .prepare('SELECT * FROM conversations WHERE id = ?')
          .get(String(msg.conversationId || ''));
        if (!conversation || (conversation.kind !== 'group' && blockedFromConversation(conversation.id)))
          return;
        markConversationRead(conversation, from.id);
        // No read-receipt fan-out in groups (unread is per-member watermarks).
        if (conversation.kind === 'group') break;
        for (const uid of conversationParticipants(conversation)) {
          if (uid === from.id) continue;
          notifyUser(uid, {
            type: 'read',
            conversationId: conversation.id,
            userId: from.id,
            at: Date.now(),
          });
        }
        break;
      }

      case 'signal': {
        const to = String(msg.to || '');
        if (!to || to === from.id) return;
        if (isBlockedAny(from.id, to)) return;
        notifyUser(to, {
          type: 'signal',
          from,
          kind: String(msg.kind || ''),
          payload: msg.payload ?? null,
        });
        break;
      }

      case 'stream-signal': {
        // SDP/ICE for one broadcaster↔viewer pair. The REST layer already
        // enforced visibility, capacity and bans; here we only prove the two
        // endpoints really are the broadcaster and one of its viewers.
        const streamId = String(msg.streamId || '');
        const to = String(msg.to || '');
        if (!streamId || !to || to === from.id) return;
        const session = db
          .prepare("SELECT * FROM stream_sessions WHERE id = ? AND status = 'live'")
          .get(streamId);
        if (!session) return;
        const fromIsBroadcaster = session.broadcaster_id === from.id;
        const fromIsViewer = isStreamViewer(streamId, from.id);
        const toIsBroadcaster = session.broadcaster_id === to;
        const toIsViewer = isStreamViewer(streamId, to);
        if (!((fromIsBroadcaster && toIsViewer) || (fromIsViewer && toIsBroadcaster))) return;
        notifyUser(to, {
          type: 'stream-signal',
          streamId,
          from,
          kind: String(msg.kind || ''),
          payload: msg.payload ?? null,
        });
        break;
      }

      default:
        ws.send(JSON.stringify({ type: 'error', message: `unknown type: ${msg.type}` }));
    }
  }

  // Prune sockets whose protocol pong is overdue: a dead device (was killed,
  // suspended, or dropped off the tunnel without a TCP close) must stop being
  // reported as online, otherwise the online list grows with ghosts.
  const heartbeat = setInterval(() => {
    for (const sockets of clients.values()) {
      for (const ws of sockets) {
        if (!ws.isAlive) {
          ws.terminate(); // triggers 'close' -> removeClient + offline broadcast
        } else {
          ws.isAlive = false;
          try {
            ws.ping();
          } catch (_) {}
        }
      }
    }
    // A broadcast whose broadcaster has no socket left (tunnel dropped without
    // a close frame) stops being listed as live.
    for (const row of db
      .prepare("SELECT id, broadcaster_id FROM stream_sessions WHERE status = 'live'")
      .all()) {
      if (!clients.has(row.broadcaster_id)) endBroadcast(row.id, 'broadcaster-offline');
    }
  }, 30000);
  heartbeat.unref();
}
