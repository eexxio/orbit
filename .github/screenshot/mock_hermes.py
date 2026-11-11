#!/usr/bin/env python3
"""A throwaway stand-in for a Hermes Agent dashboard, used only to feed the app
enough real-shaped JSON to render screenshots in CI.

It speaks the subset of the REST API orbit reads on launch:
  GET /                                  -> the page carrying __HERMES_SESSION_TOKEN__
  GET /api/status                        -> {auth_required: false, version}
  GET /api/profiles/active               -> {current}
  GET /api/sessions                      -> {sessions: [{id, title, last_active}]}
  GET /api/sessions/{key}/messages       -> {messages: [{id, role, content}]}

The app also opens one gateway socket per chat; the chats list never does, so
this mock has no WebSocket support on purpose. Keep it that way — if a future
change needs the socket here, add it deliberately.
"""

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

TOKEN = "probe-session-token"

SESSIONS = [
    ("s1", "Refactor the auth middleware", 12),
    ("s2", "Why is the release build failing?", 95),
    ("s3", "Kickoff notes for the dashboard rework", 260),
    ("s4", "Summarize the pull request review", 900),
    ("s5", "Ski trip 2027: lodging shortlist", 2400),
    ("s6", "Draft the migration plan", 7300),
    ("s7", "Compare two SIMD approaches", 21600),
    ("s8", "Rename everything to orbit", 86400),
]

PAGE = """<!doctype html>
<html><head><title>Hermes dashboard</title></head>
<body><h1>Hermes dashboard</h1>
<script>window.__HERMES_SESSION_TOKEN__ = "%s";</script>
</body></html>
""" % TOKEN


def messages_for(key):
    return {
        "messages": [
            {"id": 2, "role": "assistant", "content": "Here is what I found: three failing tests, all in the auth middleware."},
            {"id": 1, "role": "user", "content": "What broke in the last build?"},
        ],
        "session": key,
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"

        if path == "/api/status":
            self.send_json({"auth_required": False, "version": "0.11.0", "profile": "default"})
        elif path == "/":
            self.send_bytes(PAGE.encode(), "text/html; charset=utf-8")
        elif path == "/api/profiles/active":
            self.send_json({"current": "default"})
        elif path == "/api/sessions":
            now = time.time()
            self.send_json({"sessions": [
                {"id": key, "title": title, "last_active": now - ago}
                for key, title, ago in SESSIONS
            ]})
        elif path.startswith("/api/sessions/") and path.endswith("/messages"):
            self.send_json(messages_for(path.split("/")[3]))
        else:
            self.send_json({"detail": "not found"}, status=404)

    def do_POST(self):  # noqa: N802
        self.send_json({"ok": True})

    def do_PUT(self):  # noqa: N802
        self.send_json({"ok": True})

    def send_json(self, payload, status=200):
        self.send_bytes(json.dumps(payload).encode(), "application/json", status)

    def send_bytes(self, body, content_type, status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002
        print("mock %s" % (format % args), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
