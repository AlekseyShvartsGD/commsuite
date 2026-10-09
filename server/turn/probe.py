#!/usr/bin/env python3
import socket, sys

def probe(host, port, path="/api/auth/me", timeout=10):
    s = socket.create_connection((host, port), timeout=timeout)
    s.settimeout(timeout)
    req = (f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n").encode()
    s.sendall(req)
    chunks = []
    try:
        while True:
            d = s.recv(4096)
            if not d:
                break
            chunks.append(d)
    except socket.timeout:
        chunks.append(b"<TIMEOUT>")
    s.close()
    return b"".join(chunks)

target = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:7777"
host, port = target.rsplit(":", 1)
data = probe(host, int(port))
print(f"--- raw GET to {target} ---")
print(data[:300].decode("utf-8", "replace"))
print(f"(len={len(data)})")