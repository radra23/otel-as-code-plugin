var builder = WebApplication.CreateBuilder(args);

var app = builder.Build();
app.MapGet("/health", () => Results.Json(new { status = "ok" }));
app.Run();
