// TURN-over-TCP smoke test against the local coturn relay (default 127.0.0.1:3478).
// Verifies the exact path WebRTC will use over an RFC 6544/TURN-TCP relay:
//   STUN binding over TCP, authenticated Allocate (UDP relayed transport),
//   CreatePermission + ChannelBind between two allocations, and a media
//   datagram relayed from allocation A's relay socket to allocation B and
//   delivered over B's TCP channel.
//
// Wire-format notes learned empirically from coturn 4.6.1 ('Gorst'):
//   - STUN/TURN control messages over plain TCP are sent UNframed.
//   - ChannelData frames must be 4-byte aligned (payload padded to multiple
//     of 4); the 16-bit length field holds the unpadded payload size.
//   - XOR-PEER/RELAYED address attributes use RFC 5389 layout
//     [reserved=0][family=1][X-Port][X-Address].
//
// Run: node test/turn_smoke.js   (env: TURN_HOST TURN_PORT TURN_USER TURN_PASS)
import net from 'node:net';
import crypto from 'node:crypto';

const HOST = process.env.TURN_HOST || '127.0.0.1';
const PORT = Number(process.env.TURN_PORT || 3478);
const USER = process.env.TURN_USER || 'commsuite';
const PASS = process.env.TURN_PASS || 'commsuite-1';
const MAGIC = 0x2112a442;

const A = {
  USERNAME: 0x0006, MESSAGE_INTEGRITY: 0x0008, ERROR_CODE: 0x0009,
  REALM: 0x0014, NONCE: 0x0015, CHANNEL_NUMBER: 0x000c, DATA: 0x0013,
  XOR_PEER_ADDRESS: 0x0012, XOR_RELAYED_ADDRESS: 0x0016,
  REQUESTED_TRANSPORT: 0x0019, FINGERPRINT: 0x8028, XOR_MAPPED_ADDRESS: 0x0020,
};

let sno = 0;
function tid() {
  const b = Buffer.alloc(12);
  b.writeUInt32BE(++sno, 0);
  crypto.randomFillSync(b, 4);
  return b;
}

function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) { c ^= b; for (let k = 0; k < 8; k++) c = (c & 1) ? (c >>> 1) ^ 0xedb88320 : c >>> 1; }
  return (c ^ 0xffffffff) >>> 0;
}

function stun(type, t, attrs = []) {
  const body = Buffer.concat(attrs.map(([at, v]) => {
    const h = Buffer.alloc(4);
    h.writeUInt16BE(at, 0);
    h.writeUInt16BE(v.length, 2);
    return Buffer.concat([h, Buffer.from(v.length % 4 ? Buffer.concat([v, Buffer.alloc(4 - (v.length % 4))]) : v)]);
  }));
  const m = Buffer.alloc(20 + body.length);
  m.writeUInt16BE(type, 0);
  m.writeUInt16BE(body.length, 2);
  m.writeUInt32BE(MAGIC, 4);
  t.copy(m, 8);
  body.copy(m, 20);
  return m;
}

// RFC 5389: MI/FP MAC/CRC input runs "up to, but not including", the attribute
// itself (header + value); the message length field includes the attribute.
function build(type, t, attrs, { key, fingerprint = true } = {}) {
  let m = stun(type, t, attrs);
  if (key) {
    const out = Buffer.alloc(m.length + 24);
    m.copy(out, 0, 0, m.length);
    out.writeUInt16BE(m.length - 20 + 24, 2);
    out.writeUInt16BE(A.MESSAGE_INTEGRITY, m.length);
    out.writeUInt16BE(20, m.length + 2);
    crypto.createHmac('sha1', key).update(out.subarray(0, m.length)).digest().copy(out, m.length + 4);
    m = out;
  }
  if (fingerprint !== false) {
    const out = Buffer.alloc(m.length + 8);
    m.copy(out, 0, 0, m.length);
    out.writeUInt16BE(m.length - 20 + 8, 2);
    out.writeUInt16BE(A.FINGERPRINT, m.length);
    out.writeUInt16BE(4, m.length + 2);
    const crc = (crc32(out.subarray(0, m.length)) ^ 0x5354554e) >>> 0;
    out.writeUInt32BE(crc, m.length + 4);
    m = out;
  }
  return m;
}

const xorAddrBytes = (addr) => {
  const out = Buffer.alloc(8);
  out[0] = 0x00; // reserved (first octet all zeros, RFC 5389)
  out[1] = 0x01; // family = IPv4
  out.writeUInt16BE(((addr.port) ^ (MAGIC >> 16)) & 0xffff, 2);
  const ip = addr.ip.split('.').reduce((acc, p, i) => acc | (Number(p) << (24 - 8 * i)), 0) >>> 0;
  out.writeUInt32BE((ip ^ MAGIC) >>> 0, 4);
  return out;
};

const parseXorAddr = (v) => {
  const port = v.readUInt16BE(2) ^ (MAGIC >> 16);
  const ip = (v.readUInt32BE(4) ^ MAGIC) >>> 0;
  return { port, ip: [24, 16, 8, 0].map((s) => (ip >>> s) & 0xff).join('.') };
};

function parseAttrs(b) {
  const out = {};
  for (let i = 0; i + 4 <= b.length;) {
    const at = b.readUInt16BE(i);
    const al = b.readUInt16BE(i + 2);
    if (i + 4 + al > b.length) break;
    out[at] = b.subarray(i + 4, i + 4 + al);
    i += 4 + (((al + 3) >> 2) << 2);
  }
  return out;
}

let passed = 0, failed = 0;
function ok(n) { passed++; console.log(`  ok   ${n}`); }
function fail(n, e) { failed++; console.log(`  FAIL ${n}: ${e}`); }

class TurnConn {
  constructor(label) {
    this.label = label;
    this.sock = null;
    this.buf = Buffer.alloc(0);
    this.resolvers = [];
    this.channelHandlers = [];
    this.stunHandlers = [];
  }
  connect() {
    return new Promise((res, rej) => {
      const s = net.createConnection({ host: HOST, port: PORT });
      s.on('connect', res);
      s.on('error', rej);
      s.on('data', (d) => this._data(d));
      this.sock = s;
    });
  }
  _emitMessage(obj) {
    const list = this.resolvers.splice(0);
    for (const r of list) r(obj);
    for (const h of this.stunHandlers) h(obj);
  }
  _data(d) {
    this.buf = Buffer.concat([this.buf, d]);
    while (this.buf.length >= 2) {
      const f16 = this.buf.readUInt16BE(0);
      // bare ChannelData (first 16 bits = channel number >= 0x4000)
      if (f16 >= 0x4000) {
        if (this.buf.length < 4) break;
        const len = this.buf.readUInt16BE(2);
        if (this.buf.length < 4 + len) break;
        const payload = this.buf.subarray(4, 4 + len);
        this.buf = this.buf.subarray(4 + len);
        for (const h of this.channelHandlers) h(f16 & 0x0fff, payload);
        continue;
      }
      // unframed STUN message (magic cookie at offset 4..7)
      if (this.buf.length >= 20 && this.buf.readUInt32BE(4) === MAGIC) {
        const len = this.buf.readUInt16BE(2);
        if (this.buf.length < 20 + len) break;
        const m = this.buf.subarray(0, 20 + len);
        this.buf = this.buf.subarray(20 + len);
        this._emitMessage({ type: m.readUInt16BE(0), tid: Buffer.from(m.subarray(8, 20)), attrs: parseAttrs(m.subarray(20)) });
        continue;
      }
      // RFC 4571 length-prefixed frame (handled for robustness)
      const olen = f16;
      if (this.buf.length < 2 + olen) break;
      const frameBuf = this.buf.subarray(2, 2 + olen);
      this.buf = this.buf.subarray(2 + olen);
      const inner = frameBuf.readUInt16BE(0);
      if (inner >= 0x4000) {
        const len = frameBuf.readUInt16BE(2);
        for (const h of this.channelHandlers) h(inner & 0x0fff, frameBuf.subarray(4, 4 + len));
      } else {
        this._emitMessage({ type: inner, tid: Buffer.from(frameBuf.subarray(8, 20)), attrs: parseAttrs(frameBuf.subarray(20)) });
      }
    }
  }
  send(m) { this.sock.write(m); }
  next(timeout = 8000) {
    return new Promise((res, rej) => {
      const timer = setTimeout(() => rej(new Error(`${this.label}: timeout`)), timeout);
      this.resolvers.push((obj) => { clearTimeout(timer); res(obj); });
    });
  }
}

async function main() {
  console.log(`TURN-over-TCP smoke to ${HOST}:${PORT} (${USER})`);
  const a = new TurnConn('A');
  const b = new TurnConn('B');
  await a.connect(); ok('tcp connect A');
  await b.connect(); ok('tcp connect B');

  for (const [lab, c] of [['A', a], ['B', b]]) {
    const t = tid();
    c.send(build(0x001, t, []));
    const r = await c.next();
    if (r.type !== 0x0101) throw new Error(`${lab}: bad binding type ${r.type}`);
    ok(`stun binding ${lab}`);
  }

  let key = null;
  async function allocate(c) {
    const t = tid();
    c.send(build(0x003, t, [[A.REQUESTED_TRANSPORT, Buffer.from([0x11, 0, 0, 0])]]));
    const ch1 = await c.next();
    const err = ch1.attrs[A.ERROR_CODE];
    if (!err) throw new Error('expected 401 challenge but got success');
    const realm = ch1.attrs[A.REALM].toString('utf8');
    const nonce = ch1.attrs[A.NONCE];
    key = key || crypto.createHash('md5').update(`${USER}:${realm}:${PASS}`).digest();
    const t2 = tid();
    c.send(build(0x003, t2, [
      [A.USERNAME, Buffer.from(USER)], [A.REALM, Buffer.from(realm)],
      [A.NONCE, nonce], [A.REQUESTED_TRANSPORT, Buffer.from([0x11, 0, 0, 0])],
    ], { key }));
    const r2 = await c.next();
    if (r2.attrs[A.ERROR_CODE]) throw new Error(`allocate failed: ${r2.attrs[A.ERROR_CODE].readUInt16BE(2)}`);
    return { relay: parseXorAddr(r2.attrs[A.XOR_RELAYED_ADDRESS]), nonce };
  }
  const aAlloc = await allocate(a);
  ok(`allocated relay A = ${aAlloc.relay.ip}:${aAlloc.relay.port}`);
  const bAlloc = await allocate(b);
  ok(`allocated relay B = ${bAlloc.relay.ip}:${bAlloc.relay.port}`);

  async function permChan(c, peer, chNum, nonce) {
    const t = tid();
    c.send(build(0x008, t, [
      [A.USERNAME, Buffer.from(USER)], [A.REALM, Buffer.from('commsuite.local')],
      [A.NONCE, nonce], [A.XOR_PEER_ADDRESS, xorAddrBytes(peer)],
    ], { key }));
    const p = await c.next();
    if (p.attrs[A.ERROR_CODE]) throw new Error('createPermission ' + p.attrs[A.ERROR_CODE].readUInt16BE(2));
    const t2 = tid();
    const cn = Buffer.alloc(4); cn.writeUInt16BE(chNum, 0);
    c.send(build(0x009, t2, [
      [A.XOR_PEER_ADDRESS, xorAddrBytes(peer)], [A.CHANNEL_NUMBER, cn],
      [A.USERNAME, Buffer.from(USER)], [A.REALM, Buffer.from('commsuite.local')],
      [A.NONCE, nonce],
    ], { key }));
    const cb = await c.next();
    if (cb.attrs[A.ERROR_CODE]) {
      const e = cb.attrs[A.ERROR_CODE];
      throw new Error(`channelBind ${e.readUInt16BE(2)}: ${e.subarray(4).toString('utf8')}`);
    }
  }
  await permChan(a, bAlloc.relay, 0x4010, aAlloc.nonce);
  ok('createPermission + channelBind A -> relayB');
  await permChan(b, aAlloc.relay, 0x4020, bAlloc.nonce);
  ok('createPermission + channelBind B -> relayA');

  // Payload length must be a multiple of 4 (coturn requires 4-byte aligned
  // ChannelData frames over TCP - mandatory padding on stream sockets).
  const payload = Buffer.from('commsuite-tcp-relay-ok!!');
  const got = new Promise((res, rej) => {
    const timer = setTimeout(() => rej(new Error('no relayed data on B')), 8000);
    b.channelHandlers.push((ch, p) => { clearTimeout(timer); res({ ch, p }); });
    b.stunHandlers.push((m) => {
      if (m.attrs && m.attrs[A.DATA]) { clearTimeout(timer); res({ ch: null, p: m.attrs[A.DATA] }); }
    });
  });
  const hdr = Buffer.alloc(4);
  hdr.writeUInt16BE(0x4010, 0);
  hdr.writeUInt16BE(payload.length, 2);
  a.send(Buffer.concat([hdr, payload]));
  const { ch, p } = await got;
  if (p.toString('utf8') !== payload.toString('utf8')) throw new Error('payload mismatch on relay');
  ok(`media datagram relayed A->B over TCP ${ch ? `(channel 0x${(0x4000 + ch).toString(16)})` : '(data indication)'}`);

  a.sock.destroy();
  b.sock.destroy();
  console.log(`\nRESULT: ${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
}

main().catch((e) => { console.error('FATAL:', e.message); process.exit(1); });