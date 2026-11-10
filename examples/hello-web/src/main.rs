// A tokio + axum web service served by IBM i (PASE): GET /hello
// Run: . /QOpenSys/opt/rust/rustenv.sh && cargo run --release   (PORT=3080 by default)
use axum::{routing::get, Json, Router};
use serde_json::{json, Value};

async fn hello() -> Json<Value> {
    Json(json!({
        "message": "Hello from Rust on IBM i",
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "pid": std::process::id()
    }))
}

#[tokio::main]
async fn main() {
    let app = Router::new().route("/hello", get(hello));
    let port = std::env::var("PORT").unwrap_or_else(|_| "3080".into());
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}")).await.unwrap();
    println!("hello-web listening on {port}");
    axum::serve(listener, app).await.unwrap();
}
