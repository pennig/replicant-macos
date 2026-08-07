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

## An out-of-app harness understated this ~30×, and nearly buried it

The harness said an isolated switch costs ~110 ms at the live 611 messages
before *or* after the fix, so the first conclusion written here was that the
quadratic was latent and did **not** explain the reported symptom. A SwiftUI
Instruments trace of the real app says the opposite: four main-thread hangs in
a 20 s recording — 3.85 s, 6.08 s, 1.53 s, 3.02 s, three of them Severe — and
`BobnetChannelDetailView.firstUnreadID.getter`, called from the `ForEach`
closure, is **13.46 s of the 14.46 s hung, 93%**. Per window it is 98 / 94 / 79
/ 92%.

The gap is the **store hierarchy**, and it is the reusable lesson. In the app
the leaf frames under that getter are `swift_retain`/`swift_release`, and the
app frames beneath it are `AppFeature.State.appState.getter`,
`initializeWithCopy for AppFeature.State`, `assignWithCopy for
MainFeature.State`, `destroy for AppFeature.State` — every `store.channelMessages`
and `store.markerAtSelection` read walks and copies the composed parent state.
The harness built a bare root `Store(initialState: BobnetFeature.State())` with
no parent, so each access was cheap and the per-access constant was ~30× too
small. The *shape* (quadratic, flat after the fix) transferred; the *constant*
did not.

So: **an isolated view harness measures the algorithm, never the store.** For
anything whose cost is per-`store`-access, either compose the real parent
feature into the harness or measure the running app. And when a harness and a
symptom disagree by an order of magnitude, the harness is the thing to doubt —
here it very nearly retired a real bug as latent.

Instruments route, all queryable offline: `xctrace export --input X --toc`, then
`--xpath '//trace-toc/run/data/table[@schema="…"]'`. `potential-hangs` gives the
windows, `swiftui-update-groups` names the long updates ("Transaction" /
"Transaction for Gesture" — the "Other Long Updates" bucket, unattributed there),
and `time-profile` carries the stacks that actually name the culprit. Rows use
`id`/`ref` interning and the backtrace element is `tagged-backtrace`, leaf-first.
