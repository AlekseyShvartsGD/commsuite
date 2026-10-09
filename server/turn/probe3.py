#!/usr/bin/env python3
import socket, sys, time

def probe(host, port, payload, timeout=6, chunks=None):
    try:
        s = socket.create_connection((host, port), timeout=timeout)
    except Exception as e:
        return f"CONNECT FAIL: {e}"
    s.settimeout(timeout)
    if chunks:
        for c in chunks:
            s.sendall(c)
    else:
        s.sendall(payload)
    out = b""
    try:
        while True:
            d = s.recv(4096)
            if not d:
                break
            out += d
    except socket.timeout:
        out += b"<TIMEOUT>"
    except Exception as e:
        out += f"<ERR {e}>".encode()
    s.close()
    return out

host, port = sys.argv[1].rsplit(":", 1)
port = int(port)

tls_clienthello = bytes.fromhex("16030100b5010000b1030358549c5f")  # truncated TLS ClientHello

tests = [
    ("junk passthrough", b"XYZZY not http\r\n\r\n"),
    ("GET HTTP/1.0", b"GET /api/auth/me HTTP/1.0\r\nHost: tcp.cloudpub.ru\r\n\r\n"),
    ("GET no-Host 1.1", b"GET /api/auth/me HTTP/1.1\r\nConnection: close\r\n\r\n"),
    ("HEAD 1.1", b"HEAD /api/auth/me HTTP/1.1\r\nHost: tcp.cloudpub.ru\r\nConnection: close\r\n\r\n"),
    ("TLS ClientHello", tls_clienthello),
    ("POST small", b"POST /api/login HTTP/1.1\r\nHost: tcp.cloudpub.ru\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"),
    ("GET split 8+rest", [b"GET /api", b"/auth/me HTTP/1.1\r\nHost: tcp.cloudpub.ru\r\nConnection: close\r\n\r\n"]),
]
for name, payload in tests:
    print(f"=== {name} ===")
    out = probe(host, port, payload)
    print(out[:150])
    print(f"(len={len(out)})")
    time.sleep(0.2)