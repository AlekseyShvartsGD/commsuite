#!/usr/bin/env python3
import socket, sys, time

def probe(host, port, payload, timeout=6):
    try:
        s = socket.create_connection((host, port), timeout=timeout)
    except Exception as e:
        return f"CONNECT FAIL: {e}"
    s.settimeout(timeout)
    s.sendall(payload)
    chunks = []
    try:
        while True:
            d = s.recv(4096)
            if not d:
                break
            chunks.append(d)
    except socket.timeout:
        chunks.append(b"<TIMEOUT>")
    except Exception as e:
        chunks.append(f"<ERR {e}>".encode())
    s.close()
    return b"".join(chunks)

target = sys.argv[1]
host, port = target.rsplit(":", 1)

stun = bytes.fromhex("000100002112a4420000000000000000")  # STUN binding w/ empty txn
tests = {
    "GET /api/auth/me": f"GET /api/auth/me HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode(),
    "junk 'HELLO'": b"HELLO nobody expects this\r\n\r\n",
    "STUN binding": stun,
}
for name, payload in tests.items():
    print(f"=== {name} -> {target} ===")
    out = probe(host, int(port), payload)
    print(out[:200])
    print(f"(len={len(out)})")
    time.sleep(0.3)