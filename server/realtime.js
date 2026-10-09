import { WebSocketServer } from 'ws';
import db, {
  conversationParticipants,
  isBlockedAny,
  markConversationRead,
} from './db.js';
import { verifyToken } from './auth.js';

const clients = new Map();

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
      user = verifyToken(url.searchParams.get('token') || '');
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
      if (wasLast) broadcast({ type: 'presence', userId, online: false }, userId);
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
  }, 30000);
  heartbeat.unref();
}
