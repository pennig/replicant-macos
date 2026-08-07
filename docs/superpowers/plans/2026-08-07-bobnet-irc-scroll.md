# Bobnet IRC-Shaped Scroll View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Bobnet channel-detail pane behave like an IRC window — bottom-aligned on appear at any message count, scroll up for history, and a new message that never moves the viewport out of history.

**Architecture:** The IRC semantics move out of a single blanket `.defaultScrollAnchor(.bottom)` (which today does initial placement, undersized alignment, and follow-on-growth all at once) and into `BobnetFeature`, where a `TestStore` can hold them. The scroll view is left answering only "where am I". A diagnosis harness runs first and its measurement selects which fix rung to build.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), The Composable Architecture, SQLiteData, Swift Testing.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-07-bobnet-irc-scroll-design.md`. Read it before Task 1.
- **Worktree:** all work happens in `.claude/worktrees/bobnet-irc-scroll`, branch `worktree-bobnet-irc-scroll`, based on local `main` at `c120465`. Never `cd` to the repo root.
- **LSP setup, once, before Task 1:** `cd app/Modules && swift build --build-tests`, then `./scripts/link-index-store.sh` from the repo root. A fresh worktree has an empty index and every reference query silently returns zero without the symlink.
- **No PRs, no pushes, no `origin`.** Commit directly to the worktree branch.
- **Never hard-code colors, spacing, or font sizes.** Use `Space.*`, `Radius.*`, `.rc*` color tokens, `.rc*` font tokens from `app/Modules/UI/Sources/DesignSystem.swift`.
- **Comment budget is hard:** file header ≤ 6 lines, `///` doc ≤ 3 lines, inline `//` ≤ 2 lines. No dated history, no rejected alternatives, no rationale — those go to `app/.claude/memory/`.
- **Test results come from the JSON event stream**, never from console text. Use the `app:swift-test-event-stream` skill for the invocation.
- **Do not move any O(n) computation back inside the `ForEach` closure.** `firstUnreadID` is bound once per list build above the `ScrollView` and must stay there — `b1d21d0` fixed a quadratic there that cost 8866 ms at 2400 messages.
- **The query stays unwindowed.** `BobnetChannelMessages.fetch` keeps returning every message in the channel. Windowing is explicitly out of scope.
- **Do not change** `BobnetScrollBottom.isAtBottom`, `BobnetUnreadDivider.anchor`, `BobnetMessageRow`, or the 3-second linger timing.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `app/Modules/BobnetLayoutHarness/Sources/main.swift` | **Throwaway.** Hosts the real detail view in a real `NSWindow`, switches channels, prints the backing `NSScrollView`'s geometry. Deleted in Task 6. | 1, 6 |
| `app/Modules/Package.swift` | Adds then removes the harness `.executableTarget`. | 1, 6 |
| `app/Modules/BobnetFeature/Sources/BobnetFeature.swift` | Owns all IRC semantics: the away-counter, the bottom-scroll token, and the in-flight suppression. | 2, 3 |
| `app/Modules/BobnetFeature/Tests/BobnetJumpToLatestTests.swift` | **New.** The reducer's regression suite for everything Tasks 2 and 3 add. | 2, 3 |
| `app/Modules/BobnetFeature/Sources/BobnetChannelMessagesScroll.swift` | **New.** The scroll region alone — anchors, geometry reporting, `ScrollPosition`. Owns `@State scrollPosition` so a `.id(channel)` rebuild gives each channel a fresh one. | 4 |
| `app/Modules/BobnetFeature/Sources/BobnetChannelDetailView.swift` | Shrinks to composition: scroll region + error banner + pill + compose bar. | 4, 5 |
| `app/Modules/BobnetFeature/Sources/JumpToLatestPill.swift` | **New.** The floating two-state affordance. Its own file per the list-row-preview rule. | 5 |
| `app/.claude/memory/bobnet-feature.md` + `MEMORY.md` | Records the harness numbers and the rung taken. | 6 |

**Why the scroll region becomes its own view (Task 4):** `.id(channel)` must sit *above* the anchors to fix the reported bug, and `@State scrollPosition` must sit *below* it so each channel gets a fresh one. A single view cannot satisfy both. Splitting puts `@State` inside the identity boundary.

---

### Task 1: Layout diagnosis harness

This task's deliverable is **a measurement and a decision**, not a fix. Tasks 4 and 5 are written against the assumption that rung 1 wins; if the measurement says otherwise, report it and stop for a ruling before continuing.

**Files:**
- Create: `app/Modules/BobnetLayoutHarness/Sources/main.swift`
- Modify: `app/Modules/Package.swift` (insert an `.executableTarget` immediately after the `BobnetFeatureTests` test target, around line 172)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a decision recorded in the task's commit message — `RUNG 1` (`.id` ordering was the whole thing), `RUNG 2` (needs `containerRelativeFrame`), or `RUNG 3` (AppKit; STOP).

- [ ] **Step 1: Add the executable target to `Package.swift`**

Insert directly after the `BobnetFeatureTests` test target:

```swift
        .executableTarget(
            name: "BobnetLayoutHarness",
            dependencies: [
                "BobnetFeature",
                "GameDatabase",
                "GameModels",
                "UI",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "BobnetLayoutHarness/Sources"
        ),
```

- [ ] **Step 2: Write the harness**

Create `app/Modules/BobnetLayoutHarness/Sources/main.swift`:

```swift
//
//  main.swift — throwaway layout harness for the Bobnet channel switch.
//
//  Hosts the real detail pane in a real NSWindow, switches channels, and reports
//  the backing NSScrollView's geometry so undersized-content placement can be
//  read as numbers rather than guessed from a screenshot.
//

import AppKit
import BobnetFeature
import ComposableArchitecture
import GameDatabase
import GameModels
import SQLiteData
import SwiftUI
import UI

let messageCounts = ["#general": 800, "#trade": 225, "#claims": 12]

func bodyText(_ i: Int) -> String {
    let unit = "Relay traffic nominal, cargo manifest reconciled against the forge queue. "
    let repeats = (i % 17 == 0) ? 8 : (i % 5 == 0) ? 2 : 1
    return String(String(repeating: unit, count: repeats).prefix(i % 17 == 0 ? 574 : 40 + (i % 120)))
}

func seed(_ db: Database) throws {
    var id = 5345
    var rows: [BobnetMessage] = []
    for (channel, count) in messageCounts.sorted(by: { $0.key < $1.key }) {
        for i in 0..<count {
            rows.append(
                BobnetMessage(
                    id: id,
                    replicantName: "Replicant-\(i % 23)",
                    replicantCode: "RPL-\(i % 23)",
                    currentStar: i % 3 == 0 ? nil : "TAU-\(i % 9)",
                    channel: channel,
                    message: bodyText(i),
                    time: Date(timeIntervalSinceNow: -Double(count - i) * 60)
                )
            )
            id += 1
        }
    }
    for row in rows { try BobnetMessage.upsert { row }.execute(db) }
    // Markers sit behind the end so the unread divider actually renders.
    for (channel, _) in messageCounts {
        let maxID = rows.filter { $0.channel == channel }.map(\.id).max() ?? 0
        try BobnetChannel.upsert {
            BobnetChannel(
                name: channel,
                lastActive: Date(timeIntervalSinceNow: -60),
                lastReadMessageID: max(0, maxID - 5)
            )
        }.execute(db)
    }
}

/// Depth-first search for the NSScrollView backing the SwiftUI ScrollView.
func findScrollView(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for subview in view.subviews {
        if let found = findScrollView(subview) { return found }
    }
    return nil
}

func report(_ label: String, _ window: NSWindow) {
    guard let root = window.contentView, let scroll = findScrollView(root) else {
        print("\(label): NO NSSCROLLVIEW FOUND")
        return
    }
    let visible = scroll.contentView.bounds
    let documentHeight = scroll.documentView?.frame.height ?? -1
    let insets = scroll.contentInsets
    // gapBelow = how much content sits below the visible bottom edge. At a true
    // resting bottom this equals insets.bottom; undersized content should be 0.
    let gapBelow = documentHeight - (visible.origin.y + visible.height)
    print(String(
        format: "%@: originY=%8.1f visibleH=%7.1f documentH=%8.1f insets(t=%.0f,b=%.0f) gapBelow=%8.1f",
        label as NSString, visible.origin.y, visible.height,
        documentHeight, insets.top, insets.bottom, gapBelow
    ))
}

prepareDependencies {
    try! $0.bootstrapDatabase { db in try seed(db) }
}

let store = Store(initialState: BobnetFeature.State()) { BobnetFeature() }

struct Root: View {
    @Bindable var store: StoreOf<BobnetFeature>
    var body: some View {
        BobnetChannelDetailView(store: store).frame(width: 700, height: 800)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: Root(store: store))
        window.makeKeyAndOrderFront(nil)

        store.send(.binding(.set(\.selectedChannel, "#general")))
        spin(seconds: 3.0)
        report("long   (#general, 800)", window)

        store.send(.binding(.set(\.selectedChannel, "#claims")))
        spin(seconds: 3.0)
        report("short  (#claims,  12)", window)

        store.send(.binding(.set(\.selectedChannel, "#trade")))
        spin(seconds: 3.0)
        report("long2  (#trade,  225)", window)

        store.send(.binding(.set(\.selectedChannel, "#claims")))
        spin(seconds: 3.0)
        report("short2 (#claims,  12)", window)

        exit(0)
    }

    func spin(seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
            if let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 3: Run the harness against the current code and record the baseline**

Run: `cd app/Modules && swift run -c release BobnetLayoutHarness`

Expected: four lines of geometry. Record all four verbatim — they are the before-state.

**How to read them:**
- `gapBelow ≈ insets.bottom` → resting at the true bottom. Correct.
- `gapBelow` much larger than `insets.bottom` → content sits above the bottom; messages are cut off below the fold. This is symptom 2.
- On `#claims` (12 messages), `documentH < visibleH` means undersized. `originY` should be 0 and the content should be laid out at the *visual bottom* of the document — check `documentH` against `visibleH - insets.bottom`.

**If the harness fails to launch** (window server unavailable, or the process hangs): this task is BLOCKED. Report it and stop — do not guess the diagnosis. The fallback is for the user to observe the running app directly.

- [ ] **Step 4: Move `.id(channel)` above the anchors and re-run**

In `app/Modules/BobnetFeature/Sources/BobnetChannelDetailView.swift`, change lines 53-54 from:

```swift
        .id(channel)
        .defaultScrollAnchor(.bottom)
```

to:

```swift
        .defaultScrollAnchor(.bottom)
        .id(channel)
```

Run: `cd app/Modules && swift run -c release BobnetLayoutHarness`

Record all four lines again.

- [ ] **Step 5: Decide the rung**

Compare the `#claims` lines (`short` and `short2`) before and after.

| After the `.id` move, `#claims` shows | Rung | Action |
|---|---|---|
| `documentH ≈ visibleH` and `gapBelow ≈ insets.bottom` — messages at the visual bottom | **1** | Continue to Task 2 |
| Messages bottom-aligned but `gapBelow` still ≈ 0 with content overlapping the compose-bar region | **2** | Continue to Task 2, and in Task 4 Step 3 also add `.containerRelativeFrame(.vertical, alignment: .bottom)` to the `LazyVStack` |
| An arbitrary `originY` unrelated to either edge | **3** | **STOP.** Report to the user; the design's AppKit rung is now the answer and Tasks 2-6 do not apply |

- [ ] **Step 6: Commit the harness and the measurement**

```bash
git add app/Modules/BobnetLayoutHarness/Sources/main.swift app/Modules/Package.swift app/Modules/BobnetFeature/Sources/BobnetChannelDetailView.swift
git commit -m "chore(bobnet): measure detail-pane scroll geometry across channel switches"
```

Put the eight recorded geometry lines and the rung decision in the commit body. They are the evidence for the whole effort and Task 6 copies them into the memory note.

---

### Task 2: The away-message counter

**Files:**
- Modify: `app/Modules/BobnetFeature/Sources/BobnetFeature.swift`
- Test: `app/Modules/BobnetFeature/Tests/BobnetJumpToLatestTests.swift` (create)

**Interfaces:**
- Consumes: nothing from Task 1 beyond its go/no-go decision.
- Produces: `BobnetFeature.State.newWhileAway: Int` — the count of messages that arrived while `isAtLatest` was false. Task 3 modifies its increment condition; Task 5 renders it.

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/BobnetFeature/Tests/BobnetJumpToLatestTests.swift`:

```swift
//
//  BobnetJumpToLatestTests.swift
//  Replicould — Bobnet feature
//
//  The jump-to-latest affordance's state machine: counting messages that land
//  while the reader is away from the bottom, and zeroing that count wherever
//  the view is known to be pinned to the newest message.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import BobnetFeature

@MainActor
@Suite struct BobnetJumpToLatestTests {
    /// A store over #general (marker 0) with two messages, #general selected.
    private func makeStore(
        clock: TestClock<Duration>
    ) async throws -> (TestStore<BobnetFeature.State, BobnetFeature.Action>, any DatabaseWriter) {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetMessage.upsert { bobnetMessage(1, at: 100) }.execute(db)
            try BobnetMessage.upsert { bobnetMessage(2, at: 200) }.execute(db)
        }
        return try await withDependencies {
            $0.defaultDatabase = database
        } operation: {
            var state = BobnetFeature.State()
            state.selectedChannel = "#general"
            let store = TestStore(initialState: state) {
                BobnetFeature()
            } withDependencies: {
                $0.defaultDatabase = database
                $0.continuousClock = clock
            }
            store.exhaustivity = .off
            try await store.state.$channelList.load(BobnetChannelList())
            return (store, database)
        }
    }

    /// A message landing while the reader is scrolled away is counted.
    @Test func messageWhileAwayIsCounted() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        await store.send(.latestMessageChanged)

        #expect(store.state.newWhileAway == 2)
    }

    /// Reaching the bottom clears the count.
    @Test func reachingBottomClearsTheCount() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        #expect(store.state.newWhileAway == 1)

        await store.send(.binding(.set(\.isAtLatest, true)))
        #expect(store.state.newWhileAway == 0)
    }

    /// Switching channels clears the count — the new channel opens at its bottom.
    @Test func switchingChannelClearsTheCount() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        await store.send(.binding(.set(\.selectedChannel, "#trade")))

        #expect(store.state.newWhileAway == 0)
    }

    /// Re-entering the pane clears the count, the same as `.detailAppeared`
    /// re-establishes `isAtLatest`.
    @Test func reappearingPaneClearsTheCount() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        await store.send(.detailDisappeared("#general"))
        await store.send(.detailAppeared("#general"))

        #expect(store.state.newWhileAway == 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd app/Modules && swift test --filter BobnetJumpToLatestTests \
  --event-stream-output-path /tmp/bobnet-t2.jsonl 2>&1 | tail -5
```

Expected: compile failure — `value of type 'BobnetFeature.State' has no member 'newWhileAway'`.

- [ ] **Step 3: Add the state property**

In `BobnetFeature.State`, immediately after `isAtLatest` (around line 62):

```swift
        /// Messages that landed while the reader was away from the bottom.
        /// Zeroed wherever the view is known to be pinned to the newest message.
        public var newWhileAway: Int = 0
```

- [ ] **Step 4: Wire the transitions**

Change `.binding(\.isAtLatest)` (around line 135) from:

```swift
            case .binding(\.isAtLatest):
                return reevaluateLinger(state)
```

to:

```swift
            case .binding(\.isAtLatest):
                if state.isAtLatest { state.newWhileAway = 0 }
                return reevaluateLinger(state)
```

Change `.latestMessageChanged` (around line 204) from:

```swift
            case .latestMessageChanged:
                return reevaluateLinger(state)
```

to:

```swift
            case .latestMessageChanged:
                if !state.isAtLatest { state.newWhileAway += 1 }
                return reevaluateLinger(state)
```

In `.detailAppeared` (around line 236), after `state.isAtLatest = true`, add:

```swift
                state.newWhileAway = 0
```

In `.detailDisappeared` (around line 245), after `state.isAtLatest = false`, add:

```swift
                state.newWhileAway = 0
```

In `selectionChanged` (around line 317), after `state.isAtLatest = channel != nil`, add:

```swift
        state.newWhileAway = 0
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
cd app/Modules && swift test --filter BobnetJumpToLatestTests \
  --event-stream-output-path /tmp/bobnet-t2.jsonl 2>&1 | tail -5
jq -r 'select(.kind=="event" and .payload.kind=="testCaseEnded") | "\(.payload.testID)"' \
  /tmp/bobnet-t2.jsonl 2>/dev/null | sort -u
```

Expected: 4 tests, 0 failures.

- [ ] **Step 6: Run the existing Bobnet suites to prove nothing regressed**

Run:
```bash
cd app/Modules && swift test --filter 'Bobnet' \
  --event-stream-output-path /tmp/bobnet-t2-all.jsonl 2>&1 | tail -5
jq -r 'select(.payload.kind=="issueRecorded") | .payload.issue.sourceLocation' \
  /tmp/bobnet-t2-all.jsonl 2>/dev/null
```

Expected: no `issueRecorded` lines. The linger suite in particular must stay green.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/BobnetFeature/Sources/BobnetFeature.swift app/Modules/BobnetFeature/Tests/BobnetJumpToLatestTests.swift
git commit -m "feat(bobnet): count messages that land while the reader is scrolled away"
```

---

### Task 3: The bottom-scroll token and in-flight suppression

**Files:**
- Modify: `app/Modules/BobnetFeature/Sources/BobnetFeature.swift`
- Test: `app/Modules/BobnetFeature/Tests/BobnetJumpToLatestTests.swift` (append)

**Interfaces:**
- Consumes: `State.newWhileAway` (Task 2).
- Produces:
  - `State.scrollToBottomToken: Int` — the view watches this and calls `scrollPosition.scrollTo(edge: .bottom)` on every change.
  - `State.pendingBottomScroll: Bool` — true while a requested bottom-scroll has not been observed to land.
  - `Action.jumpToLatestTapped` — sent by `JumpToLatestPill` (Task 5).
  - `Action.pendingScrollExpired` — internal; the 250 ms backstop.

- [ ] **Step 1: Write the failing tests**

Append these four tests inside the `BobnetJumpToLatestTests` suite in `app/Modules/BobnetFeature/Tests/BobnetJumpToLatestTests.swift`:

```swift
    /// A message landing while the reader is AT the bottom asks the view to
    /// follow, and is never counted as unseen.
    @Test func messageWhileAtBottomRequestsAScroll() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, true)))
        let before = store.state.scrollToBottomToken
        await store.send(.latestMessageChanged)

        #expect(store.state.scrollToBottomToken == before + 1)
        #expect(store.state.newWhileAway == 0)
        #expect(store.state.pendingBottomScroll == true)
    }

    /// While a bottom-scroll is in flight, geometry reporting "not at bottom" is
    /// the content having grown under a held viewport — not the reader leaving.
    /// It must not flip the flag or count a message.
    @Test func negativeGeometryDuringPendingScrollIsIgnored() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, true)))
        await store.send(.latestMessageChanged)
        #expect(store.state.pendingBottomScroll == true)

        await store.send(.binding(.set(\.isAtLatest, false)))

        #expect(store.state.isAtLatest == true)
        #expect(store.state.newWhileAway == 0)
    }

    /// The suppression cannot stick: with no geometry report at all, 250 ms
    /// clears it and geometry becomes authoritative again.
    @Test func pendingScrollExpiresWithoutAGeometryReport() async throws {
        let clock = TestClock()
        let (store, _) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await store.send(.latestMessageChanged)
        #expect(store.state.pendingBottomScroll == true)

        await clock.advance(by: .milliseconds(250))
        await store.receive(\.pendingScrollExpired)
        #expect(store.state.pendingBottomScroll == false)

        // Geometry is authoritative once more.
        await store.send(.binding(.set(\.isAtLatest, false)))
        #expect(store.state.isAtLatest == false)

        await store.finish()
    }

    /// Tapping the pill goes to the bottom and clears the count.
    @Test func jumpToLatestScrollsAndClears() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        let before = store.state.scrollToBottomToken

        await store.send(.jumpToLatestTapped)

        #expect(store.state.isAtLatest == true)
        #expect(store.state.newWhileAway == 0)
        #expect(store.state.scrollToBottomToken == before + 1)
    }

    /// Sending a message from scrolled-up history takes the reader to it.
    @Test func sendingScrollsToTheBottom() async throws {
        let (store, _) = try await makeStore(clock: TestClock())

        await store.send(.binding(.set(\.isAtLatest, false)))
        await store.send(.latestMessageChanged)
        let before = store.state.scrollToBottomToken

        await store.send(.sendSucceeded)

        #expect(store.state.isAtLatest == true)
        #expect(store.state.newWhileAway == 0)
        #expect(store.state.scrollToBottomToken == before + 1)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd app/Modules && swift test --filter BobnetJumpToLatestTests \
  --event-stream-output-path /tmp/bobnet-t3.jsonl 2>&1 | tail -5
```

Expected: compile failure — no member `scrollToBottomToken`, no case `jumpToLatestTapped`.

- [ ] **Step 3: Add the state**

In `BobnetFeature.State`, immediately after `newWhileAway`:

```swift
        /// Bumped to ask the view to scroll to the bottom.
        public var scrollToBottomToken: Int = 0
        /// A bottom-scroll was requested and has not been observed to land.
        /// While true, geometry reporting not-at-bottom is stale and ignored.
        public var pendingBottomScroll: Bool = false
```

- [ ] **Step 4: Add the actions**

In `BobnetFeature.Action`, after `case detailAppeared(String?)`:

```swift
        /// The jump-to-latest affordance was tapped.
        case jumpToLatestTapped
        /// The bottom-scroll suppression window closed without the scroll
        /// being observed to land.
        case pendingScrollExpired
```

- [ ] **Step 5: Add the cancel ID and the request helper**

Change the `CancelID` enum (around line 126) from:

```swift
    private enum CancelID { case linger }
```

to:

```swift
    private enum CancelID { case linger, pendingScroll }
```

Add this helper next to `reevaluateLinger` (near line 343):

```swift
    /// Ask the view to scroll to the bottom, holding geometry's negative reports
    /// off until it lands or the window closes — whichever comes first.
    ///
    /// The window is bounded because a stuck `pendingBottomScroll` would freeze
    /// `isAtLatest` at true, which is what advances a read marker under a reader
    /// who has scrolled away.
    private func requestBottomScroll(_ state: inout State) -> Effect<Action> {
        state.scrollToBottomToken += 1
        state.pendingBottomScroll = true
        return .run { send in
            try await clock.sleep(for: .milliseconds(250))
            await send(.pendingScrollExpired)
        }
        .cancellable(id: CancelID.pendingScroll, cancelInFlight: true)
    }
```

- [ ] **Step 6: Rewrite the geometry-report case**

Replace the `.binding(\.isAtLatest)` case written in Task 2 with:

```swift
            case .binding(\.isAtLatest):
                // A negative report while a bottom-scroll is in flight is the
                // content having grown under a held viewport, not a reader leaving.
                if state.pendingBottomScroll, !state.isAtLatest {
                    state.isAtLatest = true
                    return .none
                }
                if state.isAtLatest {
                    state.newWhileAway = 0
                    state.pendingBottomScroll = false
                    return .merge(
                        .cancel(id: CancelID.pendingScroll),
                        reevaluateLinger(state)
                    )
                }
                return reevaluateLinger(state)
```

- [ ] **Step 7: Rewrite `.latestMessageChanged`**

Replace the case written in Task 2 with:

```swift
            case .latestMessageChanged:
                guard state.isAtLatest else {
                    state.newWhileAway += 1
                    return reevaluateLinger(state)
                }
                let scroll = requestBottomScroll(&state)
                return .merge(scroll, reevaluateLinger(state))
```

- [ ] **Step 8: Add the two new action cases and update `.sendSucceeded`**

Add next to `.detailAppeared`:

```swift
            case .jumpToLatestTapped:
                state.isAtLatest = true
                state.newWhileAway = 0
                let scroll = requestBottomScroll(&state)
                return .merge(scroll, reevaluateLinger(state))

            case .pendingScrollExpired:
                state.pendingBottomScroll = false
                return .none
```

Change `.sendSucceeded` (around line 258) from:

```swift
            case .sendSucceeded:
                state.isSending = false
                state.composeText = ""
                return .none
```

to:

```swift
            case .sendSucceeded:
                state.isSending = false
                state.composeText = ""
                state.isAtLatest = true
                state.newWhileAway = 0
                let scroll = requestBottomScroll(&state)
                return .merge(scroll, reevaluateLinger(state))
```

- [ ] **Step 9: Clear the pending flag on every pane and selection transition**

In `.detailAppeared`, after `state.newWhileAway = 0`:

```swift
                state.pendingBottomScroll = false
```

In `.detailDisappeared`, after `state.newWhileAway = 0`:

```swift
                state.pendingBottomScroll = false
```

and change its return from `.cancel(id: CancelID.linger)` to:

```swift
                return .merge(
                    .cancel(id: CancelID.linger),
                    .cancel(id: CancelID.pendingScroll)
                )
```

In `selectionChanged`, after `state.newWhileAway = 0`:

```swift
        state.pendingBottomScroll = false
```

and add `.cancel(id: CancelID.pendingScroll)` to its returned `.merge`.

- [ ] **Step 10: Run the tests to verify they pass**

Run:
```bash
cd app/Modules && swift test --filter BobnetJumpToLatestTests \
  --event-stream-output-path /tmp/bobnet-t3.jsonl 2>&1 | tail -5
jq -r 'select(.payload.kind=="issueRecorded") | .payload.issue.sourceLocation' \
  /tmp/bobnet-t3.jsonl 2>/dev/null
```

Expected: 9 tests, no `issueRecorded` lines.

- [ ] **Step 11: Run every Bobnet suite**

Run:
```bash
cd app/Modules && swift test --filter 'Bobnet' \
  --event-stream-output-path /tmp/bobnet-t3-all.jsonl 2>&1 | tail -5
jq -r 'select(.payload.kind=="issueRecorded") | .payload.issue.sourceLocation' \
  /tmp/bobnet-t3-all.jsonl 2>/dev/null
```

Expected: no failures. `BobnetLingerTests` is the one to watch — `.sendSucceeded` now touches `isAtLatest`.

- [ ] **Step 12: Commit**

```bash
git add app/Modules/BobnetFeature/Sources/BobnetFeature.swift app/Modules/BobnetFeature/Tests/BobnetJumpToLatestTests.swift
git commit -m "feat(bobnet): own the bottom-scroll request in the reducer"
```

---

### Task 4: Split the scroll region out and fix its anchors

**Files:**
- Create: `app/Modules/BobnetFeature/Sources/BobnetChannelMessagesScroll.swift`
- Modify: `app/Modules/BobnetFeature/Sources/BobnetChannelDetailView.swift:33-82`

**Interfaces:**
- Consumes: `State.scrollToBottomToken`, `State.isAtLatest` (Task 3); `BobnetUnreadDivider.anchor(in:marker:)` and `BobnetScrollBottom.isAtBottom(contentOffset:containerHeight:contentHeight:bottomInset:)` (both unchanged, existing).
- Produces: `BobnetChannelMessagesScroll(store:channel:)` — an internal `View` rendering the message list. The caller applies `.id(channel)` to it.

This task is view work with no unit test. Its verification is the harness from Task 1.

- [ ] **Step 1: Create the scroll region view**

Create `app/Modules/BobnetFeature/Sources/BobnetChannelMessagesScroll.swift`:

```swift
//
//  BobnetChannelMessagesScroll.swift
//  Replicould — Bobnet feature
//
//  The channel's message list: oldest first, laid out from the bottom, with the
//  unread divider at the read marker as it stood on selection. Owns the scroll
//  position, so the caller's `.id(channel)` gives each channel a fresh one.
//

import ComposableArchitecture
import SwiftUI
import UI

struct BobnetChannelMessagesScroll: View {
    @Bindable var store: StoreOf<BobnetFeature>
    let channel: String

    @State private var scrollPosition = ScrollPosition(idType: Int.self)

    var body: some View {
        // Bound once per list build. A scroll anchor walks the whole `ForEach`
        // to size the content, so anything O(n) inside the closure is O(n²).
        let firstUnreadID = BobnetUnreadDivider.anchor(
            in: store.channelMessages.messages,
            marker: store.markerAtSelection
        )
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s) {
                ForEach(store.channelMessages.messages) { message in
                    if message.id == firstUnreadID {
                        NewMessagesDivider()
                    }
                    BobnetMessageRow(message: message)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        // Holding the top anchor on growth is what stops a new message moving
        // the viewport out of history.
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            BobnetScrollBottom.isAtBottom(
                contentOffset: geometry.contentOffset.y,
                containerHeight: geometry.containerSize.height,
                contentHeight: geometry.contentSize.height,
                bottomInset: geometry.contentInsets.bottom
            )
        } action: { _, isAtBottom in
            if store.isAtLatest != isAtBottom {
                store.send(.binding(.set(\.isAtLatest, isAtBottom)))
            }
        }
        .onChange(of: store.scrollToBottomToken) {
            scrollPosition.scrollTo(edge: .bottom)
        }
        .onChange(of: store.channelMessages.messages.last?.id) {
            store.send(.latestMessageChanged)
        }
        .onAppear { store.send(.detailAppeared(channel)) }
        .onDisappear { store.send(.detailDisappeared(channel)) }
    }
}
```

**If Task 1 selected rung 2**, additionally add `.containerRelativeFrame(.vertical, alignment: .bottom)` directly after the `.frame(maxWidth: .infinity, alignment: .leading)` line on the `LazyVStack`.

- [ ] **Step 2: Shrink the detail view to composition**

In `app/Modules/BobnetFeature/Sources/BobnetChannelDetailView.swift`, replace the whole `messages(for:)` function (lines 33-82) with:

```swift
    @ViewBuilder
    private func messages(for channel: String) -> some View {
        BobnetChannelMessagesScroll(store: store, channel: channel)
            // Above the anchors and the geometry observer, so a channel switch
            // gives all of them a fresh identity. Deliberately not around the
            // compose bar, which keeps its field identity across a switch.
            .id(channel)
            .background(.rcContentBackground)
            .navigationTitle(channel)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let errorMessage = store.errorMessage {
                    RCErrorBanner(errorMessage) { store.send(.dismissError) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposeBar(store: store, channel: channel)
            }
    }
```

Also update the file header's second paragraph to describe what the file now is — composition, not the list itself. Keep it within the 6-line budget:

```swift
//
//  BobnetChannelDetailView.swift
//  Replicould — Bobnet feature
//
//  The channel-detail pane: the message list, an error banner, and a compose
//  bar. The list and its scroll behaviour live in BobnetChannelMessagesScroll.
//
```

- [ ] **Step 3: Build**

Run: `cd app/Modules && swift build --build-tests 2>&1 | tail -20`

Expected: no errors. `NewMessagesDivider` is `private` in `BobnetChannelDetailView.swift` and is now referenced from `BobnetChannelMessagesScroll.swift` — **change its declaration from `private struct NewMessagesDivider` to `struct NewMessagesDivider`** (module-internal) if the build reports it as inaccessible.

- [ ] **Step 4: Re-run the harness and compare against Task 1's baseline**

Run: `cd app/Modules && swift run -c release BobnetLayoutHarness`

Expected, on all four lines:
- `#claims` (12 messages): content laid out at the visual bottom — `documentH` no greater than `visibleH`, and the messages not floating mid-pane.
- `#general` and `#trade`: `gapBelow ≈ insets.bottom`, meaning resting at the true bottom with nothing hidden under the compose bar.

Record the four lines. If either expectation fails, this is a real result, not a mistake to paper over — report it and stop.

- [ ] **Step 5: Run every Bobnet suite**

Run:
```bash
cd app/Modules && swift test --filter 'Bobnet' \
  --event-stream-output-path /tmp/bobnet-t4.jsonl 2>&1 | tail -5
jq -r 'select(.payload.kind=="issueRecorded") | .payload.issue.sourceLocation' \
  /tmp/bobnet-t4.jsonl 2>/dev/null
```

Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/BobnetFeature/Sources/BobnetChannelMessagesScroll.swift app/Modules/BobnetFeature/Sources/BobnetChannelDetailView.swift
git commit -m "fix(bobnet): give the channel switch a fresh scroll identity and split the anchor by role"
```

Put the four harness lines in the commit body.

---

### Task 5: The jump-to-latest pill

**Files:**
- Create: `app/Modules/BobnetFeature/Sources/JumpToLatestPill.swift`
- Modify: `app/Modules/BobnetFeature/Sources/BobnetChannelDetailView.swift`
- Modify: `app/Modules/BobnetLayoutHarness/Sources/main.swift` (add a pill-placement check)

**Interfaces:**
- Consumes: `State.newWhileAway`, `State.isAtLatest`, `Action.jumpToLatestTapped` (Task 3).
- Produces: `JumpToLatestPill(store:)` — an internal `View` that renders nothing when the reader is at the bottom with nothing new.

- [ ] **Step 1: Create the pill**

Create `app/Modules/BobnetFeature/Sources/JumpToLatestPill.swift`:

```swift
//
//  JumpToLatestPill.swift
//  Replicould — Bobnet feature
//
//  The floating affordance back to the newest message: a count when messages
//  landed while the reader was away, a bare arrow when merely scrolled up.
//

import ComposableArchitecture
import SwiftUI
import UI

struct JumpToLatestPill: View {
    @Bindable var store: StoreOf<BobnetFeature>

    private var label: String? {
        if store.newWhileAway > 0 {
            return "\(store.newWhileAway) new"
        }
        return store.isAtLatest ? nil : ""
    }

    var body: some View {
        if let label {
            Button {
                store.send(.jumpToLatestTapped)
            } label: {
                HStack(spacing: Space.xs) {
                    if !label.isEmpty {
                        Text(label)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcAccent)
                    }
                    Image(systemName: "arrow.down")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcAccent)
                }
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xs)
                .background(Capsule().fill(.bar))
                .overlay(Capsule().stroke(.rcAccent.opacity(0.4), lineWidth: Hairline.thin))
            }
            .buttonStyle(.plain)
            .padding(.bottom, Space.s)
        }
    }
}
```

**Before building**, confirm `Hairline.thin` and `Space.xs` exist in `app/Modules/UI/Sources/DesignSystem.swift`. `Hairline.thin` is used at `Controls.swift:751`, so it does. If `.rcAccent.opacity(0.4)` fails to type-check as a `ShapeStyle`, write `Color.rcAccent.opacity(0.4)`.

- [ ] **Step 2: Wire it into the detail view**

In `BobnetChannelDetailView.messages(for:)`, insert the overlay between the top and bottom safe-area insets — after the `.safeAreaInset(edge: .top…)` block and before `.safeAreaInset(edge: .bottom…)`:

```swift
            .overlay(alignment: .bottom) {
                JumpToLatestPill(store: store)
            }
```

Placing it before the bottom inset is what puts the pill above the compose bar rather than behind it. Step 4 verifies that; if it lands wrong, the fallback is to move `JumpToLatestPill` into the bottom inset's content, wrapping it and `ComposeBar` in a `VStack(spacing: 0)`.

- [ ] **Step 3: Build**

Run: `cd app/Modules && swift build --build-tests 2>&1 | tail -20`

Expected: no errors.

- [ ] **Step 4: Verify the pill's placement in the harness**

Add to `app/Modules/BobnetLayoutHarness/Sources/main.swift`, immediately before the final `exit(0)` in `applicationDidFinishLaunching`:

```swift
        // Scroll up in a long channel, then confirm the pill renders above the
        // compose bar rather than behind it.
        store.send(.binding(.set(\.selectedChannel, "#general")))
        spin(seconds: 2.0)
        store.send(.binding(.set(\.isAtLatest, false)))
        store.send(.latestMessageChanged)
        store.send(.latestMessageChanged)
        spin(seconds: 2.0)
        if let root = window.contentView, let scroll = findScrollView(root) {
            let scrollBottom = scroll.convert(scroll.bounds, to: nil).minY
            print(String(format: "pill: newWhileAway=%d scrollViewBottomY=%.1f",
                         store.newWhileAway, scrollBottom))
        }
        print("pill: capture the window and inspect visually")
```

Run: `cd app/Modules && swift run -c release BobnetLayoutHarness`

Expected: `newWhileAway=2`. Then confirm visually — take a screenshot of the harness window while it is up (`screencapture -o -x /tmp/bobnet-pill.png` from a second shell during the 2-second spin, or extend the spin to 20 seconds temporarily) and read whether the pill sits above the compose bar with its label showing `2 new ↓`.

- [ ] **Step 5: Run every Bobnet suite**

Run:
```bash
cd app/Modules && swift test --filter 'Bobnet' \
  --event-stream-output-path /tmp/bobnet-t5.jsonl 2>&1 | tail -5
jq -r 'select(.payload.kind=="issueRecorded") | .payload.issue.sourceLocation' \
  /tmp/bobnet-t5.jsonl 2>/dev/null
```

Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/BobnetFeature/Sources/JumpToLatestPill.swift app/Modules/BobnetFeature/Sources/BobnetChannelDetailView.swift app/Modules/BobnetLayoutHarness/Sources/main.swift
git commit -m "feat(bobnet): add the jump-to-latest affordance"
```

---

### Task 6: Remove the harness, verify the whole package, record the finding

**Files:**
- Delete: `app/Modules/BobnetLayoutHarness/` (whole directory)
- Modify: `app/Modules/Package.swift` (remove the `.executableTarget`)
- Modify: `app/.claude/memory/bobnet-feature.md`
- Modify: `app/.claude/memory/MEMORY.md`

**Interfaces:**
- Consumes: the harness geometry lines recorded in Tasks 1 and 4, and the rung decision from Task 1 Step 5.
- Produces: nothing downstream.

- [ ] **Step 1: Run the comment checker**

Run:
```bash
cd /Users/matt/Developer/replicant-macos/.claude/worktrees/bobnet-irc-scroll && \
  ./app/scripts/check-comments.sh \
  app/Modules/BobnetFeature/Sources/BobnetChannelMessagesScroll.swift \
  app/Modules/BobnetFeature/Sources/BobnetChannelDetailView.swift \
  app/Modules/BobnetFeature/Sources/JumpToLatestPill.swift \
  app/Modules/BobnetFeature/Sources/BobnetFeature.swift
```

Expected: exit 0. Then read the three new/changed files yourself against the comment budget — the script is eleven regexes and cannot see prose. Any comment carrying history, a rejected alternative, or a date goes to the memory note instead.

- [ ] **Step 2: Run the full package test suite**

Run:
```bash
cd app/Modules && swift test --event-stream-output-path /tmp/bobnet-final.jsonl 2>&1 | tail -10
jq -r 'select(.payload.kind=="issueRecorded") | "\(.payload.issue.sourceLocation.fileID):\(.payload.issue.sourceLocation.line)"' \
  /tmp/bobnet-final.jsonl 2>/dev/null | sort -u
```

Expected: no `issueRecorded` lines, **except** `theSupervisorAdoptsTheRowTheBrainLaunched`, which is a known pre-existing whole-package-only failure (see `app/.claude/memory/supervisor-adopts-row-whole-package-failure.md`) and must not be attributed to this work.

- [ ] **Step 3: Remove the harness**

```bash
cd /Users/matt/Developer/replicant-macos/.claude/worktrees/bobnet-irc-scroll
rm -rf app/Modules/BobnetLayoutHarness
```

Then delete the `.executableTarget(name: "BobnetLayoutHarness", …)` block from `app/Modules/Package.swift`.

- [ ] **Step 4: Verify the package still resolves and builds**

Run: `cd app/Modules && swift package resolve && swift build --build-tests 2>&1 | tail -5`

Expected: no errors.

- [ ] **Step 5: Write the memory note**

Append a section to `app/.claude/memory/bobnet-feature.md`:

```markdown
## The scroll view is bottom-anchored by the reducer, not by one anchor modifier

`.defaultScrollAnchor(.bottom)` was doing three jobs — initial placement,
undersized alignment, and follow-on-growth — and `.id(channel)` sat *below* it,
so a channel switch gave the `ScrollView` a fresh identity while the anchor node
kept its old one. Measured geometry across a switch, real view in a real
`NSWindow`:

| channel | before | after |
|---|---|---|
| … | … | … |

The anchor is now split by role (`.bottom` for `initialOffset` and `alignment`,
`.top` for `sizeChanges`) and `.id(channel)` wraps the whole scroll region,
which lives in `BobnetChannelMessagesScroll` so `@State scrollPosition` is
recreated per channel.

Programmatic scrolling is the reducer's: `scrollToBottomToken` is bumped on a
message arriving while at the bottom, on send, and on the pill tap, and the view
answers it with `scrollPosition.scrollTo(edge: .bottom)`.

`pendingBottomScroll` suppresses geometry's not-at-bottom report while such a
scroll is in flight. Without it a message landing while the reader is *at* the
bottom races: the content grows, the held viewport reports not-at-bottom, and if
that lands before `.latestMessageChanged` the reducer counts a message the
reader watched arrive. The suppression expires after 250 ms so it can never
stick — a frozen-true `isAtLatest` is what advances a read marker under a reader
who has scrolled away.
```

Fill the table from the recorded harness lines. Add the third paragraph naming the rung actually taken if it was not rung 1.

- [ ] **Step 6: Update the memory index**

In `app/.claude/memory/MEMORY.md`, extend the existing `[Bobnet feature]` line with a clause naming the new fact. Do not add a second line — this is the same note.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore(bobnet): remove the layout harness and record the finding"
```

---

## Self-Review

**Spec coverage.**

| Spec section | Task |
|---|---|
| Diagnosis before implementation, the experiment, the ladder | 1 |
| State: `newWhileAway` | 2 |
| State: `scrollToBottomToken`, `pendingBottomScroll` | 3 |
| Actions and transitions table (all 9 rows) | 2 (rows 2, 4, 8, 9), 3 (rows 1, 3, 5, 6, 7) |
| Why `pendingBottomScroll` exists / why the expiry is bounded | 3 (tests), 6 (memory note) |
| The view: `.id` above the anchors, three roles, token scroll | 4 |
| `JumpToLatestPill`, two states | 5 |
| Testing: reducer TestStore cases | 2, 3 |
| Testing: placement evidence into a memory note, not a test | 1, 4, 6 |
| What this does not change (query, `isAtBottom`, `MessageRow`, linger, `firstUnreadID`) | Global Constraints; verified by Task 6 Step 2 |

No gaps.

**Placeholder scan.** The one `…` in the plan is inside a memory-note *template* whose fill instruction is explicit ("Fill the table from the recorded harness lines"). Every code step carries real code.

**Type consistency.** `newWhileAway`, `scrollToBottomToken`, `pendingBottomScroll`, `jumpToLatestTapped`, `pendingScrollExpired`, `requestBottomScroll(_:)`, `CancelID.pendingScroll`, `BobnetChannelMessagesScroll(store:channel:)`, `JumpToLatestPill(store:)` are spelled identically at every appearance. Pre-existing symbols used unchanged: `BobnetUnreadDivider.anchor(in:marker:)`, `BobnetScrollBottom.isAtBottom(contentOffset:containerHeight:contentHeight:bottomInset:)`, `NewMessagesDivider`, `ComposeBar(store:channel:)`, `RCErrorBanner(_:onDismiss:)`, `reevaluateLinger(_:)`, `selectionChanged(_:)`.

**One known cross-task edit.** Task 3 Step 6 and Step 7 rewrite cases that Task 2 Steps 4 wrote. That is deliberate — Task 2 ships the naive counter and Task 2's tests pass against it; Task 3's race tests are what force the suppression. A reviewer can accept Task 2 and reject Task 3 independently.
