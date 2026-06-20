// VIOLATION FILE — intentionally non-conformant for testing
// Violation 1: service.name set as span attribute (must be resource attribute)
// Violation 2: http.method used (deprecated; must be http.request.method)
// Violation 3: custom attribute 'orderId' has no reverse-DNS namespace prefix

const { NodeTracerProvider } = require('@opentelemetry/sdk-trace-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');
const { SimpleSpanProcessor } = require('@opentelemetry/sdk-trace-base');
const { trace } = require('@opentelemetry/api');

const provider = new NodeTracerProvider();
provider.addSpanProcessor(new SimpleSpanProcessor(new OTLPTraceExporter()));
provider.register();

const tracer = trace.getTracer('order-processor');

function traceOrder(orderId, method) {
  const span = tracer.startSpan('process-order');
  // Violation 1: service.name as span attribute (should be resource attribute)
  span.setAttribute('service.name', 'order-processor');
  // Violation 2: http.method is deprecated
  span.setAttribute('http.method', method);
  // Violation 3: no namespace prefix on custom attribute
  span.setAttribute('orderId', orderId);
  span.end();
}

module.exports = { traceOrder };
