import { logs, SeverityNumber } from "@opentelemetry/api-logs";

export function logException(err: unknown) {
  logs.getLogger("portal-api").emit({
    severityNumber: SeverityNumber.ERROR,
    body: String(err),
    attributes: { "exception.type": err instanceof Error ? err.name : "unknown" },
  });
}
