import Database from 'better-sqlite3';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const dataDir = path.join(__dirname, 'data');
export const uploadsDir = path.join(dataDir, 'uploads');
fs.mkdirSync(uploadsDir, { recursive: true });

const db = new Database(path.join(dataDir, 'app.db'));
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id            TEXT PRIMARY KEY,
  username      TEXT NOT NULL UNIQUE COLLATE NOCASE,
  display_name  TEXT NOT NULL,
  bio           TEXT NOT NULL DEFAULT '',
  role          TEXT NOT NULL DEFAULT 'user',
  password_hash TEXT NOT NULL,
  created_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS blocks (
  blocked_by TEXT NOT NULL,
  blocked    TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (blocked_by, blocked)
);

CREATE TABLE IF NOT EXISTS reports (
  reporter_id TEXT NOT NULL,
  target_id   TEXT NOT NULL,
  reason      TEXT NOT NULL DEFAULT '',
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (reporter_id, target_id)
);

CREATE TABLE IF NOT EXISTS conversations (
  id          TEXT PRIMARY KEY,
  user_low    TEXT NOT NULL,
  user_high   TEXT NOT NULL,
  kind        TEXT NOT NULL DEFAULT 'dm',
  name        TEXT,
  description TEXT NOT NULL DEFAULT '',
  created_at  INTEGER NOT NULL,
  UNIQUE (user_low, user_high)
);

-- Group chats. Role: owner | admin | member. last_read_at is the per-member
-- read watermark used for group unread counts. muted silences notifications
-- for just this member.
CREATE TABLE IF NOT EXISTS group_members (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id         TEXT NOT NULL,
  role            TEXT NOT NULL DEFAULT 'member',
  muted           INTEGER NOT NULL DEFAULT 0,
  last_read_at    INTEGER,
  created_at      INTEGER NOT NULL,
  PRIMARY KEY (conversation_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_gm_user ON group_members(user_id);

CREATE TABLE IF NOT EXISTS attachments (
  id         TEXT PRIMARY KEY,
  owner_id   TEXT NOT NULL,
  name       TEXT NOT NULL,
  mime       TEXT NOT NULL,
  size       INTEGER NOT NULL,
  path       TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id       TEXT NOT NULL,
  kind            TEXT NOT NULL DEFAULT 'text',
  body            TEXT,
  attachment_id   TEXT REFERENCES attachments(id),
  created_at      INTEGER NOT NULL,
  read_at         INTEGER,
  edited_at       INTEGER,
  reply_to        TEXT,
  forwarded_from  TEXT,
  pinned_at       INTEGER,
  deleted         INTEGER NOT NULL DEFAULT 0,
  reactions       TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS games (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  type            TEXT NOT NULL,
  a_user          TEXT NOT NULL,
  b_user          TEXT NOT NULL,
  a_input         TEXT,
  b_input         TEXT,
  secret          TEXT,
  guess_count     INTEGER NOT NULL DEFAULT 0,
  status          TEXT NOT NULL DEFAULT 'active',
  created_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_games_active ON games(conversation_id, status);

CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_unread ON messages(conversation_id, sender_id, read_at);
`);

// Migrate existing databases that predate the `bio` / `role` columns.
const userCols = db.prepare('PRAGMA table_info(users)').all().map((c) => c.name);
if (!userCols.includes('bio')) {
  db.exec("ALTER TABLE users ADD COLUMN bio TEXT NOT NULL DEFAULT ''");
}
if (!userCols.includes('role')) {
  db.exec("ALTER TABLE users ADD COLUMN role TEXT NOT NULL DEFAULT 'user'");
}
const gameCols = db.prepare('PRAGMA table_info(games)').all().map((c) => c.name);
if (!gameCols.includes('guess_count')) {
  db.exec('ALTER TABLE games ADD COLUMN guess_count INTEGER NOT NULL DEFAULT 0');
}
const convCols = db.prepare('PRAGMA table_info(conversations)').all().map((c) => c.name);
if (!convCols.includes('kind')) {
  db.exec("ALTER TABLE conversations ADD COLUMN kind TEXT NOT NULL DEFAULT 'dm'");
}
if (!convCols.includes('name')) {
  db.exec('ALTER TABLE conversations ADD COLUMN name TEXT');
}
if (!convCols.includes('description')) {
  db.exec("ALTER TABLE conversations ADD COLUMN description TEXT NOT NULL DEFAULT ''");
}
const msgCols = db.prepare('PRAGMA table_info(messages)').all().map((c) => c.name);
if (!msgCols.includes('edited_at')) {
  db.exec('ALTER TABLE messages ADD COLUMN edited_at INTEGER');
}
if (!msgCols.includes('reply_to')) {
  db.exec('ALTER TABLE messages ADD COLUMN reply_to TEXT');
}
if (!msgCols.includes('forwarded_from')) {
  db.exec('ALTER TABLE messages ADD COLUMN forwarded_from TEXT');
}
if (!msgCols.includes('pinned_at')) {
  db.exec('ALTER TABLE messages ADD COLUMN pinned_at INTEGER');
}
if (!msgCols.includes('deleted')) {
  db.exec('ALTER TABLE messages ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0');
}
if (!msgCols.includes('reactions')) {
  db.exec("ALTER TABLE messages ADD COLUMN reactions TEXT NOT NULL DEFAULT '{}'");
}

export function pairKey(a, b) {
  return a < b ? [a, b] : [b, a];
}

export function findConversation(a, b) {
  const [low, high] = pairKey(a, b);
  return db
    .prepare('SELECT * FROM conversations WHERE user_low = ? AND user_high = ?')
    .get(low, high);
}

export function ensureConversation(a, b) {
  const existing = findConversation(a, b);
  if (existing) return existing;
  const [low, high] = pairKey(a, b);
  const row = {
    id: crypto.randomUUID(),
    user_low: low,
    user_high: high,
    created_at: Date.now(),
  };
  db.prepare(
    'INSERT INTO conversations (id, user_low, user_high, created_at) VALUES (@id, @user_low, @user_high, @created_at)'
  ).run(row);
  return row;
}

export function conversationParticipants(conversation) {
  if (conversation.kind === 'group') {
    const rows = db
      .prepare('SELECT user_id FROM group_members WHERE conversation_id = ?')
      .all(conversation.id);
    return rows.map((r) => r.user_id);
  }
  return [conversation.user_low, conversation.user_high];
}

/// The acting user's membership row in a group, or null when not a member
/// (or when the conversation is a DM).
export function groupMemberRow(conversationId, userId) {
  return db
    .prepare('SELECT * FROM group_members WHERE conversation_id = ? AND user_id = ?')
    .get(conversationId, userId);
}

/// Full member list for a group, owner → admin → member then join order.
export function groupMembers(conversationId) {
  return db
    .prepare(
      `SELECT gm.user_id, gm.role AS member_role, gm.muted, gm.last_read_at, gm.created_at AS joined_at,
              u.username, u.display_name, u.bio, u.role AS user_role
       FROM group_members gm
       JOIN users u ON u.id = gm.user_id
       WHERE gm.conversation_id = ?
       ORDER BY CASE gm.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, gm.created_at ASC`
    )
    .all(conversationId);
}

const lastMsgStmt = db.prepare(
  'SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at DESC LIMIT 1'
);

function conversationLastMessage(conversationId) {
  const row = lastMsgStmt.get(conversationId);
  return row ? publicMessage(row) : null;
}

const unreadDmStmt = db.prepare(
  `SELECT COUNT(*) AS n FROM messages
   WHERE conversation_id = ? AND sender_id != ? AND read_at IS NULL`
);
const unreadGroupStmt = db.prepare(
  `SELECT COUNT(*) AS n FROM messages m
   WHERE m.conversation_id = ? AND m.sender_id != ?
     AND m.created_at > COALESCE(
       (SELECT last_read_at FROM group_members WHERE conversation_id = ? AND user_id = ?),
       0)`
);

function conversationUnread(conversation, me) {
  if (conversation.kind === 'group') {
    return unreadGroupStmt.get(conversation.id, me, conversation.id, me).n;
  }
  return unreadDmStmt.get(conversation.id, me).n;
}

/// Marks everything [me] has received in [conversation] as read: DM messages
/// use the per-message read_at column, groups use the member read watermark.
export function markConversationRead(conversation, me) {
  if (conversation.kind === 'group') {
    const mine = groupMemberRow(conversation.id, me);
    if (mine) {
      db.prepare(
        'UPDATE group_members SET last_read_at = ? WHERE conversation_id = ? AND user_id = ?'
      ).run(Date.now(), conversation.id, me);
    }
    return;
  }
  db.prepare(
    'UPDATE messages SET read_at = ? WHERE conversation_id = ? AND sender_id != ? AND read_at IS NULL'
  ).run(Date.now(), conversation.id, me);
}

export function publicConversation(c, me) {
  const base = {
    id: c.id,
    kind: c.kind,
    name: c.name ?? null,
    description: c.description ?? '',
    lastMessage: conversationLastMessage(c.id),
    unread: me ? conversationUnread(c, me) : 0,
    createdAt: c.created_at,
  };
  if (c.kind === 'group') {
    const members = groupMembers(c.id);
    const mine = members.find((m) => m.user_id === me);
    return {
      ...base,
      members: members.map((m) => ({
        user: publicUser({
          id: m.user_id,
          username: m.username,
          display_name: m.display_name,
          bio: m.bio ?? '',
          role: m.user_role ?? 'user',
          created_at: m.joined_at,
        }),
        role: m.member_role,
        muted: !!m.muted,
        createdAt: m.joined_at,
      })),
      myRole: mine?.member_role ?? 'member',
      muted: !!mine?.muted,
    };
  }
  const peerId = conversationParticipants(c).find((uid) => uid !== me) || c.user_low;
  const peer = db.prepare('SELECT * FROM users WHERE id = ?').get(peerId);
  return { ...base, peer: publicUser(peer) };
}

export function publicUser(row) {
  if (!row) return null;
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name,
    bio: row.bio ?? '',
    role: row.role ?? 'user',
    createdAt: row.created_at,
  };
}

/// True when either side of [a]↔[b] has blocked the other.
export function isBlockedAny(a, b) {
  return !!db
    .prepare(
      `SELECT 1 FROM blocks
       WHERE (blocked_by = ? AND blocked = ?) OR (blocked_by = ? AND blocked = ?)
       LIMIT 1`
    )
    .get(a, b, b, a);
}

export function publicMessage(row, attachment) {
  const sender = db
    .prepare('SELECT username, display_name FROM users WHERE id = ?')
    .get(row.sender_id);
  let reactions = [];
  try {
    const raw = JSON.parse(row.reactions || '{}');
    for (const [emoji, ids] of Object.entries(raw)) {
      if (Array.isArray(ids) && ids.length > 0) reactions.push({ emoji, userIds: ids });
    }
  } catch {
    reactions = [];
  }
  return {
    id: row.id,
    conversationId: row.conversation_id,
    senderId: row.sender_id,
    senderName: sender?.display_name ?? null,
    senderUsername: sender?.username ?? null,
    kind: row.kind,
    body: row.deleted ? null : row.body,
    attachment:
      row.deleted || !row.attachment_id
        ? null
        : attachment ||
          attachmentRowToPublic(
            db.prepare('SELECT * FROM attachments WHERE id = ?').get(row.attachment_id)
          ),
    createdAt: row.created_at,
    readAt: row.read_at,
    edited: !!row.edited_at,
    replyTo: row.reply_to || null,
    forwardedFrom: row.forwarded_from || null,
    pinned: !!row.pinned_at,
    deleted: !!row.deleted,
    reactions,
  };
}

export function attachmentRowToPublic(row) {
  if (!row) return null;
  return {
    id: row.id,
    name: row.name,
    mime: row.mime,
    size: row.size,
    url: `/api/attachments/${row.id}`,
    createdAt: row.created_at,
  };
}

export default db;
