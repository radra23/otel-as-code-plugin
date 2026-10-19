// svc — a minimal ASP.NET Core API in the layout most real .NET repos use: the solution file sits
// at the repository root and the project one level down, so the scanner's rootDir (the solution
// folder) is NOT the directory the project compiles from (#182).
//
// Pristine app code EXCEPT the one wiring line /otel-instrument tells you to add (the plugin
// prints it rather than writing it):
//     builder.Services.AddOtelObservability(builder.Configuration);
// OpenTelemetry.cs and the OTel package references are not here: the harness adds them where the
// generator says they go, which is beside this file.
using CheckoutApi.Observability;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddOtelObservability(builder.Configuration);

var app = builder.Build();
app.MapGet("/health", () => Results.Json(new { status = "ok" }));
app.Run();
