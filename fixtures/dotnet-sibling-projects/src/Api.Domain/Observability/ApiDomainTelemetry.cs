using System.Diagnostics;

namespace Api.Domain.Observability;

public static class ApiDomainTelemetry
{
    public static readonly ActivitySource Source = new ActivitySource("Api.Domain");
}
