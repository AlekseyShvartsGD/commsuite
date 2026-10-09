#!/usr/bin/env node
// Single-port protocol multiplexer for the CloudPub TCP tunnel.
// One public TCP endpoint carries BOTH services:
//   - STUN/TURN traffic (magic cookie 0x2112A442 at byte 4) -> coturn :3478
//   - everything else (HTTP API / WebSocket upgrade)          -> node :3000
// This avoids CloudPub's single-tunnel-per-account limit.
import net from 'net';

const PORT = Number(process.env.MUX_PORT || 7777);
const TURN_PORT = Number(process.env.TURN_PORT || 3478);
const HTTP_PORT = Number(process.env.HTTP_PORT || 3000);
const STUN_MAGIC = 0x2112a442;

const server = net.createServer((sock) => {
  let head = Buffer.alloc(0);
  let routed = false;

  sock.on('data', (chunk) => {
    if (routed) return;
    head = Buffer.concat([head, chunk]);
    if (head.length < 8) return; // need the magic cookie window to decide
    routed = true;

    const isStun = head.readUInt32BE(4) === STUN_MAGIC;
    const backend = isStun
      ? { host: '127.0.0.1', port: TURN_PORT }
      : { host: '127.0.0.1', port: HTTP_PORT };

    const up = net.connect(backend, () => {
      up.write(head);
      sock.pipe(up);
      up.pipe(sock);
    });
    up.on('error', () => sock.destroy());
    sock.on('error', () => up.destroy());
  });

  sock.setTimeout(10000, () => {
    if (!routed) sock.destroy();
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`commsuite-mux on :${PORT} -> TURN ${TURN_PORT} / HTTP ${HTTP_PORT}`);
});