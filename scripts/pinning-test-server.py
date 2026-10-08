#!/usr/bin/env python3
"""Ephemeral loopback TLS health + WebSocket fixture (no codeg server/data)."""
import base64
import hashlib
import http.server
import pathlib
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass  # Never log auth headers or request payloads.

    def headers_allowed(self):
        if not self.path.startswith("/headers/"):
            return True
        if (self.headers.get("CF-Access-Client-Id") == "fixture-id"
                and self.headers.get("CF-Access-Client-Secret") == "fixture-secret"):
            return True
        self.send_error(403)
        return False

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if not self.headers_allowed():
            return
        if self.path.startswith("/redirect-"):
            host, port = self.server.server_address
            targets = {
                "redirect-port": f"https://{host}:{port + 1}/api/health",
                "redirect-scheme": f"http://{host}:{port}/api/health",
                "redirect-host": f"https://localhost:{port}/api/health",
                "redirect-same": f"https://{host}:{port}/api/health",
            }
            self.send_response(307)
            self.send_header("Location", targets[self.path.split("/")[1]])
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path.startswith("/offline/"):
            self.send_error(503)
            return
        body = b'{"status":"ok","version":"test"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self.headers_allowed():
            return
        key = self.headers.get("Sec-WebSocket-Key")
        if self.path not in ("/ws/events", "/headers/ws/events", "/offline/ws/events") or not key:
            self.send_error(404)
            return
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.send_header("Sec-WebSocket-Protocol", "codeg-events")
        self.end_headers()
        body = b'{"channel":"__ready__"}'
        self.wfile.write(bytes([0x81, len(body)]) + body)
        self.wfile.flush()
        self.connection.settimeout(10)
        try:
            self.rfile.read(2)  # The test closes immediately after ready.
        except (TimeoutError, OSError):
            pass
        self.close_connection = True


port = int(sys.argv[1])
if not 18400 <= port <= 18499:
    raise SystemExit("Use loopback port 184xx")
server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
server.socket = context.wrap_socket(server.socket, server_side=True)
pathlib.Path(sys.argv[4]).touch()
server.serve_forever()
