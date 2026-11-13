import json
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

mode = sys.argv[1]
port = int(sys.argv[2])
log_path = sys.argv[3]
lock = threading.Lock()

CONFIG = {
    "schema": 1,
    "telemetry": {"enabled": True, "interval_s": 300},
    "reports": {"enabled": True, "screenshots": True},
    "client_ok": True,
    "message": None,
}

DIAGNOSTICS = {"enabled": True, "perf": True, "interval_s": 600, "perf_interval_s": 1800, "sample_pct": 100}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def record(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        entry = {"t": round(time.time(), 3), "m": self.command, "p": self.path}
        if mode == "diagnostics" and self.path.startswith("/v1/diagnostics") and body:
            entry["b"] = json.loads(body)
        with lock, open(log_path, "a") as log:
            log.write(json.dumps(entry) + "\n")
        return entry.get("b")

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def hang(self):
        time.sleep(3600)

    def handle_any(self):
        batch = self.record()
        if mode == "hang":
            self.hang()
            return
        if mode == "diagnostics":
            if self.path.startswith("/v1/config"):
                self.reply(200, dict(CONFIG, diagnostics=DIAGNOSTICS))
            elif self.path.startswith("/v1/installs/me"):
                self.reply(204, {})
            elif self.path.startswith("/v1/installs"):
                self.reply(201, {"install_id": "x", "status": "quarantined"})
            elif self.path.startswith("/v1/telemetry"):
                self.reply(202, {"accepted": 1, "next_after_s": 600})
            elif self.path.startswith("/v1/diagnostics"):
                events = len((batch or {}).get("events", []))
                perf = len((batch or {}).get("perf", []))
                self.reply(202, {"accepted_events": events, "accepted_perf": perf, "next_after_s": 600})
            else:
                self.reply(404, {"code": "not_found"})
            return
        if self.path.startswith("/v1/config"):
            self.reply(200, CONFIG)
        elif self.path.startswith("/v1/installs"):
            self.reply(201, {"install_id": "x", "status": "quarantined"})
        elif self.path.startswith("/v1/telemetry"):
            self.hang()
        else:
            self.reply(404, {"code": "not_found"})

    do_GET = handle_any
    do_POST = handle_any
    do_PUT = handle_any
    do_DELETE = handle_any


class Server(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


Server(("127.0.0.1", port), Handler).serve_forever()
