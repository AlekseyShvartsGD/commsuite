import { spawn } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import WebSocket from 'ws';

const PORT = 3457;
const BASE = `http://127.0.0.1:${PORT}`;

let passed = 0;
let failed = 0;

function check(name, cond, extra = '') {
  if (cond) {
    passed++;
    console.log(`  ok   ${name}`);
  } else {
    failed++;
    console.log(`  FAIL ${name}${extra ? ' — ' + extra : ''}`);
  }
}

async function api(path, opts = {}, token) {
  const headers = { ...(opts.headers || {}) };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (opts.body && typeof opts.body !== 'string' && !(opts.body instanceof FormData)) {
    headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(opts.body);
  }
  const res = await fetch(BASE + path, { ...opts, headers });
  let json = null;
  try {
    json = await res.json();
  } catch {}
  return { status: res.status, json };
}

const serverDir = path.dirname(fileURLToPath(new URL('.', import.meta.url)));
const server = spawn(process.execPath, ['index.js'], {
  cwd: serverDir,
  env: { ...process.env, PORT: String(PORT) },
  stdio: ['ignore', 'pipe', 'pipe'],
});

let serverLog = '';
server.stdout.on('data', (d) => (serverLog += d));
server.stderr.on('data', (d) => (serverLog += d));

function failAll(msg) {
  console.error(msg);
  console.error(serverLog);
  server.kill();
  process.exit(1);
}

try {
  let ready = false;
  for (let i = 0; i < 50; i++) {
    try {
      const r = await fetch(`${BASE}/health`);
      if (r.ok) {
        ready = true;
        break;
      }
    } catch {}
    await sleep(100);
  }
  if (!ready) failAll('server did not start');

  console.log('auth');
  const suffix = Date.now().toString(36);
  const regA = await api('/api/register', {
    method: 'POST',
    body: { username: `alice${suffix}`, password: 'secret1', displayName: 'Alice' },
  });
  check('register A', regA.status === 201 && !!regA.json.token);
  const regB = await api('/api/register', {
    method: 'POST',
    body: { username: `bob${suffix}`, password: 'secret2', displayName: 'Bob' },
  });
  check('register B', regB.status === 201 && !!regB.json.token, JSON.stringify(regB.json));
  const badLogin = await api('/api/login', {
    method: 'POST',
    body: { username: `alice${suffix}`, password: 'wrong' },
  });
  check('bad login rejected', badLogin.status === 401);
  const login = await api('/api/login', {
    method: 'POST',
    body: { username: `alice${suffix}`, password: 'secret1' },
  });
  check('login', login.status === 200 && !!login.json.token);
  const tokenA = regA.json.token;
  const tokenB = regB.json.token;
  const userA = regA.json.user;
  const userB = regB.json.user;

  const me = await api('/api/me', {}, tokenA);
  check('me', me.status === 200 && me.json.user.username === `alice${suffix}`);
  const noAuth = await api('/api/users');
  check('unauthorized blocked', noAuth.status === 401);

  console.log('users & conversations');
  const users = await api(`/api/users?query=bob${suffix}`, {}, tokenA);
  check('search users', users.status === 200 && users.json.users.length === 1);

  const convRes = await api('/api/conversations', {
    method: 'POST',
    body: { peerId: userB.id },
  }, tokenA);
  check('create conversation', convRes.status === 200 && !!convRes.json.conversation.id);
  const convId = convRes.json.conversation.id;

  const convRes2 = await api('/api/conversations', {
    method: 'POST',
    body: { peerId: userB.id },
  }, tokenA);
  check('conversation is idempotent', convRes2.json.conversation.id === convId);

  console.log('messages');
  const send = await api(`/api/conversations/${convId}/messages`, {
    method: 'POST',
    body: { kind: 'text', body: 'hello bob' },
  }, tokenA);
  check('send message', send.status === 201 && send.json.message.body === 'hello bob');

  const sendEmpty = await api(`/api/conversations/${convId}/messages`, {
    method: 'POST',
    body: { kind: 'text', body: '  ' },
  }, tokenA);
  check('empty message rejected', sendEmpty.status === 400);

  const msgs = await api(`/api/conversations/${convId}/messages`, {}, tokenB);
  check('peer reads message', msgs.status === 200 && msgs.json.messages.length === 1);

  const convs = await api('/api/conversations', {}, tokenB);
  const convB = convs.json.conversations.find((c) => c.id === convId);
  check('conversation list has last message', convB?.lastMessage?.body === 'hello bob');

  console.log('attachments');
  const form = new FormData();
  form.append('file', new Blob(['PDF-ish hello'], { type: 'text/plain' }), 'note.txt');
  const up = await api('/api/attachments', { method: 'POST', body: form }, tokenA);
  check('upload attachment', up.status === 201 && !!up.json.attachment.id, JSON.stringify(up.json));
  const attId = up.json?.attachment?.id;
  const dl = await fetch(`${BASE}/api/attachments/${attId}`, {
    headers: { Authorization: `Bearer ${tokenB}` },
  });
  const dlText = await dl.text();
  check('download attachment', dl.status === 200 && dlText === 'PDF-ish hello');

  const fileMsg = await api(`/api/conversations/${convId}/messages`, {
    method: 'POST',
    body: { kind: 'file', attachmentId: attId },
  }, tokenA);
  check('file message', fileMsg.status === 201 && fileMsg.json.message.attachment?.name === 'note.txt');

  console.log('websocket');
  const wsA = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${tokenA}`);
  const wsB = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${tokenB}`);
  const eventsA = [];
  const eventsB = [];
  wsA.on('message', (d) => eventsA.push(JSON.parse(d)));
  wsB.on('message', (d) => eventsB.push(JSON.parse(d)));

  await new Promise((resolve, reject) => {
    wsA.on('open', resolve);
    wsA.on('error', reject);
  });
  await new Promise((resolve, reject) => {
    wsB.on('open', resolve);
    wsB.on('error', reject);
  });

  const badWs = await new Promise((resolve) => {
    const bad = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=nope`);
    bad.on('open', () => resolve(false));
    bad.on('error', () => resolve(true));
    bad.on('unexpected-response', () => resolve(true));
  });
  check('bad token rejected at upgrade', badWs);

  await sleep(150);
  const helloA = eventsA.find((e) => e.type === 'hello');
  const helloB = eventsB.find((e) => e.type === 'hello');
  check('hello received', !!helloA && !!helloB);
  check('B sees A online', helloB?.online?.includes(userA.id));
  const presence = eventsA.find((e) => e.type === 'presence' && e.userId === userB.id && e.online);
  check('A got presence for B', !!presence);

  wsB.send(JSON.stringify({ type: 'signal', to: userA.id, kind: 'call-invite', payload: { video: true } }));
  await sleep(200);
  const sig = eventsA.find((e) => e.type === 'signal');
  check('signal relayed', sig?.kind === 'call-invite' && sig?.from?.id === userB.id);

  wsA.send(JSON.stringify({ type: 'typing', conversationId: convId }));
  await sleep(200);
  const typing = eventsB.find((e) => e.type === 'typing');
  check('typing relayed', typing?.conversationId === convId);

  const send2 = await api(`/api/conversations/${convId}/messages`, {
    method: 'POST',
    body: { kind: 'text', body: 'pushed over ws' },
  }, tokenA);
  check('second send', send2.status === 201);
  await sleep(200);
  const pushed = eventsB.find((e) => e.type === 'message' && e.message?.body === 'pushed over ws');
  check('message event pushed to peer', !!pushed);

  wsA.close();
  wsB.close();
} catch (err) {
  failed++;
  console.error('  FAIL unexpected error:', err);
} finally {
  server.kill();
}

await sleep(200);
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
