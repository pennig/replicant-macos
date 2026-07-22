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
