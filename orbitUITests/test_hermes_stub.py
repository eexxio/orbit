import base64
import http.client
import json
import socket
import struct
import threading
import unittest
from http.server import ThreadingHTTPServer

from hermes_stub import HermesStub


class FixtureIsolationTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), HermesStub)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.thread.join)
        self.addCleanup(self.server.shutdown)

    def request(self, method, path):
        connection = http.client.HTTPConnection(*self.server.server_address)
        self.addCleanup(connection.close)
        connection.request(method, path)
        response = connection.getresponse()
        data = response.read()
        self.assertIn(response.status, {200, 204})
        return json.loads(data) if data else None

    def connect(self, fixture_id):
        connection = socket.create_connection(self.server.server_address)
        self.addCleanup(connection.close)
        reader = connection.makefile("rb")
        self.addCleanup(reader.close)
        key = base64.b64encode(b"fixture-test-key").decode()
        connection.sendall((f"GET /{fixture_id}/api/ws HTTP/1.1\r\nHost: localhost\r\n"
                            f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n\r\n").encode())
        self.assertIn(b"101", reader.readline())
        while reader.readline() != b"\r\n":
            pass
        self.read_frame(reader)
        return connection, reader

    def read_frame(self, reader):
        header = reader.read(2)
        size = header[1] & 127
        if size == 126:
            size = struct.unpack("!H", reader.read(2))[0]
        return json.loads(reader.read(size))

    def call(self, client, method, params=None):
        connection, reader = client
        payload = json.dumps({"id": 1, "method": method, "params": params or {}}).encode()
        connection.sendall(bytes([129, len(payload)]) + payload)
        return self.read_frame(reader)

    def prompt(self, client, text):
        self.call(client, "prompt.submit", {"text": text})
        return self.read_frame(client[1])["params"]["payload"]

    def test_history_and_counts_stay_independent(self):
        a = self.connect("isolation-a")
        self.call(a, "session.create")
        self.assertEqual(self.prompt(a, "Same prompt")["text"], "Reply 1: Same prompt")
        b = self.connect("isolation-b")
        self.call(b, "session.create")
        self.assertEqual(self.prompt(b, "Same prompt")["text"], "Reply 1: Same prompt")
        self.assertEqual(self.prompt(a, "Same prompt")["text"], "Reply 2: Same prompt")
        before = self.request("GET", "/isolation-a/api/sessions/fixture/messages")
        self.assertEqual(len(before["messages"]), 4)
        self.request("POST", "/isolation-b/fixture/reset")
        self.assertEqual(self.request("GET", "/isolation-b/api/sessions/fixture/messages"), {"messages": []})
        self.assertEqual(self.request("GET", "/isolation-a/api/sessions/fixture/messages"), before)
        self.assertEqual(self.prompt(a, "Same prompt")["text"], "Reply 3: Same prompt")
        self.assertEqual(self.prompt(b, "Same prompt")["text"], "Reply 1: Same prompt")

    def test_failure_counts_stay_independent(self):
        a = self.connect("failure-a")
        self.call(a, "session.create")
        b = self.connect("failure-b")
        self.call(b, "session.create")
        self.assertEqual(self.prompt(a, "Action failure")["status"], "error")
        self.assertEqual(self.prompt(b, "Action failure")["status"], "error")
        self.assertEqual(self.prompt(a, "Action failure")["text"], "Reply 2: Action failure")


if __name__ == "__main__":
    unittest.main()
