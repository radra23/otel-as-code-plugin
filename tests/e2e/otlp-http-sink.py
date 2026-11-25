#!/usr/bin/env python3
"""A minimal OTLP/HTTP sink for tests/e2e/log-trace-ids.sh (the Ruby exporter speaks OTLP/HTTP).

usage: otlp-http-sink.py <out-dir> <port>

Accepts any POST to /v1/traces, /v1/metrics or /v1/logs and answers 200 with an empty body,
which an OTLP/HTTP exporter reads as success. Each request body is written to
<out-dir>/<signal>-<n>.bin, as otlp-grpc-sink.py does, so a test can look for a trace ID's 16
raw bytes in what actually arrived. Standard library only.
"""
import http.server
import itertools
import os
import sys

OUT, PORT = sys.argv[1], int(sys.argv[2])
COUNTER = itertools.count(1)
SIGNALS = {"/v1/traces": "trace", "/v1/metrics": "metrics", "/v1/logs": "logs"}


class Sink(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        signal = SIGNALS.get(self.path, "other")
        with open(os.path.join(OUT, f"{signal}-{next(COUNTER)}.bin"), "wb") as f:
            f.write(body)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-protobuf")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Sink).serve_forever()
