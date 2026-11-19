"""Loopback-only Hermes REST and WebSocket fixture for the simulator UI tests."""

import base64
import hashlib
import json
import struct
import threading
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


GATES = defaultdict(threading.Event)
STATS_LOCK = threading.Lock()
STATS = defaultdict(lambda: {"connections": 0, "prompts": 0})
PARTIAL = "Here is the first part"
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
}
DEFAULT_MODEL = "example/sonnet"
WORK_MODEL = "example/work-default"
MODELS = [DEFAULT_MODEL, "example/opus", "example/guarded", "example/refused"]
PROFILES = [
    {"name": "default", "model": DEFAULT_MODEL, "description": "Personal Hermes"},
    {"name": "work", "model": WORK_MODEL, "description": "Work projects"},
]


def options(fixture_id, profile, current=None):
    names = ["example/work-fast", WORK_MODEL] if profile == "work" else MODELS
    authenticated = not fixture_id.startswith("empty-")
    return {"model": current or names[0], "provider": "example", "providers": [
        {"slug": "example", "name": "Example AI", "models": names,
         "is_current": True, "authenticated": authenticated},
        {"slug": "unconfigured", "name": "Unconfigured", "models": ["hidden-model"], "authenticated": False},
    ]}


class HermesStub(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        parsed = urlsplit(self.path)
        fixture_id, _, path = parsed.path.lstrip("/").partition("/")
        path = "/" + path
        profile = parse_qs(parsed.query).get("profile", ["default"])[0]
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
        with STATS_LOCK:
            state = STATS[fixture_id].copy()
        if state.get("offline"):
            self.close_connection = True
            return
        active = "work" if fixture_id.startswith("removed-") and not state.get("removed") else "default"
        if state.get("removed") and profile == "work":
            self.send_error(404)
            return
        if path == "/api/model/options" and fixture_id.startswith("skew-"):
            self.send_response(503)
            body = b'{"detail":"Restart required: Update the Hermes server"}'
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        switcher = fixture_id[0:1].islower()
        if path == "/api/sessions/fixture/messages":
            data = {"messages": [{"id": 1, "role": "assistant", "content": "Earlier chat history."}]}
            self.respond(json.dumps(data).encode(), "application/json")
            return
        sessions = []
        if switcher and profile == active:
            model = "example/retired" if fixture_id.startswith("retired-") else DEFAULT_MODEL
            sessions.append({"id": "fixture", "profile": profile, "title": "Existing chat", "model": state.get("model", model)})
        if state.get("created_profile") == profile:
            sessions.append({"id": "new-fixture", "profile": profile, "title": "Created chat",
                             "model": state.get("created_model")})
        data = {
            "/api/status": {"auth_required": False, "version": "fixture"},
            "/api/profiles/active": {"current": active},
            "/api/profiles": {"profiles": PROFILES if switcher and not state.get("removed") else PROFILES[:1]},
            "/api/model/options": options(fixture_id, profile),
            "/api/sessions": {"sessions": sessions},
        }.get(path)
        if data is None:
            self.send_error(404)
            return
        self.respond(json.dumps(data).encode(), "application/json")

    def do_POST(self):
        path = urlsplit(self.path).path.split("/")
        if len(path) == 4 and path[2] == "fixture" and path[3] in {"offline", "removed"}:
            with STATS_LOCK:
                STATS[path[1]][path[3]] = True
            self.send_response(204)
            self.end_headers()
            return
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
        self.fixture_id = fixture_id
        self.profile = "default"
        self.runtime = "runtime"
        self.stored = "fixture"
        self.model = DEFAULT_MODEL
        self.canonical = fixture_id.startswith(("canonical-", "conflict-", "fallback-", "retired-"))
        with STATS_LOCK:
            STATS[fixture_id]["connections"] += 1
        try:
            self.event("gateway.ready", {"session_authority": self.canonical})
            while (request := self.read_request()) is not None:
                method = request["method"]
                params = request.get("params", {})
                if method in {"session.create", "session.resume"}:
                    self.profile = params.get("profile", "default")
                    with STATS_LOCK:
                        state = STATS[fixture_id]
                        if method == "session.create":
                            self.model = params.get("model", WORK_MODEL if self.profile == "work" else DEFAULT_MODEL)
                            if fixture_id[0:1].islower():
                                self.stored = "new-fixture"
                                state.update(created_profile=self.profile, created_model=self.model,
                                             created_provider=params.get("provider", ""))
                        else:
                            self.stored = params.get("session_id", "fixture")
                            if self.stored == "new-fixture":
                                self.model = state.get("created_model", DEFAULT_MODEL)
                            else:
                                self.model = state.get("model", "example/retired" if fixture_id.startswith("retired-") else DEFAULT_MODEL)
                            state["resumed_profile"] = self.profile
                        revision = state.get("mutations", 0) + state.get("conflicts", 0) + 7
                        if method == "session.resume":
                            state["resumes"] = state.get("resumes", 0) + 1
                    if self.canonical and "close_on_disconnect" in params:
                        self.error(request, 4001, "Unexpected legacy parameter")
                    else:
                        self.result(request, {"session_id": self.stored if self.canonical else self.runtime,
                                              "stored_session_id": self.stored, "execution_generation": 3,
                                              "revision": revision, "running": False,
                                              "info": {"model": self.model, "provider": "example"}})
                elif method == "model.options":
                    self.result(request, options(fixture_id, self.profile, self.model))
                elif method == "session.mutate" and self.canonical:
                    if fixture_id.startswith("conflict-") and not STATS[fixture_id].get("conflicts"):
                        with STATS_LOCK:
                            STATS[fixture_id]["conflicts"] = 1
                        self.error(request, 4001, "Revision is stale", reason="revision_conflict")
                    elif fixture_id.startswith("fallback-"):
                        with STATS_LOCK:
                            STATS[fixture_id]["unsupported_mutations"] = STATS[fixture_id].get("unsupported_mutations", 0) + 1
                        self.error(request, -32601, "Method not found")
                    elif (params.get("operation") != "model" or params.get("session_id") != self.stored
                          or params.get("profile") != self.profile or params.get("expected_generation") != 3
                          or params.get("expected_revision") != revision or not params.get("request_id")):
                        self.error(request, 4001, "Invalid model mutation")
                    else:
                        payload = params["payload"]
                        self.change_model(request, payload["model"], payload.get("confirm") == "fixture-confirm")
                elif method == "config.set":
                    pieces = params.get("value", "").split()
                    session_id = self.stored if self.canonical else self.runtime
                    if (params.get("session_id") != session_id or params.get("key") != "model"
                            or len(pieces) != 4 or pieces[1:] != ["--provider", "example", "--session"]):
                        self.error(request, 4001, "Must scope this switch to the live session")
                    else:
                        self.change_model(request, pieces[0], params.get("confirm_expensive_model", False))
                elif method == "gateway.ping":
                    self.result(request, {})
                elif method == "prompt.submit":
                    self.scenario = SCENARIOS.get(request["params"]["text"])
                    with STATS_LOCK:
                        STATS[fixture_id]["prompts"] += 1
                        STATS[fixture_id]["prompt_model"] = self.model
                    if self.canonical and not params.get("input_id"):
                        self.error(request, 4001, "input_id required")
                    else:
                        self.result(request, {"execution_generation": 3} if self.canonical else {})
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
        if text == "Send after reconnecting" or text not in SCENARIOS:
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
            "type": kind, "session_id": self.stored if self.canonical else self.runtime, "payload": payload or {},
        }})

    def result(self, request, result):
        self.write_json({"jsonrpc": "2.0", "id": request["id"], "result": result})

    def error(self, request, code, message, reason=None):
        error = {"code": code, "message": message}
        if reason:
            error["data"] = {"reason": reason}
        self.write_json({"jsonrpc": "2.0", "id": request["id"], "error": error})

    def change_model(self, request, model, confirmed):
        if model == "example/guarded" and not confirmed:
            self.result(request, {"confirm_required": True, "confirm": "fixture-confirm",
                                  "confirm_message": "This model costs more than your current model."})
        elif model == "example/refused":
            self.error(request, 4001, "This model is disabled for this account.")
        else:
            self.model = model
            with STATS_LOCK:
                state = STATS[self.fixture_id]
                state["mutations"] = state.get("mutations", 0) + 1
                state["mutation_method"] = request["method"]
                key = "created_model" if self.stored == "new-fixture" else "model"
                state[key] = model
            self.result(request, {"model": model, "value": model, "provider": "example"})

    def write_json(self, value):
        self.write_frame(1, json.dumps(value).encode())

    def write_frame(self, opcode, data):
        size = len(data)
        header = bytes([128 | opcode, size]) if size < 126 else bytes([128 | opcode, 126]) + struct.pack("!H", size)
        with self.write_lock:
            self.wfile.write(header + data)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18765), HermesStub).serve_forever()
