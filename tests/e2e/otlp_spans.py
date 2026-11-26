#!/usr/bin/env python3
"""The spans an OTLP sink received, one line each, for tests/e2e/log-trace-ids.sh.

usage: otlp_spans.py <sink dir>

Reads every <sink dir>/trace-*.bin (an ExportTraceServiceRequest, as otlp-http-sink.py and
otlp-grpc-sink.py write them) and prints, per span:
  <trace id> <span id> <parent span id or -> <kind> <service.name> <name>
Needs opentelemetry-proto (the Python OTLP exporter already depends on it).
"""
import glob
import sys

from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest
from opentelemetry.proto.trace.v1.trace_pb2 import Span

for path in sorted(glob.glob(sys.argv[1] + "/trace-*.bin")):
    req = ExportTraceServiceRequest()
    req.ParseFromString(open(path, "rb").read())
    for rs in req.resource_spans:
        service = next((a.value.string_value for a in rs.resource.attributes if a.key == "service.name"), "-")
        for ss in rs.scope_spans:
            for s in ss.spans:
                kind = Span.SpanKind.Name(s.kind).removeprefix("SPAN_KIND_")
                print(s.trace_id.hex(), s.span_id.hex(), s.parent_span_id.hex() or "-", kind, service, s.name)
