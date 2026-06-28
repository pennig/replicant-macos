//! GET /api/stream — SSE endpoint for real-time event delivery.
//!
//! Holds the HTTP connection open, using `XREAD BLOCK` on Upstash to push
//! events the moment they arrive. Sends `: keepalive` comments every ~25 s to
//! prevent proxy/load-balancer timeouts. Clients reconnect with `Last-Event-ID`
//! when Vercel's max function duration is reached (set `maxDuration` in
//! vercel.json to 300 on a Pro plan for the longest possible sessions).

use http::StatusCode;
use http_body_util::StreamBody;
use hyper::body::{Bytes, Frame};
use replicant_relay::{authorize_client, error_id, Upstash, EVENT_STREAM_KEY};
use serde_json::Value;
use tokio::time::{Duration, Instant};
use tokio_stream::wrappers::ReceiverStream;
use vercel_runtime::{run, service_fn, AppState, Error, Request, Response, ResponseBody};

#[tokio::main]
async fn main() -> Result<(), Error> {
    run(service_fn(handler)).await
}

async fn handler(req: Request, state: AppState) -> Result<Response<ResponseBody>, Error> {
    let (parts, _) = req.into_parts();

    if parts.method != "GET" {
        return Ok(json_response(
            StatusCode::METHOD_NOT_ALLOWED,
            r#"{"error":"GET only"}"#,
        ));
    }

    let auth = parts
        .headers
        .get("authorization")
        .and_then(|v| v.to_str().ok());
    match authorize_client(auth) {
        Ok(true) => {}
        Ok(false) => {
            return Ok(json_response(
                StatusCode::UNAUTHORIZED,
                r#"{"error":"bad token"}"#,
            ));
        }
        Err(err) => {
            let id = error_id();
            state
                .log_context
                .error(&format!("[{id}] stream auth error: {err:#}"));
            return Ok(json_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                r#"{"error":"internal error"}"#,
            ));
        }
    }

    // Cursor: Last-Event-ID header takes priority (standard SSE reconnection),
    // then the ?cursor= query param for the initial request.
    let cursor = parts
        .headers
        .get("last-event-id")
        .and_then(|v| v.to_str().ok())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .or_else(|| query_param(parts.uri.query(), "cursor"));

    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Frame<Bytes>, Error>>(32);

    tokio::spawn(async move {
        // XREAD uses the cursor as an exclusive lower bound — no `(` prefix needed.
        // "0" reads from the very beginning of the stream.
        let mut xread_cursor = cursor.unwrap_or_else(|| "0".to_string());

        let upstash = match Upstash::from_env() {
            Ok(u) => u,
            Err(e) => {
                let _ = tx.send(Err(io_err(e))).await;
                return;
            }
        };

        // Tell the client to wait 1 s before reconnecting after a close.
        if tx
            .send(Ok(Frame::data(Bytes::from_static(b"retry: 1000\n\n"))))
            .await
            .is_err()
        {
            return;
        }

        // Close 10 s before Vercel's 300 s hard limit so the connection ends
        // cleanly rather than being force-killed. The client reconnects with
        // Last-Event-ID and resumes from where it left off.
        let deadline = Instant::now() + Duration::from_secs(290);

        loop {
            if tx.is_closed() {
                break;
            }

            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }

            // Clamp the XREAD block to remaining time so we never overshoot
            // the deadline by a full 25 s polling interval.
            let block_ms = remaining.min(Duration::from_secs(25)).as_millis() as u64;

            let result = upstash
                .command(&[
                    "XREAD",
                    "BLOCK",
                    &block_ms.to_string(),
                    "COUNT",
                    "100",
                    "STREAMS",
                    EVENT_STREAM_KEY,
                    &xread_cursor,
                ])
                .await;

            match result {
                Err(e) => {
                    let _ = tx.send(Err(io_err(e))).await;
                    break;
                }
                Ok(Value::Null) => {
                    // Timeout — no new events. Send keepalive comment to prevent
                    // the connection being dropped by intermediaries.
                    if tx
                        .send(Ok(Frame::data(Bytes::from_static(b": keepalive\n\n"))))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Ok(result) => {
                    for (id, body_str) in extract_entries(&result) {
                        let line = format!("id: {id}\ndata: {body_str}\n\n");
                        xread_cursor = id;
                        if tx.send(Ok(Frame::data(Bytes::from(line)))).await.is_err() {
                            return;
                        }
                    }
                }
            }
        }
    });

    let body = ResponseBody::from(StreamBody::new(ReceiverStream::new(rx)));

    Ok(Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "text/event-stream")
        .header("cache-control", "no-store")
        .header("x-accel-buffering", "no")
        .body(body)
        .map_err(|e| Box::new(e) as Error)?)
}

/// Extract `(stream_id, body_json_string)` pairs from an XREAD result.
///
/// XREAD shape: `[[stream_name, [[id, [field, value, ...]], ...]], ...]`
fn extract_entries(result: &Value) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let Some(streams) = result.as_array() else {
        return out;
    };
    for stream_entry in streams {
        let Some(pair) = stream_entry.as_array() else {
            continue;
        };
        let Some(entries) = pair.get(1).and_then(Value::as_array) else {
            continue;
        };
        for entry in entries {
            let Some(parts) = entry.as_array() else {
                continue;
            };
            let id = parts
                .first()
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            if id.is_empty() {
                continue;
            }
            let mut body_str = "null".to_string();
            if let Some(fields) = parts.get(1).and_then(Value::as_array) {
                for chunk in fields.chunks(2) {
                    if chunk.len() == 2 && chunk[0] == "body" {
                        body_str = chunk[1].as_str().unwrap_or("null").to_string();
                    }
                }
            }
            out.push((id, body_str));
        }
    }
    out
}

fn query_param(query: Option<&str>, name: &str) -> Option<String> {
    query?.split('&').find_map(|pair| {
        let mut kv = pair.splitn(2, '=');
        match (kv.next(), kv.next()) {
            (Some(k), Some(v)) if k == name && !v.is_empty() => Some(v.to_string()),
            _ => None,
        }
    })
}

/// Bridge `anyhow::Error` → `Box<dyn std::error::Error + Send + Sync>`.
/// anyhow::Error does not directly implement std::error::Error, so we route
/// through std::io::Error which does.
fn io_err(e: anyhow::Error) -> Error {
    Box::new(std::io::Error::other(format!("{e:#}")))
}

fn json_response(status: StatusCode, body: &'static str) -> Response<ResponseBody> {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(ResponseBody::from(body))
        .unwrap()
}
