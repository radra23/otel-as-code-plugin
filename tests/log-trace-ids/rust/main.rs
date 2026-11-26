// tests/e2e/log-trace-ids.sh (#279): an axum service behind the golden telemetry.rs, wired the
// way /otel-instrument prints it. While GET /orders/{id} is handled it logs one event in the tower
// layer's request span and one inside a `tracing` span of its own; it logs one more at start-up,
// outside any span. The e2e shortens the batch delays (OTEL_BSP_/OTEL_BLRP_SCHEDULE_DELAY) and
// waits for an export before it stops the process: the golden's tokio has no `signal` feature.
mod telemetry;

use axum::{extract::Path, routing::get, Router};

async fn order(Path(id): Path<u64>) -> &'static str {
    tracing::info!(order_id = id, "rust order line");
    tracing::info_span!("charge").in_scope(|| tracing::info!("rust charge line"));
    "ok"
}

#[tokio::main]
async fn main() {
    let _otel = telemetry::init();
    tracing::info!("rust startup line");
    let app = Router::new()
        .route("/orders/{id}", get(order))
        .route("/health", get(|| async { "ok" }))
        .layer(opentelemetry_instrumentation_tower::http::server::Layer::new());
    let port = std::env::var("PORT").unwrap_or_else(|_| "8974".into());
    let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{port}")).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
