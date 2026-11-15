#!/usr/bin/env python3
"""A minimal OTLP/gRPC sink for tests/e2e/python-sigterm-flush.sh.

usage: otlp-grpc-sink.py <out-dir> <port>

Accepts any OTLP Export call (traces, metrics, logs) and answers with an empty, valid response.
Each request body is written to <out-dir>/<signal>-<n>.bin once it has been fully received, so
the test can look for a span's route in what actually arrived. Needs grpcio, which the OTLP/gRPC
exporter already depends on.
"""
import itertools
import os
import sys
import time
from concurrent import futures

import grpc

OUT, PORT = sys.argv[1], int(sys.argv[2])
COUNTER = itertools.count(1)
SIGNALS = {"TraceService": "trace", "MetricsService": "metrics", "LogsService": "logs"}


class Sink(grpc.GenericRpcHandler):
    def service(self, call_details):
        # /opentelemetry.proto.collector.trace.v1.TraceService/Export
        service = call_details.method.split("/")[1].rsplit(".", 1)[-1]
        signal = SIGNALS.get(service, "other")

        def export(request, context):
            path = os.path.join(OUT, f"{signal}-{next(COUNTER)}.bin")
            with open(path + ".tmp", "wb") as f:
                f.write(request)
            os.replace(path + ".tmp", path)
            return b""

        return grpc.unary_unary_rpc_method_handler(export)  # raw bytes in, raw bytes out


server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
server.add_generic_rpc_handlers((Sink(),))
server.add_insecure_port(f"127.0.0.1:{PORT}")
server.start()
print(f"otlp grpc sink on {PORT}", flush=True)
while True:
    time.sleep(3600)
