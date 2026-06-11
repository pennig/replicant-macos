//! GET /api/events?cursor=<stream-id>&limit=<n> — what the Mac app polls.
//!
//! Cursor semantics: pass the `next_cursor` from the previous page to get
//! everything strictly *after* it (Redis exclusive range, `(id`). Omit the
//! cursor to start from the beginning of the retained log. Polling this
//! endpoint is free — it never touches the game's rate limits.

use http::StatusCode;
use replicant_relay::{authorize_client, Upstash, EVENT_STREAM_KEY};
use serde_json::{json, Value};
use vercel_runtime::{run, service_fn, Error, Request, Response};

#[tokio::main]
async fn main() -> Result<(), Error> {
    run(service_fn(handler)).await
}

async fn handler(req: Request) -> Result<Response<String>, Error> {
    if req.method() != "GET" {
        return respond(StatusCode::METHOD_NOT_ALLOWED, json!({"error": "GET only"}));
    }

    let auth = req
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok());
    if !authorize_client(auth)? {
        return respond(StatusCode::UNAUTHORIZED, json!({"error": "bad token"}));
    }

    // --- query params ---------------------------------------------------
    let mut client_cursor: Option<String> = None;
    let mut limit: usize = 100;
    if let Some(query) = req.uri().query() {
        for pair in query.split('&') {
            let mut parts = pair.splitn(2, '=');
            match (parts.next(), parts.next()) {
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

fn respond(status: StatusCode, body: Value) -> Result<Response<String>, Error> {
    Ok(Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .header("cache-control", "no-store")
        .body(body.to_string())?)
}
