"""Loopback-only Hermes REST and WebSocket fixture for the simulator UI tests."""

import base64
import hashlib
import json
import struct
import threading
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


GATES = defaultdict(threading.Event)
PARTIAL = "Here is the first part"
SCENARIOS = {
    "Complete the reply": "complete",
    "Close the connection": "disconnect",
    "Fail the reply": "failure",
}


class HermesStub(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        fixture_id, _, path = urlsplit(self.path).path.lstrip("/").partition("/")
        path = "/" + path
        if path == "/api/ws":
            self.websocket(fixture_id)
            return
        if path == "/":
            self.respond(b'<script>window.__HERMES_SESSION_TOKEN__ = "fixture";</script>', "text/html")
            return
        data = {
            "/api/status": {"auth_required": False, "version": "fixture"},
            "/api/profiles/active": {"current": "default"},
            "/api/sessions": {"sessions": []},
        }.get(path)
        if data is None:
            self.send_error(404)
            return
        self.respond(json.dumps(data).encode(), "application/json")

    def do_POST(self):
        path = urlsplit(self.path).path.split("/")
        if len(path) != 5 or path[2] != "fixture" or path[3] not in SCENARIOS.values() or path[4] not in {"delta", "end"}:
            self.send_error(404)
            return
        GATES[path[1], path[3], path[4]].set()
        self.send_response(204)
        self.end_headers()

    def respond(self, data, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def websocket(self, fixture_id):
        key = self.headers["Sec-WebSocket-Key"]
        if not key or self.headers.get("Upgrade", "").lower() != "websocket":
            self.send_error(400)
            return
        accept = hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(accept).decode())
        self.end_headers()
        self.close_connection = True
        try:
            self.event("gateway.ready")
            while (request := self.read_request()) is not None:
                method = request["method"]
                if method in {"session.create", "session.resume"}:
                    self.result(request, {"session_id": "runtime", "stored_session_id": "fixture"})
                elif method == "gateway.ping":
                    self.result(request, {})
                elif method == "prompt.submit":
                    self.result(request, {})
                    if not self.reply(fixture_id, request["params"]["text"]):
                        return
                else:
                    self.write_json({"jsonrpc": "2.0", "id": request["id"],
                                     "error": {"code": -32601, "message": "Method not found"}})
        except (BrokenPipeError, ConnectionResetError):
            pass

    def reply(self, fixture_id, text):
        if text == "Send after reconnecting":
            self.event("message.complete", {"text": "The next reply arrived."})
            return True
        scenario = SCENARIOS[text]
        if not self.wait(fixture_id, scenario, "delta"):
            return False
        self.event("message.delta", {"text": PARTIAL})
        if scenario == "disconnect":
            self.event("tool.start", {"tool_id": "weather", "name": "get_weather"})
        if not self.wait(fixture_id, scenario, "end"):
            return False
        if scenario == "disconnect":
            self.write_frame(8, struct.pack("!H", 1001))
            return False
        if scenario == "failure":
            self.event("message.complete", {"status": "error", "partial": True, "text": PARTIAL,
                                            "error": "The test server could not finish the reply."})
        else:
            self.event("message.delta", {"text": " and the ending."})
            self.event("message.complete", {"text": PARTIAL + " and the ending."})
        return True

    @staticmethod
    def wait(fixture_id, scenario, phase):
        key = (fixture_id, scenario, phase)
        gate = GATES[key]
        released = gate.wait(timeout=30)
        GATES.pop(key, None)
        return released

    def read_request(self):
        while header := self.rfile.read(2):
            opcode, size = header[0] & 15, header[1] & 127
            if size == 126:
                size = struct.unpack("!H", self.rfile.read(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.rfile.read(8))[0]
            mask = self.rfile.read(4) if header[1] & 128 else b"\0" * 4
            data = bytes(byte ^ mask[i % 4] for i, byte in enumerate(self.rfile.read(size)))
            if opcode == 8:
                self.write_frame(8, data)
                return None
            if opcode == 9:
                self.write_frame(10, data)
            elif opcode == 1:
                return json.loads(data)
        return None

    def event(self, kind, payload=None):
        self.write_json({"jsonrpc": "2.0", "method": "event", "params": {
            "type": kind, "session_id": "runtime", "payload": payload or {},
        }})

    def result(self, request, result):
        self.write_json({"jsonrpc": "2.0", "id": request["id"], "result": result})

    def write_json(self, value):
        self.write_frame(1, json.dumps(value).encode())

    def write_frame(self, opcode, data):
        size = len(data)
        header = bytes([128 | opcode, size]) if size < 126 else bytes([128 | opcode, 126]) + struct.pack("!H", size)
        self.wfile.write(header + data)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18765), HermesStub).serve_forever()
