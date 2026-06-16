# ReplicantKit

Swift package for [replicant.space](https://replicant.space): a generated,
type-safe game API client wrapped in a self-throttling rate-limit governor,
plus a client for your relay's event log.

## What's inside

- **Generated API client** — swift-openapi-generator builds `Client` from the
  game's published OpenAPI spec at compile time. You never hand-write models.
- **`RateLimitGovernor`** (actor) — tracks the two token-scoped buckets
  (reads 120/min, actions 60/min), gates requests before they leave the app,
  reconciles with `X-RateLimit-*` response headers, and absorbs 429 penalties.
- **`RateLimitMiddleware` / `BearerAuthMiddleware`** — OpenAPI client
  middlewares wiring the governor and auth into every generated call.
- **`RelayClient`** — cursor-based polling + `AsyncThrowingStream` of webhook
  events from the Rust relay. Free to poll; doesn't touch game rate limits.
- **`EventPipeline`** (actor) — merges the relay stream with game event-log
  backfill into ONE deduplicated `AsyncStream<UnifiedEvent>`. Webhooks are
  at-most-once; the game's event log is the authoritative record. The
  pipeline treats the webhook as the fast notification path and `backfill`
  as gap repair, so the app has a single event-handling code path either way.

## Setup

1. Fetch the spec into the package (one-time, re-run when the game updates):

   ```sh
   ./scripts/fetch-spec.sh
   ```

2. Add the package to your Mac app. First build will prompt you to trust the
   `OpenAPIGenerator` build plugin (Xcode → "Trust & Enable").

3. If the generator chokes on part of the spec (not uncommon with
   hand-rolled specs), vendor the saved `openapi.yaml` and trim or patch the
   offending paths — you only need the endpoints you call. The
   [generator docs](https://swiftpackageindex.com/apple/swift-openapi-generator/documentation)
   cover `filter:` config to generate a subset.

## Usage

```swift
import ReplicantKit

// ONE governor per API token — the limits are token-scoped. Share it
// between the generated client and the pipeline's game-log client.
let governor = RateLimitGovernor()
let game = ReplicantSpace.client(apiKey: apiKey, governor: governor)

// Operation names come from the spec's operationIds — explore via autocomplete.
// e.g. let me = try await game.getAccount()

// The unified event pipeline: relay (fast path) + game log (gap repair).
let pipeline = EventPipeline(
    relay: RelayClient(
        baseURL: URL(string: "https://your-relay.vercel.app")!,
        clientToken: relayToken
    ),
    gameLog: GameLogClient(apiKey: apiKey, governor: governor)
)

let events = await pipeline.start { error in
    // Relay unreachable — backfill + resumeRelay when connectivity returns.
}

// On launch / wake / after relay errors: repair any gaps. Nonzero return
// means the webhook channel missed events — your monitoring signal.
let missed = try await pipeline.backfill(
    replicantCode: "57F0F6C8",
    since: lastSeenEventDate
)

// One code path for everything, live or recovered:
for await event in events {
    switch event.eventType {
    case "device_cruise_arrived":
        // event.payload?["location"]?.stringValue
        break
    default:
        break
    }
    lastSeenEventDate = event.date ?? lastSeenEventDate
}
```

The pipeline persists the relay cursor automatically (UserDefaults by
default; conform `RelayCursorStore` to use something else). Consumers should
handle events idempotently: dedup is fingerprint-based, and the deliberate
worst case is an occasional duplicate rather than a dropped event.

## Notes

- **App Sandbox**: enable the *Outgoing Connections (Client)* entitlement.
- **Secrets**: store the game API key and relay token in the Keychain, not
  UserDefaults.
- **Concurrency**: fire as many concurrent calls as you like — the governor
  serializes budget accounting and everything queues politely near the limit,
  keeping a small reserve so a stray curl from your terminal still works.
- 429s are retried up to 3 times with `Retry-After` honored; beyond that the
  response surfaces to the caller.
