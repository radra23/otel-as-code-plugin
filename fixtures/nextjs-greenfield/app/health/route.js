// Readiness endpoint (GET /health) — the e2e harness polls this before driving load.
export const dynamic = "force-dynamic";

export function GET() {
  return Response.json({ status: "ok" });
}
