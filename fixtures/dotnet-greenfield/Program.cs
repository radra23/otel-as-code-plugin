// checkout-dotnet — a minimal greenfield ASP.NET Core service (minimal-hosting API).
//
// Pristine app code EXCEPT the one wiring line /otel-instrument tells you to add:
//     builder.Services.AddOtelObservability(builder.Configuration);
// The plugin PRINTS that line rather than writing it (it edits no hand-written file), so in the
// e2e harness it lives here, in app code — the .NET analog of Node's `-r ./tracing.js`. The
// generated OpenTelemetry.cs (which defines the extension) and the OTel package refs are dropped
// in from tests/snapshots/instrument/dotnet by run.sh, assembling the instrumented state
// /otel-instrument would leave behind. The port comes from ASPNETCORE_URLS (set by compose).
using CheckoutApi.Observability;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddOtelObservability(builder.Configuration);

var app = builder.Build();
app.MapGet("/health", () => Results.Json(new { status = "ok" }));
app.MapGet("/pay", () => Results.Json(new { paid = true, orderId = "o1" }));
app.Run();
