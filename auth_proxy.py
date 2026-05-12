#!/usr/bin/env python3
"""OpenHost auth proxy for Nitter (Pattern E — no app-level SSO).

Nitter has no user accounts. OpenHost's zone_auth cookie gates all access.
This proxy:
  - Listens on 0.0.0.0:8080
  - Proxies to 127.0.0.1:8800 (Nitter)
  - Serves /healthz
  - Rewrites Host header from X-Forwarded-Host
  - Strips internal OpenHost headers
"""

from __future__ import annotations

import http.client
import http.server
import os
import socket
import socketserver
import sys
import threading

LISTEN_ADDR = "0.0.0.0"
LISTEN_PORT = int(os.environ.get("AUTH_PROXY_LISTEN_PORT", "8080"))
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = int(os.environ.get("AUTH_PROXY_UPSTREAM_PORT", "8800"))

STRIP_REQUEST_HEADERS = frozenset(h.lower() for h in [
    "x-openhost-is-owner", "x-openhost-app-token",
    "x-openhost-user", "x-openhost-zone-domain", "x-openhost-app-name",
])

HOP_BY_HOP = frozenset(h.lower() for h in [
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
])

MAX_REQUEST_BODY = 10 * 1024 * 1024


class NitterProxyHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        pass

    def _serve_healthz(self):
        body = b'{"status":"ok"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _proxy(self):
        path_only = self.path.split("?", 1)[0]
        if path_only == "/healthz":
            self._serve_healthz()
            return

        body = None
        cl = self.headers.get("Content-Length")
        if cl:
            body = self.rfile.read(min(int(cl), MAX_REQUEST_BODY))

        upstream_headers = {}
        for key in self.headers:
            lk = key.lower()
            if lk in STRIP_REQUEST_HEADERS or lk in HOP_BY_HOP or lk == "host":
                continue
            values = self.headers.get_all(key)
            if values:
                upstream_headers[key] = ", ".join(values)

        fh = self.headers.get("X-Forwarded-Host")
        if fh:
            upstream_headers["Host"] = fh
        else:
            upstream_headers["Host"] = f"{UPSTREAM_HOST}:{UPSTREAM_PORT}"

        if "X-Forwarded-Proto" not in upstream_headers:
            upstream_headers["X-Forwarded-Proto"] = "https"

        try:
            conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=60)
            conn.request(self.command, self.path, body=body, headers=upstream_headers)
            resp = conn.getresponse()
        except (ConnectionRefusedError, socket.timeout, OSError) as exc:
            try:
                self.send_error(502, f"Upstream unavailable: {exc}")
            except OSError:
                pass
            return

        try:
            resp_body = resp.read()
        except Exception:
            try:
                self.send_error(502, "Failed reading upstream")
            except OSError:
                pass
            return

        try:
            self.send_response(resp.status)
            for key, value in resp.getheaders():
                lk = key.lower()
                if lk in HOP_BY_HOP or lk in ("transfer-encoding", "content-length"):
                    continue
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(resp_body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(resp_body)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            conn.close()

    def do_GET(self):
        self._proxy()

    def do_POST(self):
        self._proxy()

    def do_PUT(self):
        self._proxy()

    def do_DELETE(self):
        self._proxy()

    def do_PATCH(self):
        self._proxy()

    def do_HEAD(self):
        self._proxy()

    def do_OPTIONS(self):
        self._proxy()


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    server = ThreadedHTTPServer((LISTEN_ADDR, LISTEN_PORT), NitterProxyHandler)
    print(f"[auth_proxy] listening on {LISTEN_ADDR}:{LISTEN_PORT} -> "
          f"{UPSTREAM_HOST}:{UPSTREAM_PORT}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
