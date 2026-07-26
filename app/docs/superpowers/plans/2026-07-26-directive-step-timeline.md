# Directive Step Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a running mission watchable. The detail pane gets a live step timeline off `DirectiveLogEntry` — what the engine did, when, and what it's doing right now — closing spec §7's "sit-back-and-watch view". Every entry it needs is already being written; nothing in the engine changes.

**Architecture:** One `DirectiveTimeline` `FetchKeyRequest` serves **both** row kinds, which is the payoff §2 promised when it gave `DirectiveLogEntry` an optional `directiveID` *and* an optional `deviceCode`: a custom mission's timeline is `directiveID == id`, a built-in directive's completion history is `deviceCode == controller`. It lives in `@Fetch` state and is reloaded on selection change through one `selectionChanged` helper — the `BobnetFeature` channel-messages pattern, which exists for exactly this problem. Rendering is newest-first with a per-kind glyph, and `Text(date, style: .relative)` for times so the view ticks on its own without a timer or a formatter to test.

**Tech Stack:** Swift 6.4, macOS 26+, SQLiteData (`@Fetch`, `FetchKeyRequest`), TCA, Swift Testing.

**Spec:** `2026-07-24-directives-design.md` §7 (custom: "live step timeline fed by `DirectiveLogEntry`"; built-in: "completion history from `DirectiveLogEntry`") and §2 (why the optional pair exists).

## Global Constraints

- SPM root is `app/Modules/` — run `swift` commands there. Paths below are repo-relative.
- **Run tests via the event stream**, per product, and confirm `runEnded` plus no started-without-ended test. See the repo `swift-test-event-stream` skill.
- **The timeline is read-only.** This slice writes no `DirectiveLogEntry` rows and changes no engine behaviour. If a needed entry doesn't exist, note it — don't add engine writes here.
- **`@Fetch` query lives in `@ObservableState`**, view is a pure renderer (house standard).
- **No hard-coded colors, spacing, or font sizes.** Tokens only. **Designations render monospace.** **Row structs in their own file** (Xcode 26 preview JIT crash). **Pure logic never as a static on a SwiftUI `View`.**
- **Logging:** `os.Logger`, subsystem `name.pennig.replicould`, category `Directives`.
- **Commits go to the worktree branch; no PRs.** One commit per task, `git add` scoped to the files touched.
- **Verify with SourceKit-LSP before signing off**; build first — `No such module` on code that compiles is index noise.

---

### Task 1: The `DirectiveTimeline` query

**Files:**
- Create: `app/Modules/DirectivesFeature/Sources/DirectiveTimeline.swift`
- Test: `app/Modules/DirectivesFeature/Tests/DirectiveTimelineTests.swift`

**Interfaces:**
- Produces:
  - `DirectiveTimeline: FetchKeyRequest` with `init(directiveID: String?, deviceCode: String?)` and `Value { entries: [DirectiveLogEntry] }`
  - `DirectiveTimeline.entryLimit: Int` (100)
  - `DirectiveTimeline.request(for: DirectiveRow?) -> DirectiveTimeline` — the row-kind mapping in one place

**Behaviour:**
- A custom row fetches `directiveID == id`; a built-in row fetches `deviceCode == controller`. Never both — the two ids live in different namespaces and mixing them would show a controller's history under a mission that merely drives it.
- **Newest first.** A run accumulates ~6 entries per target, so oldest-first would push the interesting end off screen exactly when the user is watching.
- Capped at `entryLimit`, newest kept. A long multi-target run is unbounded otherwise.
- Nil/nil (nothing selected) fetches nothing rather than everything.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  DirectiveTimelineTests.swift
//  Replicould — Directives feature
//
//  One query, two row kinds — the payoff for `DirectiveLogEntry`'s optional
//  directiveID/deviceCode pair (design spec §2).
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import DirectivesFeature

private func entry(
    _ id: String,
    directiveID: String? = nil,
    deviceCode: String? = nil,
    kind: DirectiveLogKind = .stepStarted,
    at seconds: TimeInterval
) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: directiveID, deviceCode: deviceCode, kind: kind,
        summary: "entry \(id)", step: nil, operationID: nil, eventID: nil,
        occurredAt: Date(timeIntervalSince1970: seconds)
    )
}

@Suite("Directive timeline")
struct DirectiveTimelineTests {
    /// A custom mission's timeline is its own entries, newest first — the end
    /// the user is watching stays at the top.
    @Test func customTimelineIsNewestFirst() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert { entry("L1", directiveID: "D1", at: 10) }.execute(db)
            try DirectiveLogEntry.insert { entry("L2", directiveID: "D1", at: 30) }.execute(db)
            try DirectiveLogEntry.insert { entry("L3", directiveID: "D1", at: 20) }.execute(db)
        }
        let value = try await database.read { db in
            try DirectiveTimeline(directiveID: "D1", deviceCode: nil).fetch(db)
        }
        #expect(value.entries.map(\.id) == ["L2", "L3", "L1"])
    }

    /// Another mission's entries never leak in.
    @Test func customTimelineExcludesOtherMissions() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert { entry("L1", directiveID: "D1", at: 10) }.execute(db)
            try DirectiveLogEntry.insert { entry("L2", directiveID: "D2", at: 20) }.execute(db)
        }
        let value = try await database.read { db in
            try DirectiveTimeline(directiveID: "D1", deviceCode: nil).fetch(db)
        }
        #expect(value.entries.map(\.id) == ["L1"])
    }

    /// A built-in row's history is keyed by DEVICE — the completion entries the
    /// `directive.*` route writes.
    @Test func builtInHistoryIsKeyedByDevice() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                entry("L1", deviceCode: "AMI1", kind: .directiveCompleted, at: 10)
            }.execute(db)
            try DirectiveLogEntry.insert {
                entry("L2", deviceCode: "AMI2", kind: .directiveCompleted, at: 20)
            }.execute(db)
        }
        let value = try await database.read { db in
            try DirectiveTimeline(directiveID: nil, deviceCode: "AMI1").fetch(db)
        }
        #expect(value.entries.map(\.id) == ["L1"])
    }

    /// A completion attributed to a mission AND its controller appears in the
    /// mission's timeline — the route sets both keys on purpose.
    @Test func attributedCompletionAppearsInTheMissionTimeline() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                entry("L1", directiveID: "D1", deviceCode: "AMI1", kind: .directiveCompleted, at: 10)
            }.execute(db)
        }
        let mission = try await database.read { db in
            try DirectiveTimeline(directiveID: "D1", deviceCode: nil).fetch(db)
        }
        let controller = try await database.read { db in
            try DirectiveTimeline(directiveID: nil, deviceCode: "AMI1").fetch(db)
        }
        #expect(mission.entries.map(\.id) == ["L1"])
        #expect(controller.entries.map(\.id) == ["L1"])
    }

    /// Nothing selected fetches nothing — never the whole table.
    @Test func emptyRequestFetchesNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert { entry("L1", directiveID: "D1", at: 10) }.execute(db)
        }
        let value = try await database.read { db in
            try DirectiveTimeline(directiveID: nil, deviceCode: nil).fetch(db)
        }
        #expect(value.entries.isEmpty)
    }

    /// The newest `entryLimit` entries are kept — a long multi-target run is
    /// otherwise unbounded.
    @Test func capsToTheNewestEntries() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for index in 0..<(DirectiveTimeline.entryLimit + 10) {
                try DirectiveLogEntry.insert {
                    entry("L\(index)", directiveID: "D1", at: TimeInterval(index))
                }.execute(db)
            }
        }
        let value = try await database.read { db in
            try DirectiveTimeline(directiveID: "D1", deviceCode: nil).fetch(db)
        }
        #expect(value.entries.count == DirectiveTimeline.entryLimit)
        #expect(value.entries.first?.id == "L\(DirectiveTimeline.entryLimit + 9)", "newest kept")
    }

    /// `request(for:)` maps each row kind to the right key, so no caller has to
    /// remember which id goes in which slot.
    @Test func requestMapsRowKinds() {
        let mission = Directive(
            id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
            targets: ["TAU"], targetIndex: 0, step: "preflight",
            stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        let custom = DirectiveTimeline.request(for: .custom(mission))
        #expect(custom.directiveID == "D1")
        #expect(custom.deviceCode == nil)

        let builtIn = DirectiveTimeline.request(for: .builtIn(
            BuiltInDirective(deviceCode: "AMI1", deviceType: "ami_survey_controller",
                             directive: "survey_system", config: nil, controlledDevices: [])
        ))
        #expect(builtIn.directiveID == nil)
        #expect(builtIn.deviceCode == "AMI1")

        let none = DirectiveTimeline.request(for: nil)
        #expect(none.directiveID == nil)
        #expect(none.deviceCode == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails.** Expected: no `DirectiveTimeline`.

- [ ] **Step 3: Implement**

```swift
//
//  DirectiveTimeline.swift
//  Replicould — Directives feature
//
//  The detail pane's timeline query, serving BOTH row kinds from one table —
//  the payoff for `DirectiveLogEntry`'s optional `directiveID`/`deviceCode`
//  pair (design spec §2). A custom mission's timeline is keyed by directive; a
//  built-in directive's completion history is keyed by its controller.
//
//  Read-only: the engine and the `directive.*` route write every entry this
//  renders, so watching a run costs nothing but the observation.
//

import Foundation
import GameModels
import SQLiteData

public struct DirectiveTimeline: FetchKeyRequest {
    public struct Value: Equatable, Sendable {
        public var entries: [DirectiveLogEntry] = []
        public init(entries: [DirectiveLogEntry] = []) { self.entries = entries }
    }

    /// Most entries any one pane renders. A multi-target run accumulates
    /// roughly six per target and nothing prunes the table.
    public static let entryLimit = 100

    public let directiveID: String?
    public let deviceCode: String?

    public init(directiveID: String?, deviceCode: String?) {
        self.directiveID = directiveID
        self.deviceCode = deviceCode
    }

    /// The request for a selected row — one place that knows which id goes in
    /// which slot. The two namespaces must never be mixed: a controller's
    /// history under a mission that merely drives it would read as the
    /// mission's own work.
    public static func request(for row: DirectiveRow?) -> DirectiveTimeline {
        switch row {
        case let .custom(directive):
            DirectiveTimeline(directiveID: directive.id, deviceCode: nil)
        case let .builtIn(builtIn):
            DirectiveTimeline(directiveID: nil, deviceCode: builtIn.deviceCode)
        case nil:
            DirectiveTimeline(directiveID: nil, deviceCode: nil)
        }
    }

    public func fetch(_ db: Database) throws -> Value {
        // Newest first: a run's interesting end is the latest entry, and the
        // user reading this is watching it happen.
        if let directiveID {
            return Value(entries: try DirectiveLogEntry
                .where { $0.directiveID.eq(directiveID) }
                .order { $0.occurredAt.desc() }
                .limit(Self.entryLimit)
                .fetchAll(db))
        }
        if let deviceCode {
            return Value(entries: try DirectiveLogEntry
                .where { $0.deviceCode.eq(deviceCode) }
                .order { $0.occurredAt.desc() }
                .limit(Self.entryLimit)
                .fetchAll(db))
        }
        return Value()
    }
}
```

If `.limit(_:)` isn't the query builder's spelling here, fetch and `prefix` in Swift, and say which you did.

- [ ] **Step 4: Run the tests.** Expected: green.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectivesFeature/Sources/DirectiveTimeline.swift app/Modules/DirectivesFeature/Tests/DirectiveTimelineTests.swift
git commit -m "Add the directive timeline query"
```

---

### Task 2: Hold the timeline in state, reload on selection

**Files:**
- Modify: `app/Modules/DirectivesFeature/Sources/DirectivesFeature.swift`
- Test: `app/Modules/DirectivesFeature/Tests/DirectivesFeatureTests.swift` (append)

**Interfaces:**
- Produces: `DirectivesFeature.State.timeline: DirectiveTimeline.Value` (via `@Fetch`), and a private `selectionChanged(_:)` helper.

Reload has to happen on **both** paths that change selection: the `selectedRowID` binding (user click) and the launcher's `.created` delegate (which selects the new run programmatically). One helper called from both — the `BobnetFeature.selectionChanged` shape, which exists because missing the second path is the easy bug.

- [ ] **Step 1: Write the failing tests**

```swift
    /// Selecting a mission loads its timeline — and only its own entries.
    @Test func selectingAMissionLoadsItsTimeline() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.stalledMission(id: "D1") }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: "D1", deviceCode: nil, kind: .stepStarted,
                    summary: "Step: configuring", step: "configuring", operationID: nil,
                    eventID: nil, occurredAt: Date(timeIntervalSince1970: 10)
                )
            }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L2", directiveID: "D9", deviceCode: nil, kind: .stepStarted,
                    summary: "someone else", step: nil, operationID: nil,
                    eventID: nil, occurredAt: Date(timeIntervalSince1970: 20)
                )
            }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.selectedRowID, "custom:D1")))
        #expect(store.state.timeline.entries.map(\.id) == ["L1"])
    }

    /// Selecting a built-in row loads that controller's completion history.
    @Test func selectingABuiltInRowLoadsItsHistory() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "survey_system") }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: nil, deviceCode: "AMI1", kind: .directiveCompleted,
                    summary: "Survey System completed at TAU", step: nil, operationID: nil,
                    eventID: "E1", occurredAt: Date(timeIntervalSince1970: 10)
                )
            }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.selectedRowID, "builtin:AMI1")))
        #expect(store.state.timeline.entries.map(\.id) == ["L1"])
    }

    /// Deselecting clears the timeline rather than leaving the last run's
    /// entries under an empty pane.
    @Test func deselectingClearsTheTimeline() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.stalledMission(id: "D1") }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L1", directiveID: "D1", deviceCode: nil, kind: .stepStarted,
                    summary: "Step: configuring", step: "configuring", operationID: nil,
                    eventID: nil, occurredAt: Date(timeIntervalSince1970: 10)
                )
            }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.selectedRowID, "custom:D1")))
        #expect(store.state.timeline.entries.count == 1)
        await store.send(.binding(.set(\.selectedRowID, String?.none)))
        #expect(store.state.timeline.entries.isEmpty)
    }

    /// Launching a run selects it AND loads its (empty) timeline — the
    /// programmatic selection path must not skip the reload.
    @Test func launchingARunLoadsItsTimeline() async throws {
        let database = try GameDatabase.bootstrap()
        let launched = Self.stalledMission(id: "D2")
        try await database.write { db in
            try Directive.insert { launched }.execute(db)
            try DirectiveLogEntry.insert {
                DirectiveLogEntry(
                    id: "L9", directiveID: "D2", deviceCode: nil, kind: .stepStarted,
                    summary: "Step: preflight", step: "preflight", operationID: nil,
                    eventID: nil, occurredAt: Date(timeIntervalSince1970: 10)
                )
            }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: { $0.defaultDatabase = database }
        store.exhaustivity = .off

        await store.send(.newDirective(.presented(.delegate(.created(launched)))))
        #expect(store.state.selectedRowID == "custom:D2")
        #expect(store.state.timeline.entries.map(\.id) == ["L9"])
    }
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement**

In `State`, beside the other queries:

```swift
        /// The selected row's timeline — a mission's steps, or a built-in
        /// directive's completion history. Reloaded on selection change (see
        /// `selectionChanged`), since the query is keyed by what's selected.
        @ObservationStateIgnored
        @Fetch(DirectiveTimeline(directiveID: nil, deviceCode: nil))
        public var timeline = DirectiveTimeline.Value()
```

Add the binding case and reuse it from the launcher path:

```swift
            case .binding(\.selectedRowID):
                return selectionChanged(&state)

            case .binding:
                return .none
```

```swift
            case let .newDirective(.presented(.delegate(.created(directive)))):
                state.selectedRowID = "custom:\(directive.id)"
                return selectionChanged(&state)
```

and the helper:

```swift
    /// Re-run the timeline query for whatever is selected now. Called from BOTH
    /// selection paths — the binding and the launcher's programmatic select —
    /// because missing the second is the easy bug (`BobnetFeature` has the same
    /// helper for the same reason).
    private func selectionChanged(_ state: inout State) -> Effect<Action> {
        let request = DirectiveTimeline.request(for: state.selectedRow)
        return .run { [fetch = state.$timeline] _ in
            _ = try? await fetch.load(request)
        }
    }
```

**Order matters** in the `.created` case: set `selectedRowID` before building the request, or it resolves against the previous selection.

- [ ] **Step 4: Run the tests.** Expected: green, and the existing 42 still pass.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectivesFeature
git commit -m "Load the selected row's timeline"
```

---

### Task 3: Render it

**Files:**
- Create: `app/Modules/DirectivesFeature/Sources/DirectiveTimelineRow.swift`
- Create: `app/Modules/DirectivesFeature/Sources/DirectiveLogPresentation.swift`
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveDetailView.swift`
- Test: `app/Modules/DirectivesFeature/Tests/DirectiveLogPresentationTests.swift`

**Interfaces:**
- Produces:
  - `DirectiveLogPresentation.symbol(for: DirectiveLogKind) -> String`, `.isProminent(_ kind:) -> Bool`
  - `DirectiveTimelineRow` (row struct, own file per the house rule)

Presentation logic goes in a SwiftUI-free namespace, not on the view — the statics-on-a-View trap.

**What the custom pane gains, in order:** the existing header + hold control → the stall panel (when stalled) → a **Now** readout → Targets → **Timeline**. The Now readout is the "in action" part: current step name plus `Text(directive.stepStartedAt, style: .relative)`, which ticks on its own with no timer. Shown only while `.running`.

**What the built-in pane gains:** a "History" section under Controlled Devices, same rows, so a server-run directive finally has the timeline §2 promised it.

- [ ] **Step 1: Write the failing presentation tests**

```swift
@Suite("Directive log presentation")
struct DirectiveLogPresentationTests {
    /// Every kind has a distinct glyph — the timeline is scanned, not read.
    @Test func everyKindHasASymbol() {
        let symbols = DirectiveLogKind.allCases.map(DirectiveLogPresentation.symbol(for:))
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(symbols).count == DirectiveLogKind.allCases.count)
    }

    /// The two kinds that mean "look at me" are prominent; routine ones aren't.
    @Test func onlyNotableKindsAreProminent() {
        #expect(DirectiveLogPresentation.isProminent(.stalled))
        #expect(DirectiveLogPresentation.isProminent(.directiveCompleted))
        #expect(!DirectiveLogPresentation.isProminent(.stepStarted))
        #expect(!DirectiveLogPresentation.isProminent(.commandDispatched))
    }
}
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement the presentation namespace**

```swift
/// Timeline rendering choices, in a SwiftUI-free namespace — pure logic hanging
/// off a `View` traps under `swift test` (see the statics-in-tests memory note).
public enum DirectiveLogPresentation {
    public static func symbol(for kind: DirectiveLogKind) -> String {
        switch kind {
        case .stepStarted: "arrow.forward.circle"
        case .commandDispatched: "paperplane"
        case .opCompleted: "checkmark.circle"
        case .directiveCompleted: "flag.checkered"
        case .stalled: "exclamationmark.triangle.fill"
        case .resolved: "hand.raised"
        }
    }

    /// Whether this entry should stand out. A stall is the one thing in the
    /// timeline the user must act on; a completion is the one they're waiting
    /// for. Everything else is routine progress.
    public static func isProminent(_ kind: DirectiveLogKind) -> Bool {
        kind == .stalled || kind == .directiveCompleted
    }
}
```

- [ ] **Step 4: Build the row and wire both panes**

`DirectiveTimelineRow` (own file): glyph (`.rcWarning` when `kind == .stalled`, `.rcAccent` when `.directiveCompleted`, else `.rcTextTertiary`), summary (`.rcCaption`, primary when prominent else secondary), and `Text(entry.occurredAt, style: .relative)` in `.rcMicroMono`, `.rcTextTertiary`, trailing. If the summary contains a designation it is already embedded in prose from the writer — don't try to mono-split it here.

In `customDetail`, after Targets:

```swift
                timelineSection(title: "Timeline")
```

and in `builtInDetail`, after Controlled Devices:

```swift
                timelineSection(title: "History")
```

with one shared builder:

```swift
    @ViewBuilder
    private func timelineSection(title: String) -> some View {
        if !store.timeline.entries.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                RCSectionHeader(title)
                ForEach(store.timeline.entries) { entry in
                    DirectiveTimelineRow(entry: entry)
                }
            }
        }
    }
```

and the Now readout in `customDetail`, above Targets:

```swift
                if directive.status == .running {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        RCSectionHeader("Now")
                        HStack(spacing: Space.xs) {
                            ProgressView().controlSize(.small)
                            Text(directive.step)
                                .font(.rcBodyEmph)
                                .foregroundStyle(.rcTextPrimary)
                            Text("·").foregroundStyle(.rcTextTertiary)
                            // Ticks on its own — no timer, no formatter.
                            Text(directive.stepStartedAt, style: .relative)
                                .font(.rcMonoSmall)
                                .foregroundStyle(.rcTextSecondary)
                        }
                    }
                }
```

- [ ] **Step 5: Run `DirectivesFeatureTests`.** Expected: green.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectivesFeature
git commit -m "Show the live step timeline in the detail pane"
```

---

### Task 4: Full-suite verification and the memory record

- [ ] **Step 1: Build and run every test product** (the loop from the previous plans; `</dev/null` on `swift test` so it doesn't eat the product list). Expected: `failed: 0`, `crashed: 0`, `runsCompleted` == product count.

- [ ] **Step 2: Record it**

Append to `app/.claude/memory/directives-feature.md`: one `DirectiveTimeline` query serving both row kinds (and that this is what §2's optional `directiveID`/`deviceCode` pair was for); newest-first + the 100 cap; the `selectionChanged` helper called from both selection paths; `Text(date, style: .relative)` instead of a timer; and that **`.opCompleted` entries are still never written** — the timeline shows step transitions and dispatches, so a long travel reads as a quiet gap until the next step starts, which the "Now" readout covers. Update the note's `description:` and the `MEMORY.md` line: the §7 timeline is done, leaving Stage 5 Relay Run.

- [ ] **Step 3: Commit**

```bash
git add app/.claude/memory
git commit -m "Memory: record the step timeline"
```

---

## Self-review

**Spec coverage.** §7 custom "live step timeline fed by `DirectiveLogEntry`" → Tasks 1–3. §7 built-in "completion history from `DirectiveLogEntry`" → same query, Task 3. §2's rationale for the optional id pair → realized.

**Out of scope, deliberately:** writing `.opCompleted` entries. That is engine work (the executor would have to notice a dispatched op closing), this slice is read-only by constraint, and the step-transition entries plus the Now readout already convey progress. Noted in memory as the remaining gap.

**Known risks.** (1) `.limit(_:)` may not be the query builder's spelling — fall back to `prefix` in Swift. (2) `@Fetch`'s initial value must be `DirectiveTimeline.Value()`, not a query that fetches everything, or a pane briefly shows the whole table. (3) `Text(date, style: .relative)` renders "in 2 minutes" for future dates; `stepStartedAt` is always past, so this is fine — but don't reuse the style for `completesAt` without checking.
