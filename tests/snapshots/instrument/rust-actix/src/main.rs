mod telemetry;

use actix_web::{get, web, App, HttpServer, Responder};
use serde_json::json;

#[get("/products/{id}")]
async fn product(id: web::Path<u64>) -> impl Responder {
    web::Json(json!({ "id": id.into_inner() }))
}

#[get("/healthz")]
async fn healthz() -> impl Responder {
    "ok"
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let _otel = telemetry::init();
    HttpServer::new(|| {
        App::new()
            .wrap(opentelemetry_instrumentation_actix_web::RequestTracing::new())
            .wrap(opentelemetry_instrumentation_actix_web::RequestMetrics::default())
            .service(product)
            .service(healthz)
    })
    .bind("0.0.0.0:8080")?
    .run()
    .await
}
