resource "kubernetes_config_map" "otel_config" {
  metadata {
    name = "otel-config"
  }

  data = {
    OTEL_EXPORTER_OTLP_TRACES_ENDPOINT  = "http://collector.observability.svc:4317"
    OTEL_EXPORTER_OTLP_METRICS_ENDPOINT = "http://collector.observability.svc:4317"
    OTEL_EXPORTER_OTLP_LOGS_ENDPOINT    = "http://collector.observability.svc:4317"
  }
}
