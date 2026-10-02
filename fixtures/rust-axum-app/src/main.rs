use axum::{extract::Path, routing::get, Json, Router};
use serde_json::{json, Value};

async fn product(Path(id): Path<u64>) -> Json<Value> {
    Json(json!({ "id": id }))
}

#[tokio::main]
async fn main() {
    let app = Router::new()
        .route("/products/{id}", get(product))
        .route("/healthz", get(|| async { "ok" }));
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
