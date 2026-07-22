# Bobnet Feature — Design

**Date:** 2026-07-22
**Status:** Approved for implementation (autonomous session; decisions recorded here in lieu of interactive review)

## Goal

Extract Bobnet out of `DevicesFeature` into its own TCA feature module and build it out into a real
three-panel comms experience: channels in the content pane, that channel's messages in the detail
pane, with sending, channel creation, per-channel read markers, and FTL-relay-backed catch-up.

## Background (what exists today)

- `BobnetView`/`BobnetRow` live in `DevicesFeature` as a flat, read-only, all-channels list.
  `SidebarItem.bobnet.hasDetail == false`, so the shell renders it two-pane.
- `BobnetMessage` (GameModels) is a locally-persisted SQLite table keyed by the server message `id`;
  `GameSync.bobnetRoute()` upserts one row per `bobnet.*` stream event (`bobnet.new` payloads carry
  the `id`). This table is the app's message store and survives relaunch; nothing here changes.
- API surface (openapi.json, confirmed against the docs site):
  - `GET /v1/devices/{code}/channels` → `{channels: [{name, last_active}]}` — distinct channels seen
    by a relay-capable device.
  - `GET /v1/devices/{code}/messages` → `{messages: [BobnetMessageItem], next_cursor, total}` with
    `cursor`/`limit` (max 100)/`latest`/`include_npcs` — recent messages visible from a relay.
    **No channel filter** — paging is global across channels.
  - `POST /v1/replicants/{code}/message` `{channel, text}` → the created message (incl. `id`).
    Sending to an unsubscribed channel auto-subscribes (docs) — this is also the channel-creation
    primitive.
- Active relays: `Device` rows with `deviceType == "ftl_relay"` and `statusBase == "relaying"`
  (liveness flips via `relay_activated`/`relay_deactivated`, already reconciled into the table).

## Approaches considered

1. **Grow Bobnet in place inside DevicesFeature.** Rejected — wrong ownership, and DevicesFeature is
   already the largest feature module.
2. **Server-driven UI (query a relay on every view, no persistence).** Rejected — Bobnet history is
   already persisted locally from the stream; relay-only reads would lose offline history, break
   when no relay is active, and hammer the rate limiter.
3. **New `BobnetFeature` module, local-first over the existing `BobnetMessage` table, with a relay
   catch-up client layered on top.** Chosen. The stream keeps the table warm in real time; relays
   fill gaps (channels directory + missed history) on demand. A full `GameServices` domain +
   `DomainFreshness` registration is deferred — catch-up on pane appearance is enough for v1 and
   avoids composition-root churn.

## Architecture

New SPM module **`BobnetFeature`** (Sources + Tests), dependencies mirroring `MessagesFeature`:
`API`, `GameDatabase` (tests bootstrap), `GameModels`, `GameSession`, `UI`, TCA, `SQLiteData`.
No `GameServices` dependency.

### Units

- **`BobnetChannel`** (new `@Table` in GameModels, migration composed in `GameDatabase`):
  `name` (TEXT PK), `lastActive` (nullable date, from relay directory), `lastReadMessageID`
  (INTEGER, default 0). Rows are created by relay channel sync, by channel creation, and lazily by
  the first read-marker write; a channel that exists only as streamed messages still appears in the
  list (see the merge query) with marker 0.
- **`BobnetClient`** (dependency in BobnetFeature): thin wrapper over `@Dependency(\.gameClient)`
  with three ops — `channels(relayCode)`, `messages(relayCode, cursor:limit:latest:)`,
  `send(replicantCode, channel, text)` — mapping generated schemas to feature value types.
  `testValue` uses `unimplemented(...)` per the loud-test-defaults rule.
- **`BobnetFeature`** (reducer): selection, relay discovery, catch-up, compose/send, channel
  creation, read-marker lifecycle.
- **Channel list query**: a `FetchKeyRequest` that, in one read, fetches all `BobnetChannel` rows
  plus a per-channel aggregate over `bobnetMessages` (max id, max time, count of `id >
  lastReadMessageID`), merged into `[ChannelRow]` sorted by last activity desc. Lives beside the
  reducer as plain (SwiftUI-free) code so it's unit-testable against an in-memory DB.
- **Views**: `BobnetChannelsView` (content pane list), `BobnetChannelRow` (own file — preview-crash
  rule), `BobnetChannelDetailView` (messages + compose bar), `BobnetMessageRow` (own file; adapted
  from today's `BobnetRow`, minus the channel tag since the channel is the context),
  `NewChannelSheet`.

### State (sketch)

```swift
@ObservableState struct State {
  @ObservationStateIgnored @FetchAll(ChannelList()) var channels: [ChannelRow]
  @ObservationStateIgnored @FetchAll(/* relaying ftl_relay devices */) var activeRelays: [Device]
  var selectedChannel: String?
  var markerAtSelection: Int      // read-marker snapshot for the "new" divider
  var isAtLatest: Bool            // detail scrolled to the newest message
  var composeText: String
  var newChannel: NewChannelDraft?   // plain-value sheet (presentation dialect tier 1)
  var isCatchingUp: Bool
  var errorMessage: String?
}
```

Messages for the selected channel live in state as a channel-scoped `@Fetch`/`@FetchAll` request
(the list-query-in-state standard), reloaded via `state.$messages.load(...)` when the selection
changes — the same reload pattern `LocationsFeature` uses for `forest`. Ascending by `(time, id)`.

### Data flow

- **On `task`** (pane appears) and on manual refresh: pick the active relay (first `relaying`
  `ftl_relay` by device code, for determinism). If none → no network work; the UI shows the
  no-relay state. Otherwise: `channels(relay)` → upsert `BobnetChannel` rows (preserving
  `lastReadMessageID` — upsert touches only `lastActive`); then catch-up. Cursor semantics
  (confirmed live 2026-07-22): `cursor=N` pages **forward** — ascending ids > N, `next_cursor` =
  last id of the page, `null` at the tail; `latest=true` returns the newest page descending with
  `next_cursor: null`. So: if the local table is empty, seed with `messages(relay, latest: true,
  limit: 100)`; otherwise walk forward from `cursor = max local id` in pages of 100 until
  `next_cursor` is nil or a short page arrives, capped at 5 pages (logged when truncated). Upsert
  into `BobnetMessage`.
- **Live updates**: the SSE route keeps writing `BobnetMessage`; `@FetchAll` re-renders both panes
  automatically. No new stream plumbing.
- **Send**: compose bar posts via the active replicant (`@Shared(.appStorage)` active-replicant
  code, same source the sidebar header uses). On success, upsert the returned message and advance
  the channel's marker to its `id` (you were at the bottom composing). Sending disabled (with
  explanation) when there's no active relay or no active replicant.
- **Create channel**: toolbar “+” → `NewChannelSheet` (plain-value presentation: optional in state,
  `.sheet(item:)` with dismiss-setter binding). Fields: channel name (trimmed; `#` prepended if
  missing) and a required first message — posting it is what creates/subscribes the channel
  network-side (per docs). On success: upsert channel row + message, select the new channel.

### Read marker

`lastReadMessageID` per channel; a message is unread iff `id > lastReadMessageID`.

- Selecting a channel snapshots `markerAtSelection` (drives the “New messages” divider so it
  doesn't jump while reading).
- The detail view reports whether the newest message is visible (`isAtLatest`, via scroll
  geometry). While `selectedChannel != nil && isAtLatest && maxLocalID > marker`, a 3-second
  `continuousClock` timer runs (cancellable, keyed per channel); scrolling away, deselecting, or
  leaving the pane cancels it. A new arrival while lingering restarts the 3s window (the “most
  recent message” changed). On fire, the marker is set to the channel's current max local id inside
  the write transaction.
- Sending also advances the marker (above).

### No-active-relay indication

A persistent banner at the top of the channels pane when `activeRelays` is empty: “No active FTL
relays — showing stored history; catch-up and sending unavailable.” Compose bar and “+” are
disabled in that state. The `@FetchAll` over the Device table makes the banner flip live when a
relay (de)activates.

### Shell integration

- `SidebarItem.bobnet.hasDetail` → `true`.
- `MainFeature`: add `bobnet: BobnetFeature.State` + scope; content pane → `BobnetChannelsView`,
  detail pane → `BobnetChannelDetailView`. Remove the old `BobnetView()` branch.
- Delete `BobnetView.swift`/`BobnetRow.swift` from DevicesFeature.
- **Manual step (user, in Xcode):** link the `BobnetFeature` product to the app target — pbxproj
  edits are off-limits per project protocol. Until then the app target won't build; the SPM package
  (all module code + tests) verifies independently.

## Error handling

- Relay reads are best-effort: a failed channels/messages fetch surfaces `errorMessage` (dismissible,
  same pattern as MessagesFeature) but never blocks the locally-stored view.
- Send/create failures keep the draft text and surface the error.
- Decode drift: probe the live endpoints (`probe-api`, GET only) before wiring; patch the spec
  copy per the strict-spec drift policy if needed.

## Testing

- **Reducer (TestStore + TestClock):** no-relay short-circuit; catch-up upsert + early-stop walk;
  linger semantics (2.9s + scroll-away cancels; 3.0s writes marker; arrival mid-linger re-arms);
  send success advances marker / failure keeps draft; create-channel selects and subscribes.
- **Query merge (in-memory DB via `GameDatabase.bootstrap()`):** channels from messages-only,
  relay-only, and both; unread counts against markers; ordering.
- Pure logic stays in SwiftUI-free namespaces (statics-in-View trap).

## Out of scope (deliberate)

- Per-channel unbounded history backfill (the messages endpoint pages globally, not per channel).
- Unsubscribe/leave, muting, `bobnet_channels` account-settings editing (AccountFeature owns that).
- NPC filtering toggle (`include_npcs` is left at its default).
