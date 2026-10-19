#!/usr/bin/env python3
"""A deliberately slow OTLP/HTTP sink for tests/e2e/nextjs-sigterm-flush.sh.

usage: slow-otlp-sink.py <log-file> <port> [delay-seconds]

Appends one line per POST ("<path> <bytes>") AFTER the delay, so a request that is still in
flight when the process that sent it exits is not counted. Handles chunked bodies (the Node OTLP
exporter sends without Content-Length).
"""
import http.server
import sys
import time

LOG, PORT = sys.argv[1], int(sys.argv[2])
DELAY = float(sys.argv[3]) if len(sys.argv) > 3 else 0.2


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        if self.headers.get("transfer-encoding", "").lower() == "chunked":
            size = 0
            while True:
                n = int(self.rfile.readline().strip() or b"0", 16)
                if n == 0:
                    self.rfile.readline()
                    break
                size += len(self.rfile.read(n))
                self.rfile.readline()
        else:
            size = len(self.rfile.read(int(self.headers.get("content-length", 0))))
        time.sleep(DELAY)
        with open(LOG, "a") as f:
            f.write(f"{self.path} {size}\n")
        body = b"{}"
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
