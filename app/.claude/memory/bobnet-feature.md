# Bobnet feature

BobnetFeature module (2026-07-22): 3-panel channels/messages chat, extracted
from DevicesFeature. Local-first: `BobnetMessage` (SSE-fed) + `BobnetChannel`
(name PK, relay `lastActive`, `lastReadMessageID` marker). Catch-up from the
first *relaying* `ftl_relay`: channel directory + forward cursor walk from max
local id (cursor pages ascending; `latest=true` seeds empty tables; 5-page
cap). Send = `POST replicants/{code}/message` as the active replicant — also
the channel-creation primitive (auto-subscribes). Read marker: 3s linger at
newest message (TestClock-proven) or own send; "New" divider anchors to
`markerAtSelection` snapshot. No relaying relay → read-only + banner.
App-target link of the module product is manual (user, Xcode).

## `isAtLatest` must never be sourced from scroll geometry alone (2026-07-31)

`onScrollGeometryChange` fires its `action` **only when the transformed value
changes**. The detail view opens pinned to the bottom
(`.defaultScrollAnchor(.bottom)`), so the opening at-the-bottom state is the
*initial* value and is never announced. `selectionChanged` was resetting
`isAtLatest = false`, so a switched-to channel sat dead-linked at false forever:
the linger never armed and **its unread count never cleared** — `#general` was
stuck 175 messages behind for three days while `#trade` (the first channel
opened, whose modifier got a fresh identity) stayed current.

`.id(channel)` was added in eba8b2e *specifically* to re-fire that initial
report, and **it does not work**: `.id()` is applied *below*
`onScrollGeometryChange`, so the modifier node keeps its identity and its stored
previous value across the rebuild — the transform re-runs, yields the same
`true`, and no action fires. (Empirically confirmed on macOS 26/27. Moving
`.id()` *above* the modifier would restore initial delivery, but that initial
call is undocumented — Apple only promises change-based delivery — so don't
build on it.)

Rule: **treat geometry reports as maintenance, not as the source of truth.**
`isAtLatest` is *established* wherever the view is known to render pinned to the
bottom — `selectionChanged` and `.detailAppeared` — and only then maintained by
geometry. `.detailAppeared`/`.detailDisappeared` both guard on the channel
identity so a stale report from an intra-pane switch can't clobber the new
selection. Note the linger tests all inject `isAtLatest` directly, so they
cannot catch a broken view→reducer signal; the DB (`bobnetChannels
.lastReadMessageID` vs `MAX(bobnetMessages.id)`) is the ground truth for
"did the marker actually advance".
