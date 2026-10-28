import Database from 'better-sqlite3';
import crypto from 'node:crypto';

const BASE = 'http://127.0.0.1:3000/api';
const suffix = crypto.randomBytes(4).toString('hex');
let token = '';
const userIds = [];
const botIds = [];
let convId = '';

async function call(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
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
    if (convId) {
      db.prepare('DELETE FROM messages WHERE conversation_id = ?').run(convId);
      db.prepare('DELETE FROM group_members WHERE conversation_id = ?').run(convId);
      db.prepare('DELETE FROM conversations WHERE id = ?').run(convId);
    }
    for (const id of botIds) {
      db.prepare('DELETE FROM bot_replies WHERE bot_id = ?').run(id);
      db.prepare('DELETE FROM bots WHERE user_id = ?').run(id);
    }
    for (const id of [...botIds, ...userIds].filter(Boolean)) {
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
    username: `zzgrp_${suffix}`,
    password: 'test-pass-12345',
    displayName: `Group Tester ${suffix}`,
    bio: '',
  });
  token = reg.data.token;
  userIds.push(reg.data.user.id);

  const a = (await call('POST', '/bots', { name: 'Alpha Bot', miniApp: 'json', mode: 'builtin' })).data.bot;
  const b = (await call('POST', '/bots', { name: 'Beta Bot', miniApp: 'uuid', mode: 'builtin' })).data.bot;
  botIds.push(a.user.id, b.user.id);

  await call('POST', `/bots/${a.user.id}/replies`, { trigger: 'ping', reply: 'pong' });
  await call('POST', `/bots/${b.user.id}/replies`, { trigger: 'pong', reply: 'ping' });

  const group = await call('POST', '/conversations/group', {
    name: `Bot group ${suffix}`,
    description: '',
    memberIds: [a.user.id, b.user.id],
  });
  check('create group with bots', group.status === 201, `status ${group.status}`);
  convId = group.data.conversation.id;

  await call('POST', `/conversations/${convId}/messages`, { kind: 'text', body: 'ping' });
  await new Promise((r) => setTimeout(r, 800));
  let msgs = (await call('GET', `/conversations/${convId}/messages?limit=50`)).data.messages;
  const alphaReplies = msgs.filter((m) => m.senderId === a.user.id);
  const betaReplies = msgs.filter((m) => m.senderId === b.user.id);
  check('bot replies in a group', alphaReplies.length === 1 && alphaReplies[0].body === 'pong');
  check(
    'bots do not ping-pong with each other',
    betaReplies.length === 0,
    `beta replies: ${betaReplies.length}`
  );

  await call('PATCH', `/bots/${a.user.id}`, { miniApp: 'uuid' });
  await call('POST', `/conversations/${convId}/messages`, { kind: 'text', body: '/uuid 2' });
  await new Promise((r) => setTimeout(r, 300));
  msgs = (await call('GET', `/conversations/${convId}/messages?limit=100`)).data.messages;
  const uuidReply = [...msgs].reverse().find((m) => m.senderId === a.user.id);
  check(
    'uuid mini-app returns two ids',
    !!uuidReply && uuidReply.body.split('\n').length === 2,
    uuidReply?.body
  );

  await call('PATCH', `/bots/${a.user.id}`, { miniApp: 'json' });
  await call('POST', `/conversations/${convId}/messages`, {
    kind: 'text',
    body: '{"a":1,"b":[2,3]}',
  });
  await new Promise((r) => setTimeout(r, 300));
  msgs = (await call('GET', `/conversations/${convId}/messages?limit=100`)).data.messages;
  const jsonReply = [...msgs].reverse().find((m) => m.senderId === a.user.id);
  check(
    'json mini-app pretty-prints',
    !!jsonReply && jsonReply.body.includes('\n  "a": 1'),
    jsonReply?.body
  );
} catch (e) {
  console.error('TEST ERROR', e);
  process.exitCode = 1;
} finally {
  cleanup();
  db.close();
  console.log('cleaned up test rows');
}
