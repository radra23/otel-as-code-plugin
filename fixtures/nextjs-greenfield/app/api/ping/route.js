// Load target (GET /api/ping). Once instrumentation.js registers a tracer provider, Next.js's
// built-in tracing emits a server span for this route handler — that span is what the harness
// asserts landed in Jaeger with the correct service.* resource attributes.
export const dynamic = "force-dynamic";

export function GET() {
  return Response.json({ pong: true });
}
