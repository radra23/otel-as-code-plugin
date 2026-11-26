#!/usr/bin/env python3
"""The log records an OTLP sink received, one line each, for tests/e2e/log-trace-ids.sh.

usage: otlp_logs.py <sink dir>

Reads every <sink dir>/logs-*.bin (an ExportLogsServiceRequest, as otlp-http-sink.py writes them)
and prints, per record:
  <trace id or -> <span id or -> <service.name> <body>
Needs opentelemetry-proto (the Python OTLP exporter already depends on it).
"""
import glob
import sys

from opentelemetry.proto.collector.logs.v1.logs_service_pb2 import ExportLogsServiceRequest

for path in sorted(glob.glob(sys.argv[1] + "/logs-*.bin")):
    req = ExportLogsServiceRequest()
    req.ParseFromString(open(path, "rb").read())
    for rl in req.resource_logs:
        service = next((a.value.string_value for a in rl.resource.attributes if a.key == "service.name"), "-")
        for sl in rl.scope_logs:
            for r in sl.log_records:
                print(r.trace_id.hex() or "-", r.span_id.hex() or "-", service, r.body.string_value)
