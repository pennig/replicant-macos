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

## The at-bottom predicate must subtract `contentInsets.bottom` (2026-07-31)

The above fix was necessary but not sufficient — unread counts still refused to
clear, "hit or miss". Instrumented logging of the real pane settled it:

```
off=10750 container=915 content=11702 insets=(t52,b54) gap=50
```

The compose bar is a bottom `safeAreaInset`, and **a scroll view pinned to its
true bottom still reports `contentSize - (contentOffset + containerSize) ==
contentInsets.bottom`** — 54pt here, against a 24pt tolerance. So
`offset + container >= contentSize - 24` was *false at rest* and true only during
the rubber-band overscroll of an active gesture. The linger armed on scroll blips
and was cancelled milliseconds later when the view settled. The resting bottom is
`contentSize - contentInsets.bottom`; `BobnetScrollBottom.isAtBottom` is now the
one place that arithmetic lives, and it is unit-tested against real captured
geometry rather than through the view.

## `.cancel(id:)` cannot cancel an effect that hasn't registered yet

Same investigation, second bug — and the *only* reason the marker ever advanced.
A linger ARMED at `12:33:14.961` and CANCELLED at `12:33:14.963` still fired its
`lingerElapsed` at `12:33:18.148`: the `.run` task had not yet reached its
`withTaskCancellation` registration, so the cancel found no token and was a
no-op. That escaped timer marked #general read *while the user was scrolling
upward*, and left #trade's marker parked on another player's message.

Rule: **for any effect whose firing has a side effect, re-check the arming
conditions when it fires.** Cancellation is an optimisation, never a guarantee.
`lingerableChannel(_:)` is deliberately shared by `reevaluateLinger` (arming) and
`.lingerElapsed` (firing) so the conditions must hold at both ends of the window.
Covered by `escapedLingerAfterScrollingAwayWritesNothing` /
`escapedLingerAfterLeavingPaneWritesNothing`, which send `.lingerElapsed`
directly to simulate the lost cancellation.

Also: the `lingerElapsed` DB write had no `catch:`, so a throwing marker write
was discarded in silence. It logs now.

## The scroll view is bottom-anchored by the reducer, not by one anchor modifier

The motivating hypothesis — that `.id(channel)` sitting *below*
`.defaultScrollAnchor(.bottom)` broke bottom alignment on a channel switch —
was never confirmed. An isolated harness (a real `NSHostingView` in a real
`NSWindow`, seeded from the live table: `#general` 615 messages, `#trade` 226,
`#claims` 15 at 25-34 characters each) measured `{bare, split} × {800, 1054}`,
16 configurations in all. Every one reported `atBottom=Y`; in the six rows
where `#claims` genuinely fit its viewport, `fillsViewport == visibleH -
insets.bottom` **exactly** (952 == 952 under `split h=800`; 982 == 982 under
`bare h=1054` and `split h=1054`). **The isolated harness reproduces neither
reported symptom** — not the short channel failing to bottom-align, not
messages hidden behind the compose bar — so this branch's changes stand on
the IRC behaviour they deliver, not on a measured fix.

Two measurement traps cost real time getting there:

- The first harness reading concluded "rung 3, rewrite in AppKit" from a
  reading guide that had the sign backwards. The correct identity is
  `gapBelow == -insets.bottom` at rest — an `NSClipView` with
  `contentInsets` scrolled to its true maximum sits at `bounds.maxY ==
  documentHeight + insets.bottom`. A metric that fails to discriminate can
  mean the instrument is broken *or* that nothing is wrong; here it was the
  latter.
- `findScrollView`'s depth-first search grabbed the sidebar's `NSScrollView`
  under the split-view variant, silently reporting `documentH=120` unchanged
  across every channel switch. Fix: pick the rightmost scroll view by window
  x, not the first one found in tree order.

What the branch actually built, since the harness gave it no measured bug to
fix: the anchor is split by role (`.bottom` for `initialOffset` and
`alignment`, `.top` for `sizeChanges`, so a message landing doesn't drag the
viewport out of history) and `.id(channel)` now wraps the whole scroll
region, which lives in `BobnetChannelMessagesScroll` so `@State
scrollPosition` is recreated per channel. Programmatic scrolling is the
reducer's: `scrollToBottomToken` is bumped on a message arriving while at the
bottom, on send, and on the pill tap, and the view answers it with
`scrollPosition.scrollTo(edge: .bottom)`. `pendingBottomScroll` suppresses
geometry's not-at-bottom report while such a scroll is in flight, bounded to
250 ms so it can never stick — a frozen-true `isAtLatest` is what advances a
read marker under a reader who has scrolled away. The temporary
`BobnetScrollProbe` logging instrumentation in
`BobnetChannelMessagesScroll.swift` stays in place past this branch: it is
the only thing that can see the reported symptom in the running app, since
the harness could not reproduce it.
