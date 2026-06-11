//! POST /api/webhook — the URL you register with the game.
//!
//! Responsibilities, in order:
//!   1. Answer the `webhook_verification` handshake (unsigned by design).
//!   2. Verify the HMAC-SHA256 signature over the RAW body bytes.
//!   3. Append the raw payload to a capped Redis stream (the event log).
//!   4. Optionally forward the payload to a dev machine (DEV_FORWARD_URL),
//!      so you never burn the 12/hour webhook-change budget on ngrok URLs.

use replicant_relay::{env_var, verify_signature, Upstash, EVENT_STREAM_KEY, EVENT_STREAM_MAXLEN};
use serde_json::{json, Value};
use vercel_runtime::{run, service_fn, Body, Error, Request, Response, StatusCode};

#[tokio::main]
async fn main() -> Result<(), Error> {
    run(service_fn(handler)).await
}

async fn handler(req: Request) -> Result<Response<Body>, Error> {
    if req.method() != "POST" {
        return respond(StatusCode::METHOD_NOT_ALLOWED, json!({"error": "POST only"}));
    }

    // IMPORTANT: keep a handle on the raw bytes. The signature is computed
    // over exactly what was sent — re-serialized JSON will not match.
    let raw: &[u8] = match req.body() {
        Body::Binary(bytes) => bytes,
        Body::Text(text) => text.as_bytes(),
        Body::Empty => &[],
    };
    let payload: Value = serde_json::from_slice(raw).unwrap_or(Value::Null);

    // 1. Verification handshake. The docs say to skip signature verification
    //    for this type — your code doesn't know the secret yet at registration.
    if payload["type"] == "webhook_verification" {
        return respond(StatusCode::OK, json!({ "challenge": payload["challenge"] }));
    }

    // 2. Signature check.
    let secret = env_var("REPLICANT_WEBHOOK_SECRET")?;
    let signature = req
        .headers()
        .get("x-replicant-space-signature")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if !verify_signature(&secret, raw, signature) {
        return respond(StatusCode::UNAUTHORIZED, json!({"error": "bad signature"}));
    }

    // 3. Append to the durable, capped event log.
    let body_str = std::str::from_utf8(raw).map_err(|_| "webhook body was not utf-8")?;
    let upstash = Upstash::from_env()?;
    let stream_id = upstash
        .command(&[
            "XADD", EVENT_STREAM_KEY, "MAXLEN", "~", EVENT_STREAM_MAXLEN, "*", "body", body_str,
        ])
        .await?;

    // 4. Best-effort dev forwarding. Failures are intentionally swallowed —
    //    a dead laptop must never make the game think your webhook is broken.
    if let Ok(dev_url) = std::env::var("DEV_FORWARD_URL") {
        if !dev_url.is_empty() {
            let _ = reqwest::Client::new()
                .post(&dev_url)
                .header("content-type", "application/json")
                .header("x-replicant-space-signature", signature)
                .body(body_str.to_owned())
                .timeout(std::time::Duration::from_secs(3))
                .send()
                .await;
        }
    }

    respond(StatusCode::OK, json!({ "stored": stream_id }))
}

fn respond(status: StatusCode, body: Value) -> Result<Response<Body>, Error> {
    Ok(Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Body::Text(body.to_string()))?)
}
