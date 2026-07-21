> **🪦 DECOMMISSIONED (2026-07-19).** This relay is no longer used by anything.
> Backend v2.3.0 shipped a first-party SSE endpoint (`GET /v1/events/stream`)
> and the Mac app now consumes it directly (`app/Modules/API/Sources/EventStream/`);
> the app has zero references to this service, and the deployment can be torn
> down whenever. The README below is preserved as-built for the record.

# replicant-relay

Rust middleware for [replicant.space](https://replicant.space), deployed as
Vercel Functions (official Rust runtime, public beta since Dec 2025).

Two functions:

| Route | What it does |
| --- | --- |
| `POST /api/webhook` | Receives signed game webhooks. Handles the verification handshake, verifies HMAC-SHA256 over raw bytes, appends to a capped Redis stream, optionally forwards to a dev machine. |
| `GET /api/events` | Cursor-based event log reads for your own clients (the Mac app). Auth via `RELAY_CLIENT_TOKEN` bearer token. Free to poll — never touches the game's rate limits. |

## Architecture

```
game ──signed webhook──▶ /api/webhook ──XADD──▶ Upstash Redis stream (capped ~10k)
                                        │
                                        └──(optional)──▶ DEV_FORWARD_URL
Mac app ──Bearer RELAY_CLIENT_TOKEN──▶ /api/events?cursor=...  (poll, cheap)
```

The stream is an append-only log with per-consumer cursors, so adding more
consumers later (dashboard, automation runner, APNs pusher) requires no schema
change — each consumer just keeps its own cursor.

## Environment variables

| Name | Purpose |
| --- | --- |
| `REPLICANT_WEBHOOK_SECRET` | One-time secret from webhook registration. HMAC key. |
| `UPSTASH_REDIS_REST_URL` | From the Upstash console (or Vercel Marketplace integration). |
| `UPSTASH_REDIS_REST_TOKEN` | Ditto. |
| `RELAY_CLIENT_TOKEN` | A token you mint yourself (`openssl rand -hex 32`). Shared with the Mac app. |
| `DEV_FORWARD_URL` | Optional. e.g. an ngrok URL. Relay mirrors verified payloads here so you never re-register the webhook during development (limit: 12 changes/hour). |

## Deploy order (matters!)

1. Create an Upstash Redis database (the Vercel Marketplace integration sets
   the two env vars for you). Set `RELAY_CLIENT_TOKEN` too.
2. Set a placeholder `REPLICANT_WEBHOOK_SECRET` (any string) and deploy:
   `vercel --prod`. The relay must be live **before** registration, because
   the game POSTs a `webhook_verification` challenge during registration and
   the relay must echo it back. (The handshake is unsigned, so the placeholder
   secret is fine at this stage.)
3. Register: `REPLICANT_API_KEY=... ./scripts/register-webhook.sh https://<your-app>.vercel.app/api/webhook`
4. Store the real `webhook_secret` it prints (shown once, ever) and redeploy.

## Local dev

`vercel dev` works with the Rust runtime (needs rustup-installed cargo).
But for webhook traffic, prefer `DEV_FORWARD_URL` pointed at an ngrok tunnel —
production stays the registered receiver and mirrors everything to you.

## Notes

- Signature verification is over the **raw body bytes**, exactly as received —
  the handler never re-serializes before verifying. If you refactor, keep it
  that way; JSON round-tripping changes whitespace and breaks the HMAC.
- `XADD ... MAXLEN ~ 10000` caps retention. At typical single-player event
  rates that's days of history; raise it if you want more replay depth.
- The events endpoint returns `{ "events": [{ "id", "event" }], "next_cursor" }`.
  Persist `next_cursor` client-side; pass it back to get strictly-newer events.
