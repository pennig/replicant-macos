//! Shared plumbing for the relay functions.

use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;

/// Read a required environment variable, with a useful error message.
pub fn env_var(name: &str) -> Result<String> {
    std::env::var(name).map_err(|_| anyhow!("missing env var: {name}"))
}

/// Verify the `X-Replicant-Space-Signature` header.
///
/// Per the game docs: HMAC-SHA256 over the *raw request body bytes*, keyed
/// with the one-time `webhook_secret`, hex-encoded lowercase. We hex-decode
/// the header and use `verify_slice`, which is a constant-time comparison.
pub fn verify_signature(secret: &str, raw_body: &[u8], signature_hex: &str) -> bool {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;

    let Ok(signature) = hex::decode(signature_hex.trim()) else {
        return false;
    };
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(secret.as_bytes()) else {
        return false;
    };
    mac.update(raw_body);
    mac.verify_slice(&signature).is_ok()
}

/// Constant-time equality for the relay's own client token.
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Check the `Authorization: Bearer <RELAY_CLIENT_TOKEN>` header on requests
/// from your own clients (the Mac app).
pub fn authorize_client(auth_header: Option<&str>) -> Result<bool> {
    let expected = format!("Bearer {}", env_var("RELAY_CLIENT_TOKEN")?);
    Ok(matches!(
        auth_header,
        Some(actual) if constant_time_eq(actual.as_bytes(), expected.as_bytes())
    ))
}

/// Minimal Upstash Redis REST client. Serverless-friendly: plain HTTPS,
/// no connection pools to keep warm. Each command is a POST whose JSON body
/// is the command as an array of strings, e.g. ["XADD", "events", ...].
pub struct Upstash {
    base: String,
    token: String,
    http: reqwest::Client,
}

impl Upstash {
    pub fn from_env() -> Result<Self> {
        Ok(Self {
            base: env_var("KV_REST_API_URL")?,
            token: env_var("KV_REST_API_TOKEN")?,
            http: reqwest::Client::new(),
        })
    }

    pub async fn command(&self, cmd: &[&str]) -> Result<Value> {
        let name = cmd.first().copied().unwrap_or("?");
        let response = self
            .http
            .post(&self.base)
            .bearer_auth(&self.token)
            .json(&cmd)
            .send()
            .await
            .with_context(|| format!("sending {name} to Upstash"))?;
        let value: Value = response
            .json()
            .await
            .with_context(|| format!("parsing the Upstash response to {name}"))?;
        if let Some(err) = value.get("error") {
            bail!("Upstash rejected {name}: {err}");
        }
        Ok(value.get("result").cloned().unwrap_or(Value::Null))
    }
}

/// Build a JSON response. The error type is anyhow so call sites inside
/// `handle(...)` compose with `?` and pick up context naturally.
pub fn respond(status: http::StatusCode, body: Value) -> Result<http::Response<String>> {
    http::Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(body.to_string())
        .context("building response")
}

/// Short correlation id pairing a sanitized 500 with its log line.
/// Not cryptographic — just unique enough to grep for.
pub fn error_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{:08x}", nanos as u32)
}

pub const EVENT_STREAM_KEY: &str = "replicant:events";
/// Approximate cap on retained events (XADD MAXLEN ~).
pub const EVENT_STREAM_MAXLEN: &str = "150000";
