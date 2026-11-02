import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
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
// Never write test accounts into the live database: the suite runs against a
// throwaway data directory that is deleted when it finishes.
const testDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'commsuite-smoke-'));
const server = spawn(process.execPath, ['index.js'], {
  cwd: serverDir,
  env: { ...process.env, PORT: String(PORT), COMMSUITE_DATA_DIR: testDataDir },
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

  // ---- live streaming: channel, directory, 8 viewers, chat, moderation -----
  console.log('streaming');
  const mine0 = await api('/api/streams/mine', {}, tokenA);
  check('stream channel starts empty', mine0.status === 200 && mine0.json.live === null);

  const saved = await api('/api/streams/channel', {
    method: 'PATCH',
    body: {
      title: 'Speedrun night',
      description: 'Any% attempts',
      game: 'Celeste',
      visibility: 'public',
      slowMode: 0,
    },
  }, tokenA);
  check(
    'channel profile saved',
    saved.status === 200 &&
      saved.json.channel.title === 'Speedrun night' &&
      saved.json.channel.game === 'Celeste',
  );

  const goLive = await api('/api/streams', { method: 'POST' }, tokenA);
  const streamId = goLive.json?.stream?.id;
  const streamChat = goLive.json?.chatId;
  check('go live creates a session and chat', goLive.status === 201 && !!streamId && !!streamChat);
  check('broadcaster sees own live session', goLive.json?.stream?.isMine === true);

  const relive = await api('/api/streams', { method: 'POST' }, tokenA);
  check('cannot start two streams at once', relive.status === 409);

  const dirB = await api('/api/streams', {}, tokenB);
  check(
    'public stream listed in directory',
    dirB.json.streams.some((s) => s.id === streamId && s.broadcaster.id === userA.id),
  );

  const games = await api('/api/streams/games', {}, tokenB);
  check('game autocomplete lists the live game', games.json.games.includes('Celeste'));

  const joinB = await api(`/api/streams/${streamId}/join`, { method: 'POST' }, tokenB);
  check('viewer joins', joinB.status === 200 && joinB.json.chatId === streamChat);
  await sleep(200);
  const joinedEvent = eventsA.find(
    (e) => e.type === 'stream-viewer-joined' && e.streamId === streamId,
  );
  check(
    'broadcaster told a viewer joined',
    joinedEvent?.viewer?.id === userB.id && joinedEvent?.viewerCount === 1,
  );

  wsB.send(JSON.stringify({
    type: 'stream-signal',
    streamId,
    to: userA.id,
    kind: 'offer',
    payload: { sdp: 'v=0', type: 'offer' },
  }));
  await sleep(200);
  const offer = eventsA.find((e) => e.type === 'stream-signal' && e.kind === 'offer');
  check(
    'viewer offer relayed to broadcaster',
    offer?.streamId === streamId && offer?.payload?.sdp === 'v=0',
  );

  wsA.send(JSON.stringify({
    type: 'stream-signal',
    streamId,
    to: userB.id,
    kind: 'answer',
    payload: { sdp: 'v=0', type: 'answer' },
  }));
  await sleep(200);
  const answer = eventsB.find((e) => e.type === 'stream-signal' && e.kind === 'answer');
  check('broadcaster answer relayed to viewer', answer?.streamId === streamId);

  // A third party must not be able to inject signalling into someone's stream.
  const outsider = await api('/api/register', {
    method: 'POST',
    body: { username: `eve${suffix}`, password: 'secret3', displayName: 'Eve' },
  });
  const eveToken = outsider.json.token;
  const wsEve = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${eveToken}`);
  const eventsEve = [];
  wsEve.on('message', (d) => eventsEve.push(JSON.parse(d)));
  await new Promise((resolve, reject) => {
    wsEve.on('open', resolve);
    wsEve.on('error', reject);
  });
  wsEve.send(JSON.stringify({
    type: 'stream-signal',
    streamId,
    to: userB.id,
    kind: 'offer',
    payload: { sdp: 'v=9', type: 'offer' },
  }));
  await sleep(200);
  check(
    'outsider cannot signal into a stream',
    !eventsB.some((e) => e.type === 'stream-signal' && e.payload?.sdp === 'v=9'),
  );

  // Fill the audience: 8 viewers including B, the 9th is refused.
  const extraViewers = [];
  for (let i = 0; i < 7; i++) {
    const reg = await api('/api/register', {
      method: 'POST',
      body: {
        username: `viewer${i}${suffix}`,
        password: 'secret4',
        displayName: `Viewer ${i}`,
      },
    });
    extraViewers.push(reg.json.token);
  }
  let capacityOk = true;
  for (const token of extraViewers) {
    const r = await api(`/api/streams/${streamId}/join`, { method: 'POST' }, token);
    if (r.status !== 200) capacityOk = false;
  }
  check('seven more viewers fit the audience', capacityOk);
  const ninth = await api(`/api/streams/${streamId}/join`, { method: 'POST' }, eveToken);
  check(
    'ninth viewer is refused',
    ninth.status === 409 && ninth.json.error === 'stream is full',
  );

  // Stream chat: messages, then slow mode enforced for viewers but not mods.
  const chatMsg = await api(`/api/conversations/${streamChat}/messages`, {
    method: 'POST',
    body: { kind: 'text', body: 'first!' },
  }, tokenB);
  check('viewer can post in stream chat', chatMsg.status === 201);

  const slow = await api('/api/streams/channel', { method: 'PATCH', body: { slowMode: 3 } }, tokenA);
  check('slow mode saved', slow.status === 200 && slow.json.channel.slowMode === 3);
  const tooFast = await api(`/api/conversations/${streamChat}/messages`, {
    method: 'POST',
    body: { kind: 'text', body: 'second' },
  }, tokenB);
  check(
    'slow mode throttles viewers',
    tooFast.status === 429 &&
      tooFast.json.error === 'slow mode' &&
      tooFast.json.retryAfterMs > 0,
  );

  // Moderators are appointed by the broadcaster and may delete chat messages.
  const appoint = await api(
    `/api/streams/${streamId}/mods`,
    { method: 'POST', body: { userId: userB.id } },
    tokenA,
  );
  check('broadcaster appoints a moderator', appoint.status === 200);
  await sleep(200);
  check(
    'moderator notified',
    eventsB.some((e) => e.type === 'stream-modded' && e.broadcasterId === userA.id),
  );
  const modPost = await api(`/api/conversations/${streamChat}/messages`, {
    method: 'POST',
    body: { kind: 'text', body: 'mods ignore slow mode' },
  }, tokenB);
  check('moderator bypasses slow mode', modPost.status === 201);

  // Kick then ban: kicked viewers can rejoin, banned ones cannot.
  const kick = await api(
    `/api/streams/${streamId}/kick`,
    { method: 'POST', body: { userId: userB.id } },
    tokenA,
  );
  check('broadcaster kicks a viewer', kick.status === 200 && kick.json.ok === true);
  await sleep(200);
  check(
    'kicked viewer notified',
    eventsB.some((e) => e.type === 'stream-kicked' && e.streamId === streamId),
  );
  check(
    'viewer count drops after kick',
    eventsA.some(
      (e) => e.type === 'stream-viewer-left' && e.userId === userB.id && e.viewerCount === 7,
    ),
  );

  const rejoin = await api(`/api/streams/${streamId}/join`, { method: 'POST' }, tokenB);
  check('kicked viewer may rejoin', rejoin.status === 200);

  const ban = await api(
    `/api/streams/${streamId}/ban`,
    { method: 'POST', body: { userId: userB.id } },
    tokenA,
  );
  check('broadcaster bans a viewer', ban.status === 200);
  await sleep(200);
  check(
    'banned viewer notified',
    eventsB.some((e) => e.type === 'stream-kicked' && e.reason === 'banned'),
  );
  const bannedRejoin = await api(`/api/streams/${streamId}/join`, { method: 'POST' }, tokenB);
  check(
    'banned viewer cannot rejoin',
    bannedRejoin.status === 403 && bannedRejoin.json.error.includes('banned'),
  );
  const unban = await api(`/api/streams/${streamId}/ban/${userB.id}`, { method: 'DELETE' }, tokenA);
  check('broadcaster unbans', unban.status === 200);

  const viewers = await api(`/api/streams/${streamId}/viewers`, {}, tokenA);
  check(
    'broadcaster lists live viewers',
    viewers.status === 200 &&
      viewers.json.viewers.length === 7 &&
      viewers.json.maxViewers === 8,
  );
  const viewerListForViewer = await api(`/api/streams/${streamId}/viewers`, {}, eveToken);
  check('non-moderators cannot list the audience', viewerListForViewer.status === 403);

  // Put B back in the audience so the end-of-stream event has a real recipient.
  const rejoinBeforeEnd = await api(`/api/streams/${streamId}/join`, { method: 'POST' }, tokenB);
  check('unbanned viewer can rejoin before the end', rejoinBeforeEnd.status === 200);

  // Ending the broadcast clears the directory and the chat memberships.
  const end = await api(`/api/streams/${streamId}/end`, { method: 'POST' }, tokenA);
  check('broadcaster ends the stream', end.status === 200);
  await sleep(200);
  check(
    'viewers told the stream ended',
    eventsB.some((e) => e.type === 'stream-ended' && e.streamId === streamId),
  );
  const dirAfter = await api('/api/streams', {}, tokenB);
  check('ended stream leaves the directory', !dirAfter.json.streams.some((s) => s.id === streamId));
  const joinEnded = await api(`/api/streams/${streamId}/join`, { method: 'POST' }, tokenB);
  check('cannot join an ended stream', joinEnded.status === 410);

  // A broadcaster whose socket dies must not leave a zombie "live" entry.
  const zoe = await api('/api/register', {
    method: 'POST',
    body: { username: `zoe${suffix}`, password: 'secret5', displayName: 'Zoe' },
  });
  const wsZoe = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${zoe.json.token}`);
  await new Promise((resolve, reject) => {
    wsZoe.on('open', resolve);
    wsZoe.on('error', reject);
  });
  const liveZoe = await api('/api/streams', {
    method: 'POST',
    body: { title: 'Zoe live' },
  }, zoe.json.token);
  const streamZoe = liveZoe.json?.stream?.id;
  const dirZoe = await api('/api/streams', {}, tokenA);
  check('second broadcaster appears in the directory', dirZoe.json.streams.some((s) => s.id === streamZoe));
  wsZoe.close();
  await sleep(600);
  const dirAfterDrop = await api('/api/streams', {}, tokenA);
  check(
    'broadcaster disconnect ends the stream',
    !dirAfterDrop.json.streams.some((s) => s.id === streamZoe),
  );
  wsEve.close();

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
  try {
    fs.rmSync(testDataDir, { recursive: true, force: true });
  } catch {}
}

await sleep(200);
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
