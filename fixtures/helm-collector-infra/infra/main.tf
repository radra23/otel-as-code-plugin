terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

resource "helm_release" "otel_agent" {
  name       = "otel-agent"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  namespace  = "observability"

  values = [
    yamlencode({
      mode = "daemonset"
      image = {
        repository = "otel/opentelemetry-collector-contrib"
      }
      config = {
        processors = {
          batch         = {}
          memory_limiter = {
            check_interval = "1s"
            limit_mib      = 512
          }
        }
        exporters = {
          otlp = {
            endpoint = "otel-gateway.observability.svc:4317"
          }
        }
      }
    })
  ]
}
