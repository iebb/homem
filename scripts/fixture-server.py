#!/usr/bin/env python3
"""Deterministic Memoh wire-contract fixture. Local testing only; not a Memoh server."""
import base64
import hashlib
import json
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

TOKEN = "homem-local-fixture-token"
HISTORY = []
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def payload(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        return json.loads(data) if data else {}

    def send_json(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if self.headers.get("Authorization") == f"Bearer {TOKEN}":
            return True
        self.send_json({"message": "Sign in required"}, 401)
        return False

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            return self.send_json({"fixture": "homem"})
        if path == "/avatars/cdn.png":
            if any(self.headers.get(h) for h in ["Authorization", "Cookie", "X-Team-ID"]):
                return self.send_json({"message": "Credentials leaked to image host"}, 400)
            data = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNQSnv3HwAEmgJ2pp70QwAAAABJRU5ErkJggg==")
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if not self.authorized():
            return
        if path in ["/avatars/private", "/avatars/storage"]:
            self.send_response(302)
            self.send_header("Location", "/avatars/storage" if path == "/avatars/private" else "http://localhost:18765/avatars/cdn.png")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path.endswith("/web/ws") or path == "/api/display-test/ws":
            return self.websocket()
        if path == "/api/users/me":
            return self.send_json({"id": "fixture-user", "username": "fixture", "display_name": "Fixture User", "role": "admin"})
        if path == "/api/bots":
            return self.send_json({"items": [{"id": "fixture-bot", "name": "fixture", "display_name": "Wire Test Agent", "is_active": True, "current_user_permissions": ["chat", "manage"]}]})
        if path.endswith("/sessions"):
            return self.send_json({"items": [{"id": "fixture-session", "title": "Live contract test", "bot_id": "fixture-bot", "type": "chat"}]})
        if path.endswith("/messages"):
            with LOCK:
                return self.send_json({"items": HISTORY[:]})
        if path.endswith("/models"):
            return self.send_json({"items": []})
        return self.send_json({"message": "Fixture route not implemented"}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        body = self.payload()
        if path == "/api/auth/login":
            if body == {"username": "fixture", "password": "fixture-password"}:
                return self.send_json({"access_token": TOKEN, "role": "admin"})
            return self.send_json({"message": "Wrong fixture credentials"}, 401)
        if not self.authorized():
            return
        if path == "/api/test/stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            for event in [{"type": "started"}, {"type": "step", "message": "Installing"}, {"type": "done", "id": "fixture-install"}]:
                self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                self.wfile.flush()
                time.sleep(0.02)
            self.close_connection = True
            return
        return self.send_json({"message": "Fixture route not implemented"}, 404)

    def ws_send(self, value, opcode=1):
        data = json.dumps(value).encode() if not isinstance(value, bytes) else value
        header = bytes([0x80 | opcode])
        if len(data) < 126:
            header += bytes([len(data)])
        else:
            header += bytes([126]) + struct.pack("!H", len(data))
        self.wfile.write(header + data)
        self.wfile.flush()

    def websocket(self):
        key = self.headers["Sec-WebSocket-Key"]
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        if urlparse(self.path).path == "/api/display-test/ws":
            return self.desktop()
        seq = 1
        run = None
        try:
            while True:
                header = self.rfile.read(2)
                if len(header) < 2:
                    return
                opcode, length = header[0] & 15, header[1] & 127
                if length == 126:
                    length = struct.unpack("!H", self.rfile.read(2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", self.rfile.read(8))[0]
                mask = self.rfile.read(4) if header[1] & 128 else b""
                data = self.rfile.read(length)
                if mask:
                    data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
                if opcode == 8:
                    return
                if opcode == 9:
                    self.ws_send(data, opcode=10)
                    continue
                event = json.loads(data)
                session = event.get("session_id", "fixture-session")
                if event["type"] == "runtime_subscribe":
                    self.ws_send({"type": "runtime_snapshot", "session_id": session, "epoch": "fixture-epoch", "seq": seq, "snapshot": {"epoch": "fixture-epoch", "seq": seq, "current_run_view": run}})
                elif event["type"] == "message":
                    turn_id = event["invocation_id"]
                    user = {"turn_id": turn_id, "role": "user", "text": event.get("text", ""), "timestamp": "2026-09-17T00:00:00Z", "attachments": event.get("attachments", []), "workspace_target_id": event.get("workspace_target_id", "")}
                    run = {"run_id": "fixture-run", "turn_id": turn_id, "status": "running", "request_user_turn": user, "messages": [{"id": 1, "type": "text", "content": "Verified "}]}
                    self.ws_send({"type": "run_accepted", "session_id": session, "run_id": "fixture-run", "turn_id": turn_id, "invocation_id": turn_id})
                    seq += 1
                    self.ws_send({"type": "runtime_snapshot", "session_id": session, "snapshot": {"epoch": "fixture-epoch", "seq": seq, "current_run_view": run}})
                    time.sleep(0.15)
                    seq += 1
                    self.ws_send({"type": "runtime_delta", "session_id": session, "epoch": "fixture-epoch", "seq": seq, "delta": {"message_appends": [{"id": 1, "type": "text", "content": "native WebSocket response."}]}})
                    run["messages"][0]["content"] = "Verified native WebSocket response."
                    with LOCK:
                        HISTORY.extend([user, {"turn_id": turn_id, "role": "assistant", "messages": run["messages"], "timestamp": "2026-09-17T00:00:01Z"}])
                    seq += 1
                    self.ws_send({"type": "runtime_delta", "session_id": session, "epoch": "fixture-epoch", "seq": seq, "delta": {"run": {"run_id": "fixture-run", "status": "completed"}}})
                    run = None
        except (ConnectionError, BrokenPipeError):
            return

    def desktop(self):
        # A quiet desktop: after the first frame, updates arrive only when a ping
        # proves the client is keeping the transport alive. No production service.
        self.ws_send(b"RFB 003.", opcode=2)
        self.ws_send(b"008\n", opcode=2)
        phase, first_frame = 0, False
        def frame():
            update = b"\x00\x00\x00\x01" + struct.pack("!HHHHi", 0, 0, 2, 2, 0) + bytes([40, 80, 160, 0]) * 4
            self.ws_send(update[:19], opcode=2)
            self.ws_send(update[19:], opcode=2)
        try:
            while True:
                header = self.rfile.read(2)
                if len(header) < 2:
                    return
                opcode, length = header[0] & 15, header[1] & 127
                if length == 126:
                    length = struct.unpack("!H", self.rfile.read(2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", self.rfile.read(8))[0]
                mask = self.rfile.read(4) if header[1] & 128 else b""
                data = self.rfile.read(length)
                if mask:
                    data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
                if opcode == 8:
                    return
                if opcode == 9:
                    self.ws_send(data, opcode=10)
                    if first_frame:
                        frame()
                    continue
                if phase == 0:
                    assert data == b"RFB 003.008\n"
                    self.ws_send(b"\x01\x01", opcode=2)
                elif phase == 1:
                    assert data == b"\x01"
                    self.ws_send(b"\x00" * 4, opcode=2)
                elif phase == 2:
                    self.ws_send(struct.pack("!HH", 2, 2) + b"\x00" * 20, opcode=2)
                elif data[0] == 3 and not first_frame:
                    first_frame = True
                    frame()
                phase += 1
        except (ConnectionError, BrokenPipeError):
            return


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 18765), Handler)
    print("Homem fixture ready at http://127.0.0.1:18765", flush=True)
    server.serve_forever()
