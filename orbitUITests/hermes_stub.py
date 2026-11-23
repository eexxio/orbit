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
STATS_LOCK = threading.Lock()
STATS = defaultdict(lambda: {"connections": 0, "prompts": 0})
PARTIAL = "Here is the first part"
LONG_TOOL_SECONDS = 20
SCENARIOS = {
    "Complete the reply": "complete",
    "Close the connection": "disconnect",
    "Fail the reply": "failure",
    "Stop the reply": "stop",
    "Stop without final": "stop-no-final",
    "Stop with error": "stop-error",
    "Ignore the stop": "stop-ignore",
    "Stop while waiting": "stop-waiting",
    "Send the next reply": "next",
    "Run a long task": "long",
}


class HermesStub(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        fixture_id, _, path = urlsplit(self.path).path.lstrip("/").partition("/")
        path = "/" + path
        if path == "/fixture/state":
            with STATS_LOCK:
                self.respond(json.dumps(STATS[fixture_id]).encode(), "application/json")
            return
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
        if len(path) != 5 or path[2] != "fixture" or path[3] not in SCENARIOS.values() or path[4] not in {"delta", "end", "interrupted"}:
            self.send_error(404)
            return
        key = (path[1], path[3], path[4])
        if path[4] == "interrupted":
            if not GATES[key].wait(timeout=5):
                self.send_error(408)
                return
            GATES.pop(key, None)
        else:
            GATES[key].set()
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
        self.write_lock = threading.Lock()
        self.stopped = threading.Event()
        self.interrupt_received = threading.Event()
        self.scenario = None
        with STATS_LOCK:
            STATS[fixture_id]["connections"] += 1
        try:
            self.event("gateway.ready")
            while (request := self.read_request()) is not None:
                method = request["method"]
                if method in {"session.create", "session.resume"}:
                    self.result(request, {"session_id": "runtime", "stored_session_id": "fixture"})
                elif method == "gateway.ping":
                    self.result(request, {})
                elif method == "prompt.submit":
                    self.scenario = SCENARIOS.get(request["params"]["text"])
                    with STATS_LOCK:
                        STATS[fixture_id]["prompts"] += 1
                    self.result(request, {})
                    threading.Thread(target=self.reply, args=(fixture_id, request["params"]["text"]), daemon=True).start()
                elif method == "session.interrupt":
                    self.interrupt_received.set()
                    GATES[fixture_id, self.scenario, "interrupted"].set()
                    if self.scenario == "stop-ignore":
                        self.late_events()
                        continue
                    self.stopped.set()
                    if self.scenario == "stop-error":
                        self.write_json({"jsonrpc": "2.0", "id": request["id"],
                                         "error": {"code": -32000, "message": "Already disconnected"}})
                    else:
                        if self.scenario == "stop":
                            self.late_events()
                        self.result(request, {"status": "interrupted"})
                else:
                    self.write_json({"jsonrpc": "2.0", "id": request["id"],
                                     "error": {"code": -32601, "message": "Method not found"}})
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.stopped.set()

    def reply(self, fixture_id, text):
        try:
            self.stream_reply(fixture_id, text)
        except (BrokenPipeError, ConnectionResetError, ValueError):
            pass

    def stream_reply(self, fixture_id, text):
        if text == "Send after reconnecting":
            self.event("message.complete", {"text": "The next reply arrived."})
            return True
        scenario = SCENARIOS[text]
        self.scenario = scenario
        if scenario == "next":
            if self.wait(fixture_id, scenario, "delta"):
                self.event("message.delta", {"text": "The next reply"})
                if self.wait(fixture_id, scenario, "end"):
                    self.event("message.complete", {"text": "The next reply arrived."})
            return True
        if scenario == "long":
            self.event("message.start", {})
            self.event("tool.start", {"tool_id": "search", "name": "web_search"})
            if self.stopped.wait(timeout=LONG_TOOL_SECONDS):
                return True
            self.event("tool.complete", {"tool_id": "search", "summary": "Found the answer"})
            for _ in range(240):
                if self.stopped.wait(timeout=0.5):
                    return True
                self.event("message.delta", {"text": "The agent keeps working on it. "})
            self.event("message.complete", {"text": "The long task finished."})
            return True
        if not self.wait(fixture_id, scenario, "delta", self.stopped):
            return False
        self.event("message.delta", {"text": PARTIAL})
        if scenario == "disconnect" or scenario.startswith("stop"):
            self.event("tool.start", {"tool_id": "weather", "name": "get_weather"})
        if scenario.startswith("stop"):
            if scenario == "stop-ignore":
                self.interrupt_received.wait(timeout=30)
                while not self.stopped.wait(timeout=0.05):
                    self.event("message.delta", {"text": " OLD TURN MUST NOT APPEAR"})
                return True
            self.stopped.wait(timeout=30)
            return True
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

    def late_events(self):
        self.event("message.delta", {"text": " OLD TURN MUST NOT APPEAR"})
        self.event("message.interim", {"text": "Late interim"})
        self.event("reasoning.delta", {"text": "Late thinking"})
        self.event("tool.start", {"tool_id": "late", "name": "late_tool"})
        self.event("tool.complete", {"tool_id": "weather", "summary": "Late tool result"})
        self.event("message.complete", {"text": "Late final", "status": "interrupted"})
        self.event("error", {"message": "Late error"})

    @staticmethod
    def wait(fixture_id, scenario, phase, stopped=None):
        key = (fixture_id, scenario, phase)
        gate = GATES[key]
        for _ in range(600):
            if stopped is not None and stopped.is_set():
                return False
            if gate.wait(timeout=0.05):
                break
        released = gate.is_set()
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
        with self.write_lock:
            self.wfile.write(header + data)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18765), HermesStub).serve_forever()
