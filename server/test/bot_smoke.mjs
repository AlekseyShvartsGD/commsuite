import Database from 'better-sqlite3';
import crypto from 'node:crypto';

const BASE = 'http://127.0.0.1:3000/api';
const suffix = crypto.randomBytes(4).toString('hex');
const username = `zzbot_${suffix}`;
const password = 'test-pass-12345';
let token = '';
let botId = '';
let botUsername = '';
let userId = '';

async function call(method, path, body, auth = true) {
  const res = await fetch(BASE + path, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(auth && token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let data = {};
  try {
    data = await res.json();
  } catch {}
  return { status: res.status, data };
}

function check(name, ok, extra = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${extra ? ` — ${extra}` : ''}`);
  if (!ok) process.exitCode = 1;
}

const db = new Database(new URL('../data/app.db', import.meta.url).pathname);

function cleanup() {
  try {
    const convs = db
      .prepare(
        `SELECT DISTINCT c.id FROM conversations c
         LEFT JOIN group_members gm ON gm.conversation_id = c.id
         WHERE c.user_low IN (?, ?) OR c.user_high IN (?, ?)
            OR (c.kind = 'group' AND gm.user_id IN (?, ?))`
      )
      .all(userId, botId, userId, botId, userId, botId);
    for (const { id } of convs) {
      db.prepare('DELETE FROM messages WHERE conversation_id = ?').run(id);
      db.prepare('DELETE FROM group_members WHERE conversation_id = ?').run(id);
      db.prepare('DELETE FROM conversations WHERE id = ?').run(id);
    }
    if (botId) {
      db.prepare('DELETE FROM bot_replies WHERE bot_id = ?').run(botId);
      db.prepare('DELETE FROM bots WHERE user_id = ?').run(botId);
    }
    for (const id of [botId, userId].filter(Boolean)) {
      db.prepare('DELETE FROM blocks WHERE blocked_by = ? OR blocked = ?').run(id, id);
      db.prepare('DELETE FROM reports WHERE reporter_id = ? OR target_id = ?').run(id, id);
      db.prepare('DELETE FROM users WHERE id = ?').run(id);
    }
  } catch (e) {
    console.error('cleanup failed:', e.message);
  }
}

try {
  const reg = await call('POST', '/register', {
    username,
    password,
    displayName: `Bot Tester ${suffix}`,
    bio: '',
  });
  check('register test user', reg.status === 200 || reg.status === 201, `status ${reg.status}`);
  token = reg.data.token;
  userId = reg.data.user.id;

  const created = await call('POST', '/bots', {
    name: 'Ping Bot Test',
    description: 'Automated test bot',
    miniApp: 'base64',
    mode: 'builtin',
  });
  check('create bot', created.status === 201, JSON.stringify(created.data).slice(0, 300));
  const bot = created.data.bot;
  botId = bot?.user?.id;
  botUsername = bot?.user?.username;
  check('bot is a user with role bot', bot?.user?.role === 'bot' && bot.user.isBot === true);
  check('bot gets generated username', !!botUsername && botUsername.endsWith('_bot'));

  const directory = await call('GET', `/users?query=${encodeURIComponent(botUsername)}`);
  check(
    'bot appears in directory',
    directory.data.users?.some((u) => u.id === botId && u.isBot)
  );

  const login = await call('POST', '/login', { username: botUsername, password: 'whatever' }, false);
  check('bot cannot sign in', login.status === 403, `status ${login.status}`);

  const rule = await call('POST', `/bots/${botId}/replies`, {
    trigger: 'ping',
    reply: 'pong',
  });
  check('add keyword reply', rule.status === 201 && rule.data.bot.replies.length === 1);

  const conv = await call('POST', '/conversations', { peerId: botId });
  check('open conversation with bot', conv.status === 200 || conv.status === 201);
  const convId = conv.data.conversation?.id;

  await call('POST', `/conversations/${convId}/messages`, { kind: 'text', body: 'ping' });
  await new Promise((r) => setTimeout(r, 300));
  let msgs = await call('GET', `/conversations/${convId}/messages?limit=50`);
  let replied = msgs.data.messages?.some(
    (m) => m.senderId === botId && m.body === 'pong'
  );
  check('bot answers keyword automatically', replied);

  await call('POST', `/conversations/${convId}/messages`, {
    kind: 'text',
    body: '/b64 hello',
  });
  await new Promise((r) => setTimeout(r, 300));
  msgs = await call('GET', `/conversations/${convId}/messages?limit=50`);
  replied = msgs.data.messages?.some(
    (m) => m.senderId === botId && m.body === 'aGVsbG8='
  );
  check('bot mini-app base64 command works', replied);

  await call('POST', `/conversations/${convId}/messages`, { kind: 'text', body: '/help' });
  await new Promise((r) => setTimeout(r, 300));
  msgs = await call('GET', `/conversations/${convId}/messages?limit=50`);
  replied = msgs.data.messages?.some(
    (m) => m.senderId === botId && m.body.includes('/b64')
  );
  check('bot /help lists mini-app commands', replied);

  const before = (await call('GET', `/conversations/${convId}/messages?limit=50`)).data.messages
    .length;
  await call('PATCH', `/bots/${botId}`, { enabled: false });
  await call('POST', `/conversations/${convId}/messages`, {
    kind: 'text',
    body: 'ping again',
  });
  await new Promise((r) => setTimeout(r, 300));
  const after = (await call('GET', `/conversations/${convId}/messages?limit=50`)).data.messages
    .length;
  check('paused bot stays silent', after === before + 1, `${before} -> ${after}`);

  const del = await call('DELETE', `/bots/${botId}`);
  check('delete bot', del.status === 200);
  const bots = await call('GET', '/bots');
  check('bot list empty after delete', bots.data.bots?.length === 0);
  const gone = await call('GET', `/users/${botId}`);
  check('bot user removed', gone.status === 404);
  botId = '';
} catch (e) {
  console.error('TEST ERROR', e);
  process.exitCode = 1;
} finally {
  cleanup();
  db.close();
  console.log('cleaned up test rows');
}
