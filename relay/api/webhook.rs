//! POST /api/webhook — the URL you register with the game.
//!
//! Responsibilities, in order:
//!   1. Answer the `webhook_verification` handshake (unsigned by design).
//!   2. Verify the HMAC-SHA256 signature over the RAW body bytes.
//!   3. Append the raw payload to a capped Redis stream (the event log).
//!   4. Optionally forward the payload to a dev machine (DEV_FORWARD_URL),
//!      so you never burn the 12/hour webhook-change budget on ngrok URLs.

use anyhow::Context;
use http::request::Parts;
use http::StatusCode;
use http_body_util::BodyExt;
use replicant_relay::{
    env_var, error_id, respond, verify_signature, Upstash, EVENT_STREAM_KEY, EVENT_STREAM_MAXLEN,
};
use serde_json::{json, Value};
use vercel_runtime::{run, service_fn, AppState, Error, LogContext, Request, Response};

#[tokio::main]
async fn main() -> Result<(), Error> {
    run(service_fn(handler)).await
}

/// Runtime-facing shim and ERROR BOUNDARY.
///
/// hyper's `Incoming` body can only be produced by a live connection, so
/// the shim stays thin (split, collect, delegate to the testable `handle`).
/// Any error from `handle` is logged HERE, once, with its full anyhow
/// context chain and a correlation id — and crosses the trust boundary
/// redacted: callers see only `{"error": "internal error", "id": ...}`.
async fn handler(req: Request, state: AppState) -> Result<Response<String>, Error> {
    let (parts, body) = req.into_parts();
    let outcome = async {
        let raw = body
            .collect()
            .await
            .context("collecting request body")?
            .to_bytes();
        handle(parts, &raw, &state.log_context).await
    }
    .await;

    match outcome {
        Ok(response) => Ok(response),
        Err(err) => {
            let id = error_id();
            state
                .log_context
                .error(&format!("[{id}] webhook failed: {err:#}"));
            Ok(respond(
                StatusCode::INTERNAL_SERVER_ERROR,
                json!({"error": "internal error", "id": id}),
            )?)
        }
    }
}

async fn handle(parts: Parts, raw: &[u8], log: &LogContext) -> anyhow::Result<Response<String>> {
    if parts.method != "POST" {
        return respond(StatusCode::METHOD_NOT_ALLOWED, json!({"error": "POST only"}));
    }

    // IMPORTANT: `raw` is the body exactly as sent. The signature is
    // computed over these bytes — re-serialized JSON will not match.
    let payload: Value = serde_json::from_slice(raw).unwrap_or(Value::Null);

    // 1. Verification handshake. The docs say to skip signature verification
    //    for this type — your code doesn't know the secret yet at registration.
    if payload["type"] == "webhook_verification" {
        return respond(StatusCode::OK, json!({ "challenge": payload["challenge"] }));
    }

    // 2. Signature check.
    let secret = env_var("REPLICANT_WEBHOOK_SECRET")?;
    let signature = parts
        .headers
        .get("x-replicant-space-signature")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if !verify_signature(&secret, raw, signature) {
        return respond(StatusCode::UNAUTHORIZED, json!({"error": "bad signature"}));
    }

    // 3. Append to the durable, capped event log.
    let body_str = std::str::from_utf8(raw).context("webhook body was not utf-8")?;
    let upstash = Upstash::from_env().context("configuring the Upstash client")?;
    let stream_id = upstash
        .command(&[
            "XADD", EVENT_STREAM_KEY, "MAXLEN", "~", EVENT_STREAM_MAXLEN, "*", "body", body_str,
        ])
        .await
        .context("appending the event to the log")?;

    let kind = payload["event_type"]
        .as_str()
        .or_else(|| payload["type"].as_str())
        .unwrap_or("?");
    log.info(&format!("stored {kind} as {stream_id}"));

    // 4. Best-effort dev forwarding. Failures are logged but never propagate —
    //    a dead laptop must never make the game think your webhook is broken.
    if let Ok(dev_url) = std::env::var("DEV_FORWARD_URL") {
        if !dev_url.is_empty() {
            let forward = reqwest::Client::new()
                .post(&dev_url)
                .header("content-type", "application/json")
                .header("x-replicant-space-signature", signature)
                .body(body_str.to_owned())
                .timeout(std::time::Duration::from_secs(3))
                .send()
                .await;
            if let Err(err) = forward {
                log.warn(&format!("dev forward failed (ignored): {err}"));
            }
        }
    }

    respond(StatusCode::OK, json!({ "stored": stream_id }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use hmac::Mac;

    fn parts(method: &str, signature: Option<&str>) -> Parts {
        let mut builder = http::Request::builder().method(method).uri("/api/webhook");
        if let Some(signature) = signature {
            builder = builder.header("x-replicant-space-signature", signature);
        }
        builder.body(()).unwrap().into_parts().0
    }

    fn log() -> LogContext {
        LogContext::new(None, None, None)
    }

    fn sign(secret: &str, body: &[u8]) -> String {
        let mut mac = hmac::Hmac::<sha2::Sha256>::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(body);
        hex::encode(mac.finalize().into_bytes())
    }

    fn set_secret() {
        std::env::set_var("REPLICANT_WEBHOOK_SECRET", "whsec_test");
    }

    #[tokio::test]
    async fn handshake_echoes_challenge_unsigned() {
        set_secret();
        let body = br#"{"type":"webhook_verification","challenge":"abc123"}"#;
        let response = handle(parts("POST", None), body, &log()).await.unwrap();
        assert_eq!(response.status(), 200);
        assert!(response.body().contains("abc123"));
    }

    #[tokio::test]
    async fn bad_or_missing_signature_rejected() {
        set_secret();
        let body = br#"{"type":"event","event_type":"travel_arrived"}"#;
        let bad = handle(parts("POST", Some("deadbeef")), body, &log())
            .await
            .unwrap();
        assert_eq!(bad.status(), 401);
        let missing = handle(parts("POST", None), body, &log()).await.unwrap();
        assert_eq!(missing.status(), 401);
        // Same payload re-serialized with different whitespace must fail too.
        let signature = sign("whsec_test", body);
        let reserialized = br#"{"type": "event", "event_type": "travel_arrived"}"#;
        let mismatched = handle(parts("POST", Some(&signature)), reserialized, &log())
            .await
            .unwrap();
        assert_eq!(mismatched.status(), 401);
    }

    #[tokio::test]
    async fn wrong_method_rejected() {
        set_secret();
        let response = handle(parts("GET", None), b"", &log()).await.unwrap();
        assert_eq!(response.status(), 405);
    }

    /// Full happy path including the Upstash write. Hits the network, so
    /// it's opt-in:  UPSTASH_REDIS_REST_URL=... UPSTASH_REDIS_REST_TOKEN=... \
    ///               cargo test -- --include-ignored
    #[tokio::test]
    #[ignore = "requires UPSTASH_* env vars (performs a real Redis write)"]
    async fn valid_signature_stores_event() {
        set_secret();
        std::env::remove_var("DEV_FORWARD_URL");
        let body = br#"{"type":"event","event_type":"travel_arrived"}"#;
        let signature = sign("whsec_test", body);
        let response = handle(parts("POST", Some(&signature)), body, &log())
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        assert!(response.body().contains("stored"));
    }
}
