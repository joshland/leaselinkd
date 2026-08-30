#!/usr/bin/env python3
import http.server
import json
import os
import sys
import time

port_file, log_file = sys.argv[1:]

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_):
        pass

    def _reply(self, payload):
        delay = float(os.environ.get("OPNSENSE_DELAY_SECONDS", "0"))
        if delay:
            time.sleep(delay)
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass

    def _record(self, body=""):
        with open(log_file, "a", encoding="utf-8") as out:
            out.write(f"{self.command} {self.path} {self.headers.get('Authorization', '')} peer={self.client_address[1]} body={body}\n")

    def do_GET(self):
        self._record()
        self._reply({"rows": []} if self.path.endswith("search_host_override") else {"status": "ok"})

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(size).decode("utf-8", errors="replace")
        self._record(body)
        self._reply({"uuid": "override-uuid"} if self.path.endswith("add_host_override") else {})

server = http.server.ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("OPNSENSE_BIND_PORT", "0"))), Handler)
with open(port_file, "w", encoding="utf-8") as out:
    out.write(str(server.server_port))
server.serve_forever()
