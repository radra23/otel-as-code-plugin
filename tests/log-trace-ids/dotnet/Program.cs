// tests/e2e/log-trace-ids.sh (#279): an ASP.NET Core minimal API that logs one line through
// ILogger while POST /pay is handled. The e2e drops in the golden OpenTelemetry.cs and csproj
// (the state /otel-instrument leaves) and writes the app's appsettings.json; the one line below
// that is not the app's own is the wiring line /otel-instrument prints.
using CheckoutApi.Observability;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddOtelObservability(builder.Configuration);

var app = builder.Build();
app.MapGet("/health", () => Results.Json(new { status = "ok" }));
app.MapPost("/pay", (ILogger<Program> log) =>
{
    log.LogInformation("dotnet pay line orderId={OrderId}", "o1");
    return Results.Json(new { paid = true });
});
app.Run();
