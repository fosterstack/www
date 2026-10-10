#!/usr/bin/env python3
"""A minimal HTTP proxy for the corporate-proxy page's test. Not a production proxy.

It forwards plain HTTP requests that arrive in the absolute form a proxy client sends
("GET http://host:port/path HTTP/1.1"), tunnels HTTPS with CONNECT, can refuse chosen hosts
with a 403, and appends one line per request to a log file. Every connection is closed after
one request so that no request goes unlogged. Standard library only; it listens on 127.0.0.1.

  bench-proxy.py PORT LOGFILE [DENIED_HOST ...]

Log lines: "GET http://host:port/path", "PUT http://...", "CONNECT host:port"; a refused request
has " 403" added at the end.
"""
import socket
import sys
import threading
from urllib.parse import urlsplit

PORT = int(sys.argv[1])
LOG = sys.argv[2]
DENIED = set(sys.argv[3:])
LOCK = threading.Lock()


def log(line):
    with LOCK:
        with open(LOG, "a") as f:
            f.write(line + "\n")


def read_head(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            break
        data += chunk
        if len(data) > 1 << 20:
            break
    head, _, rest = data.partition(b"\r\n\r\n")
    return head, rest


def pipe(src, dst):
    try:
        while True:
            chunk = src.recv(65536)
            if not chunk:
                break
            dst.sendall(chunk)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def refuse(conn):
    conn.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")


def handle(conn):
    try:
        head, rest = read_head(conn)
        if not head:
            return
        lines = head.decode("latin-1").split("\r\n")
        method, target, _version = lines[0].split(" ", 2)
        if method == "CONNECT":
            host, _, port = target.rpartition(":")
            if host in DENIED:
                log("CONNECT %s 403" % target)
                refuse(conn)
                return
            log("CONNECT %s" % target)
            upstream = socket.create_connection((host, int(port)), timeout=30)
            conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            if rest:
                upstream.sendall(rest)
            t = threading.Thread(target=pipe, args=(upstream, conn), daemon=True)
            t.start()
            pipe(conn, upstream)
            t.join(timeout=60)
            upstream.close()
            return
        url = urlsplit(target)
        host = url.hostname
        port = url.port or 80
        path = url.path or "/"
        if url.query:
            path += "?" + url.query
        if host in DENIED:
            log("%s %s 403" % (method, target))
            refuse(conn)
            return
        log("%s %s" % (method, target))
        headers = []
        length = 0
        for h in lines[1:]:
            name = h.split(":", 1)[0].strip().lower()
            if name in ("proxy-connection", "connection", "proxy-authorization"):
                continue
            if name == "content-length":
                length = int(h.split(":", 1)[1])
            headers.append(h)
        upstream = socket.create_connection((host, port), timeout=60)
        req = ("%s %s HTTP/1.1\r\n" % (method, path)) + "\r\n".join(headers) + "\r\nConnection: close\r\n\r\n"
        upstream.sendall(req.encode("latin-1"))
        body = rest
        while len(body) < length:
            chunk = conn.recv(65536)
            if not chunk:
                break
            body += chunk
        if body:
            upstream.sendall(body[:length] if length else body)
        while True:
            chunk = upstream.recv(65536)
            if not chunk:
                break
            conn.sendall(chunk)
        upstream.close()
    except Exception as e:  # keep serving; a failed request is logged, not fatal
        log("ERROR %r" % (e,))
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(64)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
