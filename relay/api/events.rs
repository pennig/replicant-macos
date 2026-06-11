//! GET /api/events?cursor=<stream-id>&limit=<n> — what the Mac app polls.
//!
//! Cursor semantics: pass the `next_cursor` from the previous page to get
//! everything strictly *after* it (Redis exclusive range, `(id`). Omit the
//! cursor to start from the beginning of the retained log. Polling this
//! endpoint is free — it never touches the game's rate limits.

use http::request::Parts;
use http::StatusCode;
use replicant_relay::{authorize_client, error_id, Upstash, EVENT_STREAM_KEY};
use serde_json::{json, Value};
use vercel_runtime::{run, service_fn, AppState, Error, Request, Response};

#[tokio::main]
async fn main() -> Result<(), Error> {
    run(service_fn(handler)).await
}

/// Runtime-facing shim and ERROR BOUNDARY (see webhook.rs for the pattern).
/// The GET path never reads the body, so `handle` needs only the metadata.
async fn handler(req: Request, state: AppState) -> Result<Response<String>, Error> {
    match handle(req.into_parts().0).await {
        Ok(response) => Ok(response),
        Err(err) => {
            let id = error_id();
            state
                .log_context
                .error(&format!("[{id}] events read failed: {err:#}"));
            Ok(replicant_relay::respond(
                StatusCode::INTERNAL_SERVER_ERROR,
                json!({"error": "internal error", "id": id}),
            )?)
        }
    }
}

async fn handle(parts: Parts) -> anyhow::Result<Response<String>> {
    if parts.method != "GET" {
        return respond(StatusCode::METHOD_NOT_ALLOWED, json!({"error": "GET only"}));
    }

    let auth = parts
        .headers
        .get("authorization")
        .and_then(|v| v.to_str().ok());
    if !authorize_client(auth)? {
        return respond(StatusCode::UNAUTHORIZED, json!({"error": "bad token"}));
    }

    // --- query params ---------------------------------------------------
    let mut client_cursor: Option<String> = None;
    let mut limit: usize = 100;
    if let Some(query) = parts.uri.query() {
        for pair in query.split('&') {
            let mut kv = pair.splitn(2, '=');
            match (kv.next(), kv.next()) {
                (Some("cursor"), Some(v)) if !v.is_empty() => {
                    client_cursor = Some(v.to_string());
                }
                (Some("limit"), Some(v)) => {
                    limit = v.parse().unwrap_or(100);
                }
                _ => {}
            }
        }
    }
    let limit = limit.clamp(1, 500);

    // Exclusive start when a cursor is provided; "-" means "from the start".
    let start = match &client_cursor {
        Some(id) => format!("({id}"),
        None => "-".to_string(),
    };

    // --- read the stream -------------------------------------------------
    let upstash = Upstash::from_env()?;
    let result = upstash
        .command(&[
            "XRANGE",
            EVENT_STREAM_KEY,
            &start,
            "+",
            "COUNT",
            &limit.to_string(),
        ])
        .await?;

    let mut events: Vec<Value> = Vec::new();
    let mut next_cursor = client_cursor.unwrap_or_default();

    if let Value::Array(entries) = result {
        for entry in entries {
            // Each entry: [ "<stream-id>", [ "body", "<raw json>", ... ] ]
            let id = entry
                .get(0)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let mut event_body = Value::Null;
            if let Some(fields) = entry.get(1).and_then(Value::as_array) {
                for chunk in fields.chunks(2) {
                    if chunk.len() == 2 && chunk[0] == "body" {
                        event_body = chunk[1]
                            .as_str()
                            .and_then(|s| serde_json::from_str(s).ok())
                            .unwrap_or(Value::Null);
                    }
                }
            }
            if !id.is_empty() {
                next_cursor = id.clone();
                events.push(json!({ "id": id, "event": event_body }));
            }
        }
    }

    respond(
        StatusCode::OK,
        json!({ "events": events, "next_cursor": next_cursor }),
    )
}

/// Local respond wrapper: same JSON response as the shared helper, plus
/// `cache-control: no-store` so nothing between the relay and the Mac app
/// caches a page of the event log.
fn respond(status: StatusCode, body: Value) -> anyhow::Result<Response<String>> {
    let mut response = replicant_relay::respond(status, body)?;
    response.headers_mut().insert(
        http::header::CACHE_CONTROL,
        http::HeaderValue::from_static("no-store"),
    );
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parts(method: &str, auth: Option<&str>, query: &str) -> Parts {
        let mut builder = http::Request::builder()
            .method(method)
            .uri(format!("/api/events{query}"));
        if let Some(auth) = auth {
            builder = builder.header("authorization", auth);
        }
        builder.body(()).unwrap().into_parts().0
    }

    fn set_token() {
        std::env::set_var("RELAY_CLIENT_TOKEN", "relay-token");
    }

    #[tokio::test]
    async fn missing_or_wrong_token_rejected() {
        set_token();
        let missing = handle(parts("GET", None, "")).await.unwrap();
        assert_eq!(missing.status(), 401);
        let wrong = handle(parts("GET", Some("Bearer nope"), "")).await.unwrap();
        assert_eq!(wrong.status(), 401);
    }

    #[tokio::test]
    async fn wrong_method_rejected() {
        set_token();
        let response = handle(parts("POST", Some("Bearer relay-token"), ""))
            .await
            .unwrap();
        assert_eq!(response.status(), 405);
    }

    /// Full read path against real Upstash; opt-in like the webhook test.
    #[tokio::test]
    #[ignore = "requires UPSTASH_* env vars (performs a real Redis read)"]
    async fn authorized_read_returns_page() {
        set_token();
        let response = handle(parts("GET", Some("Bearer relay-token"), "?limit=5"))
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        assert!(response.body().contains("next_cursor"));
    }
}
