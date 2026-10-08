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

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = b'{"status":"ok","version":"test"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if self.path != "/ws/events" or not key:
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
