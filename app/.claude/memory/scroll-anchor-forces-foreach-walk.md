---
name: scroll-anchor-forces-foreach-walk
description: ".defaultScrollAnchor(.bottom) walks the whole ForEach to size content, so anything O(n) inside the closure makes the view quadratic in row count"
metadata:
  type: project
---

# `.defaultScrollAnchor(.bottom)` makes a lazy stack walk every row

`LazyVStack` inside a `ScrollView` really is lazy about **row bodies** — a
611-message Bobnet channel materialised 63 of them, measured with a counter in
the row's `body`. So "it's laying out all the messages" is the wrong diagnosis
for this shape, and was the wrong diagnosis here.

What is **not** lazy is the `ForEach` closure. To place the content at the
bottom, SwiftUI has to size the whole thing, and that walks every element:
**1297 closure evaluations for 611 messages**, roughly 2n. Cheap in itself. The
trap is that anything O(n) sitting in that closure is then O(n²).

`BobnetChannelDetailView` had exactly that — the "New messages" divider compared
each row against `firstUnreadID`, a computed property that scanned the channel's
whole message array. Settle time for one channel switch, real view in a real
`NSWindow`, **`-c release`** (the commit message for `b1d21d0` mislabels this
same table as debug):

| messages | before | after |
|---|---|---|
| 611 | 138 ms | 108 ms |
| 1200 | 942 ms | 121 ms |
| 2400 | 8866 ms | 125 ms |

Debug at 611 is 117–148 ms before and 72–120 ms after, so the config barely
moves it — this is Sharing/store access per scan, not arithmetic the optimiser
can fold. Worth knowing because the app is normally run as a Debug build out of
Xcode, so debug is the config the symptom lives in.

After binding the anchor once per list build the switch is **flat** — a
25-message channel and a 2400-message channel both cost ~110 ms, so row count no
longer enters the switch at all. Note where the payoff is: at the live 611 the
fix is worth ~30 ms, and the whole win is in the growth curve.

Rule: **inside a `ForEach` closure under a scroll anchor, treat every element as
if the closure runs for all of them, because it does.** Bind list-wide values
above the `ScrollView`, never in the closure.

Related, same family: [[event-log-feature]] capped its query at `displayLimit`
because `SelectableList` measures every row. Different mechanism (that one
really does measure rows), same lesson about unbounded chat/log lists.

## Measuring this without running the app

The [[chrome-min-height-window-pin]] recipe generalises: add a throwaway
`.executableTarget` **inside** `Modules` (not a separate package — a separate
package re-resolves the whole dependency graph), host the real view in an
`NSHostingView` on a real `NSWindow`, drive one `store.send` for the interaction,
and measure `getrusage` CPU plus wall-time-until-quiet. Recoverable from `b1d21d0`.

Two things that cost real time here and will again:

- **Seed the read marker.** With `lastReadMessageID = 0` the divider's `marker > 0`
  guard short-circuits and the quadratic never fires — the first run measured a
  clean 233 ms and looked fine.
- **Measure variants back-to-back in one batch.** Two early batches read 4× high
  (630 ms debug / 572 ms release for work that re-measures at ~140 ms) purely
  from machine state after a long build. Never compare across batches.

## Still open

This did **not** explain the reported symptom. An isolated switch at the live
611 messages settles in ~110 ms before *or* after the fix, and the running app's
main thread is idle at rest (2825 of 2848 samples in `mach_msg_trap`). Whatever
makes channel switching feel slow today is not in the Bobnet detail pane's own
work, and is unmeasured.
