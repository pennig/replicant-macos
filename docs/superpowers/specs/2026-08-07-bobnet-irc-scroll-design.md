# Bobnet channel detail: an IRC-shaped scroll view

## The goal

`BobnetChannelDetailView` should behave like an IRC channel window:

- **Bottom-aligned on appear**, whatever the message count — a channel with 12
  messages sits its messages at the bottom of the pane, not floating in the
  middle and not pinned to the top.
- **Scroll up for history**, lazily laid out.
- **A new message never yanks you out of history.** If you are reading back, the
  viewport holds still and an affordance tells you something arrived.

Two symptoms motivate the work, both reported switching between channels:

1. Switching from a long channel (`#general`, `#trade`) to a short one
   (`#claims`, fewer messages than fill the pane) leaves the messages neither
   bottom-aligned nor centred.
2. Switching between two long channels sometimes leaves one or two messages
   tucked behind the compose bar.

## Scope

In scope: the placement and follow behaviour of the detail scroll view, and the
reducer state that governs it.

Out of scope: **windowing the query.** `BobnetChannelMessages.fetch` keeps
returning every message in the channel. Row *bodies* stay lazy via `LazyVStack`;
the array does not become lazy. Load-older-on-scroll-up is a separate effort and
is deliberately not designed here — tangling it with placement would mean solving
scroll-position preservation across a prepend before the scroll view is
trustworthy at all.

## Diagnosis before implementation

The fix below rests on a hypothesis that has not yet been confirmed against a
running view, and the design is explicit about which rung of the ladder each
possible measurement selects.

### The hypothesis

`BobnetChannelDetailView` applies `.id(channel)` to the `ScrollView` and
`.defaultScrollAnchor(.bottom)` *outside* it. On a channel switch the
`ScrollView` gets a fresh identity while the anchor node keeps its old one, so
the anchor's placement does not necessarily re-apply to the new channel's
content.

This is the same modifier-ordering trap already recorded for this exact view in
`.claude/memory/bobnet-feature.md`, where `.id(channel)` was added in `eba8b2e`
specifically to re-fire `onScrollGeometryChange` and provably did not, because
`.id()` sat below the modifier.

The competing hypothesis: `.defaultScrollAnchor`'s `.alignment` role measures
against the container *including* the bottom safe-area inset, so undersized
content bottom-aligns to a line hidden behind the compose bar.

### The experiment

A throwaway `.executableTarget` inside `Modules` (not a separate package — a
separate package re-resolves the whole dependency graph), per the recipe
recoverable from `b1d21d0`. It hosts the real `BobnetChannelDetailView` in an
`NSHostingView` on a real `NSWindow`, seeds a 12-message channel and an
800-message channel, switches between them, and walks the AppKit subview tree
down to the backing `NSScrollView` to read three numbers:

- `contentView.bounds.origin.y`
- `documentView.frame.height`
- `contentInsets`

Numbers, not a screenshot. A screenshot says it looks wrong; those three say
why. The harness is removed in the same commit series that uses it.

Unlike the perf investigation this harness style burned us on
(`.claude/memory/scroll-anchor-forces-foreach-walk.md`: an isolated harness
understated a per-`store`-access cost ~30× because a bare root `Store` has no
parent state to copy), **layout does not depend on the store hierarchy**, so an
isolated harness is sound evidence here.

### The ladder

With `.id(channel)` moved above the anchors, does the 12-message channel
bottom-align?

| Measurement | Conclusion | Action |
|---|---|---|
| Yes | `.id` ordering was the whole thing | Ship the design below |
| No, content sits behind the compose bar | `.alignment` measures the inset-inclusive container | Add `.containerRelativeFrame(.vertical, alignment: .bottom)` to the `LazyVStack`, forcing it to at least container height and bottom-aligning within that, independent of the anchor |
| No, content floats at an arbitrary offset | SwiftUI is not placing undersized content deterministically | Stop. Rebuild the pane as an `NSViewRepresentable` over `NSScrollView` + `NSTableView` |

The AppKit rung is a real option, not a threat: an unflipped AppKit document view
anchors its content to the bottom-left by construction, which *is* the disposition
we want rather than a behaviour we configure. It is third because it rewrites a
view whose defect has not been identified, and an unidentified defect reappears in
the replacement.

## Design

### The governing move: behaviour into the reducer

Today a single `.defaultScrollAnchor(.bottom)` does three unrelated jobs —
initial placement, undersized alignment, and follow-on-growth — and none of them
can be reasoned about or tested independently.

After this change the scroll view answers only *where am I*, and `BobnetFeature`
decides *where should I be*. This follows the standard already recorded in
`.claude/memory/list-feature-query-in-state.md`: state decides, the view renders.

### State

Three additions to `BobnetFeature.State`:

```swift
/// Messages that arrived while the reader was away from the bottom.
var newWhileAway: Int = 0
/// Bumped to ask the view to scroll to the bottom.
var scrollToBottomToken: Int = 0
/// A bottom-scroll has been asked for and not yet observed to land.
var pendingBottomScroll: Bool = false
```

### Actions and transitions

**`isAtLatest` is pure geometry truth. The reducer never writes it mid-flight.**
It is *established* where the view is known to render pinned to the bottom
(`selectionChanged`, `.detailAppeared`, `.detailDisappeared` clearing it on the
way out) and otherwise only ever set by the view's own report.
`pendingBottomScroll` is a **mask**: OR-ed with `isAtLatest` wherever the question
is "effectively at the newest message".

| Trigger | Effect on state |
|---|---|
| `.latestMessageChanged`, `isAtLatest \|\| pendingBottomScroll` | `scrollToBottomToken += 1`, `pendingBottomScroll = true`, arm the 250 ms expiry |
| `.latestMessageChanged`, neither | `newWhileAway += 1` |
| `.binding(\.isAtLatest)` reporting **false** | `isAtLatest = false` — recorded as reported, whether or not a scroll is in flight; the mask, not an override, keeps the linger alive |
| `.binding(\.isAtLatest)` reporting **true** | `newWhileAway = 0`, `pendingBottomScroll = false`, cancel the expiry |
| `.jumpToLatestTapped` (new) | `newWhileAway = 0`, token bump + mask, re-arm the linger |
| `.sendSucceeded` | `newWhileAway = 0`, token bump + mask |
| `.pendingScrollExpired` (new) | `pendingBottomScroll = false`, re-evaluate the linger |
| `selectionChanged`, `.detailAppeared` | `isAtLatest = true`, `newWhileAway = 0`, `pendingBottomScroll = false` |
| `.detailDisappeared` | `isAtLatest = false`, `newWhileAway = 0`, `pendingBottomScroll = false` |

`.sendSucceeded` scrolling to the bottom is deliberate: sending a message while
scrolled up should take you to your own message.

`lingerableChannel(_:)` — the one place arming and firing both read — guards on
`isAtLatest || pendingBottomScroll`. That single OR is what keeps the linger alive
across the brief window where content has grown and the scroll has not yet landed.
No other linger behaviour changes.

### Why `pendingBottomScroll` exists

Without it, a message arriving while the reader is *at* the bottom is a race. The
content grows, `sizeChanges: .top` holds the viewport, and geometry reports
not-at-bottom. The reducer sees `isAtLatest == false` and both disarms the linger
and increments `newWhileAway` — producing a spurious "1 new ↓" for a message the
reader watched arrive, and a read marker that stops advancing. That is a wrong
count, not merely a one-frame flash.

The mask covers that window: while a bottom-scroll is in flight the reader counts
as at-latest even though geometry says otherwise, so the negative report costs
neither the linger nor a count.

It removes **one** ordering, not both. If the geometry report lands *before*
`.latestMessageChanged`, the mask is not yet armed and `newWhileAway` still takes a
spurious increment. That is a known limitation, accepted because the increment is
bounded by one per arrival and the pill's count is corrected by the next positive
report. Closing it would need the reducer to know a size change was in flight
before the view told it, which nothing in the geometry contract offers.

The one thing the mask must **not** do is write `isAtLatest`. `onScrollGeometryChange`
fires only when its transformed `Bool` *changes*, so a report the reducer overwrites
is a report the view can never repeat: the two values desynchronise permanently and
the observer stays silent. Masking leaves geometry's value untouched, so the
observer and the reducer always agree on what was last reported.

### Why the expiry is bounded

A mask that never clears makes "effectively at latest" permanently true, and that
is precisely the failure that advances a read marker while the reader is scrolled
away — the bug documented in `.claude/memory/bobnet-feature.md`. The 250 ms expiry
makes the optimistic hold unable to stick.

After it fires, geometry is authoritative again — and under the mask design that
claim is actually true. Nothing overwrote `isAtLatest` during the window, so the
value the expiry falls back to is the last thing the view reported, not a reducer
invention the view has no way to correct. Dropping the mask can change
lingerability, so `.pendingScrollExpired` re-evaluates the linger at that moment.
A channel shorter than its viewport is the case that proves the difference: it is
at rest at the bottom, `isAtBottom` stays true as content grows, so no report ever
arrives — and the expiry leaves `isAtLatest` true, exactly as the view last said.

The hold is safe within its window for an independent reason: the linger is 3
seconds and **re-checks its arming conditions when it fires**
(`lingerableChannel(_:)` is shared by arming and firing, deliberately). A 250 ms
optimistic hold cannot survive to the firing check.

250 ms is chosen as roughly an order of magnitude above the one-or-two frames a
token scroll needs to land (~33 ms), and below the threshold at which a delayed
button is perceptible. It is a tunable; nothing depends on the exact value.

### The view

```
ScrollView { LazyVStack { ForEach … } }
  .defaultScrollAnchor(.bottom, for: .initialOffset)
  .defaultScrollAnchor(.bottom, for: .alignment)
  .defaultScrollAnchor(.top,    for: .sizeChanges)
  .scrollPosition($scrollPosition)
  .onScrollGeometryChange(…)          // unchanged
  .onChange(of: store.scrollToBottomToken) { scrollPosition.scrollTo(edge: .bottom) }
  .id(channel)                         // above the anchors and the geometry observer
  .overlay(alignment: .bottom) { JumpToLatestPill … }
  .safeAreaInset(edge: .bottom) { ComposeBar … }
```

Three changes from today:

- **`.id(channel)` moves above** the anchors and the geometry observer, so it
  wraps everything holding scroll state. It deliberately does *not* wrap the
  compose bar or the error banner, so a draft keeps its field identity across a
  channel switch.
- **The blanket anchor splits by role.** `.top` for `sizeChanges` is what stops a
  new message moving the viewport.
- **`scrollPosition.scrollTo(edge: .bottom)` on the token** becomes the only
  thing that ever scrolls programmatically.

All three APIs are verified present in the MacOSX27.0 SDK:
`ScrollAnchorRole` carries exactly `.initialOffset` / `.sizeChanges` /
`.alignment`; `defaultScrollAnchor(_:for:)` and `ScrollPosition.scrollTo(edge:)`
are macOS 15+.

Putting the geometry observer under a fresh `.id` may restore initial-value
delivery. **The design does not depend on it** — that initial call is
undocumented, Apple promises only change-based delivery, and `isAtLatest` remains
*established* in the reducer and only *maintained* by geometry. A redundant
initial report is absorbed by the existing `if store.isAtLatest != isAtBottom`
guard.

### `JumpToLatestPill`

Its own file in `BobnetFeature/Sources/` (a small view, feature-local; nothing
else needs it). An `.overlay(alignment: .bottom)` floating above the compose bar,
tapping sends `.jumpToLatestTapped`. Two states:

| Condition | Label |
|---|---|
| `newWhileAway > 0` | `"3 new ↓"` |
| `!isAtLatest && !pendingBottomScroll && newWhileAway == 0` | bare `↓` |
| otherwise | hidden |

`Capsule` + `.rcAccent` + `Space` tokens. `UI`'s existing `rcPill(_:)` is a
static inline text badge, not a tappable float, so this is a new view rather than
a reuse of it.

The counted state cannot flicker, because `newWhileAway` only ever increments
while the reader is genuinely away. The bare state is protected by
`pendingBottomScroll`.

## Testing

**Reducer — `TestStore`, no view.** These are the real regression tests, and they
exist because the behaviour moved out of the scroll view:

- A message arriving while at latest bumps the token and does not touch
  `newWhileAway`.
- A message arriving while away increments `newWhileAway` and does not bump the
  token.
- A geometry report of false during `pendingBottomScroll` is recorded but costs
  neither the linger nor a count.
- A geometry report of true clears both `newWhileAway` and `pendingBottomScroll`.
- `pendingBottomScroll` clears on the 250 ms expiry with no geometry report at
  all (`TestClock`).
- `.jumpToLatestTapped` and `.sendSucceeded` each set the mask, zero the counter,
  and bump the token — neither writes `isAtLatest`.
- Selection change zeroes both.

The four cases that decide whether the mask is right are asserted against the
**database** (`BobnetChannel.lastReadMessageID`), not state: a message landing at
the bottom, the reader scrolling up mid-window, a channel shorter than its
viewport that never reports at all, and a pill tap whose scroll never lands.
State-only assertions are what let the override design's two bugs through.

**Placement — not unit-testable, and this design does not pretend otherwise.**
The harness numbers from the diagnosis step are the evidence. They belong in a
memory note, not in a test that claims coverage it does not have.

## What this does not change

- `BobnetChannelMessages` still fetches the whole channel.
- `BobnetMessageRow` is untouched, keeping `.textSelection(.enabled)`.
- `BobnetScrollBottom.isAtBottom` is untouched, keeping the
  `contentInsets.bottom` arithmetic that is unit-tested against real captured
  geometry.
- Linger timing, arming, and the re-check-on-fire rule are untouched.
- The `firstUnreadID` binding above the `ScrollView` stays exactly where
  `b1d21d0` put it. Nothing in this design may move an O(n) computation back
  inside the `ForEach` closure.
