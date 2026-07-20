---
name: event-stream-migration
description: v2.3.0 native SSE event stream replaced the custom relay; single-channel EventPipeline + dotted event taxonomy.
metadata: 
  node_type: memory
  type: project
  originSessionId: afe10dd7-bbc8-463d-a682-3468dfea5d92
---

Backend v2.3.0 (adopted 2026-07-19) added a native SSE endpoint `GET /v1/events/stream` + account-wide pull `GET /v1/events`, replacing the custom Rust relay. The app was migrated to a **single event channel**:

- `Modules/API/Sources/EventStream/`: `EventStreamClient` (SSE over URLSession.bytes, session bearer token via injected provider, string Redis-stream-ID cursor + Last-Event-ID), `GameEventEnvelope` (replaces `GameEvent`/`UnifiedEvent`; dotted `event` + `category` + first-class `star`/`location`; `provenance: .stream/.catchUp` replaces `UnifiedEvent.Source`), `GameEventsFetching` (`APIProtocol.gameEvents` pull + `EventCursorStore` under key `replicant.events.cursor`), reworked single-channel `EventPipeline`.
- **Deleted**: `Relay/RelayClient.swift`, `Event Log/` (UnifiedEvent, GameLogEntry, GameLogFetching, old EventPipeline), `GameSync/RelayRoute.swift` + `RelayConfiguration.swift`. No more fingerprint dedup — dedup is by stream `id`.
- Routing: `EventRoute`/`EventMatcher`(`.category`/`.event`/`.eventPrefix`/`.all`)/`EventRouter` in `GameSync/EventRoute.swift`. Device route = `.all` confirm-read. **Every event is logged with payload** at `.info`; a non-device event with no feature-specific route logs `⚠️ UNHANDLED EVENT` at `.notice` (fill taxonomy gaps from logs).
- Completion event remap (`Reconciler.completionEventTypes`): `print.completed`, `travel.arrived`, `site.depleted`, `scan.completed`. `print.completed` is real but **undocumented**. Print-completion payload key still assumed `new_device_code` (unverified — watch logs).
- Also v2.3.0: `Message` gained `category`/`subcategory` (+migration); `Account` gained `events`(amiDigestInterval/muted)/`messages`(email/subscribed) settings + `AccountUpdate` PATCH wiring — **settings-editing UI deferred**.

See [[decode-diagnostics-decorator]]: after any spec bump, regenerate `DiagnosticAPIClient` (`swift build --target API` then `python3 Modules/scripts/gen-diagnostic-client.py`) or the API target won't conform to `APIProtocol` — this bit during the migration.
