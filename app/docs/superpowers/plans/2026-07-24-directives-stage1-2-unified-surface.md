# Directives Stages 1–2 — Composer Extraction + Unified Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working **Directives** screen in the Operations sidebar group that lists built-in AMI device directives beside (an as-yet-empty set of) custom missions, with built-in rows fully reconfigurable and clearable in place — and the schema the engine will need already in the database.

**Architecture:** Stage 1 lifts `DirectiveComposer` out of `DevicesFeature` into a new shared feature-tier module so two parents can present it. Stage 2 adds the `Directive`/`DirectiveLogEntry` tables and a new `DirectivesFeature` whose list merges two typed sources into one row enum — custom rows from the `Directive` table, built-in rows derived live from `Device` rows with no persistence of their own. No engine, no executors, no new event routes: those are Stages 3–5.

**Tech Stack:** Swift / SwiftUI (macOS 26), TCA (`@Reducer`, `@ObservableState`, `@Presents`, `@Dependency`), SQLiteData (`@Table`, `@FetchAll`, `DatabaseMigrator`), Swift Testing.

**Spec:** `app/docs/superpowers/specs/2026-07-24-directives-design.md` — §10 defines this staging. Read §1, §2, §7 before starting.

## Global Constraints

- **Design tokens only.** `Space.*`, `Radius.*`, `.rc*` colors/fonts, `IconSize.*`. Never hard-code a color, spacing value, or font size. Missing token ⇒ add it to `DesignSystem.swift`, don't inline.
- **Designations render mono.** Any system/location/device designation code uses `.rcMono`, `.rcMonoSmall`, or a prominence-matched mono token.
- **Status colors come from `DeviceStatus.tone(for:)`** — never invent per-status colors.
- **Presentation dialect:** a sheet presenting a *feature* uses `@Presents` + enum/optional child state + `.ifLet` + `.sheet(item: $store.scope(…))`. Never `.sheet(isPresented:)` for item-backed sheets. Dismissal must cancel in-flight child effects (`.ifLet` does this structurally — do not add manual cancel plumbing in the parent).
- **List-row structs live in their own file**, never beside a `#Preview` (Xcode 26 preview JIT crash). Same for delegating convenience inits.
- **Pure logic never lives as a static on a SwiftUI `View`** — it traps under `swift test` (signal 5). Put it on reducer `State` or in a plain SwiftUI-free namespace.
- **TCA is for feature modules only, by manifest.** A non-feature module declares `.product(name: "Dependencies", package: "swift-dependencies")` instead.
- **Logging:** `os.Logger` only (no `print`), subsystem `name.pennig.replicould`, category = the module name.
- **Loud test defaults:** a shared client's `testValue` uses `unimplemented(...)`; rich fixtures go on `previewValue`.
- **House header comment style:** `//` / filename / `Replicould — <feature> feature` / blank / one-paragraph purpose note.
- **Run all builds and tests from `app/Modules/`.**
- **Tests:** always `swift test --filter <Suite> --event-stream-output-path <tmpfile>` and read pass/fail from the JSON event stream with `jq` — never grep console text. Use the **`swift-test-event-stream`** skill; it covers the multi-target truncation trap.
- **Swift-LSP protocol:** verify symbols and references with SourceKit-LSP (`documentSymbol`, `goToDefinition`, `findReferences`) before signing off. LSP root is `Modules/`. `0 references` right after session start is usually index warm-up — wait and re-query rather than falling back to grep. The app shell (`app/macOS/*.swift`) is *not* LSP-covered; grep is acceptable for that sliver only.
- **Commits go directly to local `main`** (or a worktree branch merged to it). No PRs, no pushes. Message style matches `git log`. Trailer: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **`.pbxproj` edits are blocked.** Linking a new SPM product to the app target is a **manual user action in Xcode** — Task 7 stops and asks.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `Modules/DirectiveComposerFeature/Sources/DirectiveComposer.swift` | the `set_directive` editor reducer (moved) |
| `Modules/DirectiveComposerFeature/Sources/DirectiveComposerSheet.swift` | its sheet view (moved, made public) |
| `Modules/DirectiveComposerFeature/Tests/DirectiveComposerTests.swift` | its tests (moved) |
| `Modules/GameModels/Sources/Directive.swift` | `Directive` + `DirectiveLogEntry` tables, enums, migrations |
| `Modules/DirectivesFeature/Sources/DirectivesFeature.swift` | the reducer: two `@FetchAll` sources, selection, clear/reconfigure intents |
| `Modules/DirectivesFeature/Sources/DirectiveRow.swift` | the merge model — SwiftUI-free, pure, testable |
| `Modules/DirectivesFeature/Sources/DirectivesListView.swift` | the content pane |
| `Modules/DirectivesFeature/Sources/DirectiveRowView.swift` | one list row (own file per the row-file rule) |
| `Modules/DirectivesFeature/Sources/DirectiveDetailView.swift` | the detail pane, branching on row kind |
| `Modules/DirectivesFeature/Tests/DirectiveRowTests.swift` | merge/derivation logic |
| `Modules/DirectivesFeature/Tests/DirectivesFeatureTests.swift` | reducer flows |

**Modified:** `Modules/Package.swift`, `Modules/GameModels/Sources/DeviceCommandResources.swift` (new, see Task 1), `Modules/DevicesFeature/Sources/DevicePresentation.swift`, `Modules/GameDatabase/Sources/GameDatabase.swift`, `Modules/SidebarFeature/Sources/SidebarItem.swift`, `macOS/MainFeature.swift`, `macOS/ReplicantApp.swift`.

**Why `DirectiveComposerFeature` is its own module:** it owns a `@Reducer`, so it cannot live in `PrintingUI`/`TravelUI` (TCA-free by manifest — `GameModels` + `UI` only). A feature-tier shared leaf with two parents is a new precedent in this package; the alternative (`DirectivesFeature` depending on `DevicesFeature`) would drag the whole device inspector into the graph.

---

# STAGE 1 — Composer extraction

### Task 1: Move `miningResources` to GameModels

The composer sheet reads `DeviceCommand.miningResources`, which lives inside `DevicesFeature`. The resource list is a domain fact, not a view concern, so it moves down rather than being duplicated.

**Files:**
- Create: `Modules/GameModels/Sources/DeviceCommandResources.swift`
- Create: `Modules/GameModels/Tests/MiningResourceTests.swift`
- Modify: `Modules/DevicesFeature/Sources/DevicePresentation.swift:319`

**Interfaces:**
- Produces: `MiningResource.all: [String]` (public, in `GameModels`) — Task 2's sheet and Task 6 rely on this exact name.

- [ ] **Step 1: Write the failing test**

Create `Modules/GameModels/Tests/MiningResourceTests.swift`:

```swift
//
//  MiningResourceTests.swift
//  Replicould — GameModels
//
//  The mining-resource vocabulary is a domain constant shared by the device
//  inspector and the directive composer, so it is pinned here rather than
//  living inside a feature module.
//

import Testing
@testable import GameModels

@Suite("Mining resources")
struct MiningResourceTests {
    /// The six mineable resource types, in the backend's canonical order.
    @Test func vocabularyIsTheSixBackendResources() {
        #expect(MiningResource.all == [
            "structural", "conductive", "silicates", "carbon", "volatiles", "rares",
        ])
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
swift test --filter MiningResourceTests --event-stream-output-path /tmp/es1.jsonl 2>&1 | tail -3
```

Expected: build failure — `cannot find 'MiningResource' in scope`.

- [ ] **Step 3: Add the constant**

Create `Modules/GameModels/Sources/DeviceCommandResources.swift`:

```swift
//
//  DeviceCommandResources.swift
//  Replicould — GameModels
//
//  The mineable resource vocabulary. It lives at the model tier because two
//  feature modules need it — the device inspector's mine/retarget parameter
//  panels and the directive composer's transport requirement/priority editors —
//  and duplicating the list in both would let them drift.
//

import Foundation

/// The resource types a device can mine, in the backend's canonical order.
public enum MiningResource {
    public static let all: [String] = [
        "structural", "conductive", "silicates", "carbon", "volatiles", "rares",
    ]
}
```

- [ ] **Step 4: Point `DeviceCommand` at it**

In `Modules/DevicesFeature/Sources/DevicePresentation.swift`, replace line 319:

```swift
    static let miningResources = ["structural", "conductive", "silicates", "carbon", "volatiles", "rares"]
```

with:

```swift
    /// The mineable resource vocabulary, shared with the directive composer
    /// (which lives in its own module now) — see `MiningResource` in GameModels.
    static let miningResources = MiningResource.all
```

`DevicePresentation.swift` already has `import GameModels`, so no import change is needed. Verify that with `grep -n "^import" Modules/DevicesFeature/Sources/DevicePresentation.swift`.

- [ ] **Step 5: Run the test and the affected targets**

```bash
swift test --filter MiningResourceTests --event-stream-output-path /tmp/es1.jsonl 2>&1 | tail -3
swift test --filter DevicesFeatureTests --event-stream-output-path /tmp/es2.jsonl 2>&1 | tail -3
```

Expected: both pass. Read the verdicts from the event streams per the `swift-test-event-stream` skill, not from this console text.

- [ ] **Step 6: Commit**

```bash
git add Modules/GameModels/Sources/DeviceCommandResources.swift \
        Modules/GameModels/Tests/MiningResourceTests.swift \
        Modules/DevicesFeature/Sources/DevicePresentation.swift
git commit -m "Move the mining-resource vocabulary down to GameModels

The directive composer is about to leave DevicesFeature, and it needs this
list. A domain constant belongs at the model tier anyway; DeviceCommand now
aliases it so the inspector's call sites are untouched.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Create `DirectiveComposerFeature` and move the composer

Pure refactor. **No behaviour change.** The existing `DirectiveComposerTests` suite is the regression net — it must pass unmodified except for its `@testable import`.

**Files:**
- Create: `Modules/DirectiveComposerFeature/Sources/DirectiveComposer.swift` (moved from `Modules/DevicesFeature/Sources/DirectiveComposer.swift`)
- Create: `Modules/DirectiveComposerFeature/Sources/DirectiveComposerSheet.swift` (moved from `Modules/DevicesFeature/Sources/DirectiveComposerSheet.swift`)
- Create: `Modules/DirectiveComposerFeature/Tests/DirectiveComposerTests.swift` (moved from `Modules/DevicesFeature/Tests/DirectiveComposerTests.swift`)
- Delete: the three original paths
- Modify: `Modules/Package.swift`

**Interfaces:**
- Consumes: `MiningResource.all` (Task 1), `BlueprintPresentation.displayName(_:)` (existing, public in `GameModels`).
- Produces: `public struct DirectiveComposer: Reducer` with `State.init(device: Device, fleet: [Device])`, `Action.delegate(.confirmed(directive: String, configuration: [String: JSONValue]?))`, and `public struct DirectiveComposerSheet: View` with `init(store: StoreOf<DirectiveComposer>)`. Tasks 6 and the existing `DeviceDetailView` both rely on these exact names.

- [ ] **Step 1: Create the directories and move the files**

```bash
cd /Users/matt/Developer/replicant-macos/app/Modules
mkdir -p DirectiveComposerFeature/Sources DirectiveComposerFeature/Tests
git mv DevicesFeature/Sources/DirectiveComposer.swift DirectiveComposerFeature/Sources/DirectiveComposer.swift
git mv DevicesFeature/Sources/DirectiveComposerSheet.swift DirectiveComposerFeature/Sources/DirectiveComposerSheet.swift
git mv DevicesFeature/Tests/DirectiveComposerTests.swift DirectiveComposerFeature/Tests/DirectiveComposerTests.swift
```

Using `git mv` keeps the history attached to the files.

- [ ] **Step 2: Add the module to `Package.swift`**

Insert in **alphabetical order (case-insensitive)** — `DirectiveComposerFeature` sorts after `DevicesFeature` and before `EventLogFeature`. Preserve existing formatting and trailing commas; do not reorder unrelated targets.

Append to `products`:

```swift
        .library(
            name: "DirectiveComposerFeature",
            targets: ["DirectiveComposerFeature"]
        ),
```

Append to `targets`:

```swift
        .target(
            name: "DirectiveComposerFeature",
            dependencies: [
                "GameModels",
                "GameServices",
                "UI",
                "UniverseModels",
                "Utils",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "DirectiveComposerFeature/Sources"
        ),
        .testTarget(
            name: "DirectiveComposerFeatureTests",
            dependencies: [
                "DirectiveComposerFeature",
                "GameDatabase",
            ],
            path: "DirectiveComposerFeature/Tests"
        ),
```

Then add `"DirectiveComposerFeature"` to the `DevicesFeature` target's `dependencies` array (alphabetically, after `"DevicesFeature"`'s existing `"GameModels"`… — insert it as the first entry since `D` sorts before `G`).

- [ ] **Step 3: Verify the package still resolves**

```bash
swift package resolve
```

Expected: no error. If it errors, check that the `path:` values match the directories created in Step 1.

- [ ] **Step 4: Fix the two DevicesFeature-internal references in the sheet**

In `DirectiveComposerFeature/Sources/DirectiveComposerSheet.swift`:

Replace the import block (lines 14–17) with:

```swift
import ComposableArchitecture
import GameModels
import SwiftUI
import UI
import UniverseModels
```

Replace line 65's `DevicePresentation.displayName($0)` — `DevicePresentation` is a `DevicesFeature`-internal one-line delegate to the shared GameModels helper, so call that helper directly:

```swift
                options: store.availableDirectives.map {
                    (label: BlueprintPresentation.displayName($0), value: $0)
                },
```

Replace both `DeviceCommand.miningResources` references (lines 231 and 296) with `MiningResource.all`:

```swift
                ForEach(Array(MiningResource.all.enumerated()), id: \.element) { index, resource in
```

```swift
                ForEach(MiningResource.all, id: \.self) { resource in
```

- [ ] **Step 5: Make the moved types public**

`DirectiveComposerSheet` is currently internal — `DeviceDetailView` in another module now needs it. In `DirectiveComposerFeature/Sources/DirectiveComposerSheet.swift`:

```swift
public struct DirectiveComposerSheet: View {
    @Bindable var store: StoreOf<DirectiveComposer>

    public init(store: StoreOf<DirectiveComposer>) {
        self.store = store
    }

    public var body: some View {
```

(The `body` property must become `public` too. Everything below `body` is a private helper and stays as-is.)

In `DirectiveComposerFeature/Sources/DirectiveComposer.swift`, `SurveyScope` is referenced by the sheet from the same module, so it stays internal. Update the header comment's second paragraph, which still claims the file lives in the Devices feature:

```swift
//
//  DirectiveComposer.swift
//  Replicould — Directive composer feature
//
//  The `set_directive` editor, presented as a sheet from the device inspector
//  and from the Directives list (per the presentation rule: live-data /
//  heavy-form commands get a sheet). Seeds its draft from the directive
//  currently in force, validates the configuration the backend requires per
//  directive, and hands the confirmed directive + configuration back to its
//  parent through the delegate. Selecting `gather_salvage` hydrates the
//  controller's system into the local locations catalog so the salvage-body
//  picker can fill; dismissing the sheet cancels that in-flight hydrate (the
//  `.ifLet` presentation tears down child effects automatically).
//
//  It is its own module because two features present it. It owns a reducer, so
//  it cannot live in the TCA-free UI-tier modules (PrintingUI / TravelUI).
//
```

Apply the same `Replicould — Directive composer feature` header line to the sheet and the test file.

- [ ] **Step 6: Retarget the test import**

In `DirectiveComposerFeature/Tests/DirectiveComposerTests.swift`, replace:

```swift
@testable import DevicesFeature
```

with:

```swift
@testable import DirectiveComposerFeature
```

Leave every test body unchanged — that is the point of this task. If a test fails to compile because it referenced a `DevicesFeature` helper, **stop and report it** rather than rewriting the test; it means the composer had a hidden coupling this plan didn't find.

- [ ] **Step 7: Add the import to `DeviceDetailView`**

In `Modules/DevicesFeature/Sources/DeviceDetailView.swift`, add to the import block (alphabetically):

```swift
import DirectiveComposerFeature
```

`DevicesFeature.swift` also references `DirectiveComposer.State` and `DirectiveComposer.Action` (lines 61, 150, 539, 617), so add the same import there.

- [ ] **Step 8: Build and run both test targets**

```bash
swift build 2>&1 | tail -5
swift test --filter DirectiveComposerFeatureTests --event-stream-output-path /tmp/es3.jsonl 2>&1 | tail -3
swift test --filter DevicesFeatureTests --event-stream-output-path /tmp/es4.jsonl 2>&1 | tail -3
```

Expected: clean build; both suites pass with the same test count as before the move. Confirm the counts from the event streams.

- [ ] **Step 9: LSP verification**

Query `findReferences` on `DirectiveComposer` and `DirectiveComposerSheet` and confirm every reference resolves to the new module, with no dangling references left in `DevicesFeature`. Confirm `documentSymbol` on the two moved source files reports the expected public surface.

- [ ] **Step 10: Commit**

```bash
git add -A Modules/DirectiveComposerFeature Modules/DevicesFeature Modules/Package.swift
git commit -m "Extract DirectiveComposer into its own feature module

The Directives list is about to present the same set_directive editor the
device inspector presents. A shared feature-tier leaf keeps that from
becoming a feature-to-feature dependency that would drag the whole device
inspector into the Directives graph. It owns a reducer, so PrintingUI /
TravelUI (TCA-free by manifest) were not an option.

Pure move: the two DevicesFeature-internal references it carried are now
the shared GameModels helpers they always delegated to. Tests move
unchanged apart from their @testable import.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

# STAGE 2 — Schema + unified surface

### Task 3: `Directive` and `DirectiveLogEntry` tables

**Files:**
- Create: `Modules/GameModels/Sources/Directive.swift`
- Create: `Modules/GameModels/Tests/DirectiveSchemaTests.swift`
- Modify: `Modules/GameModels/Sources/Operation.swift:185` (add the `clearDirective` kind)
- Modify: `Modules/GameDatabase/Sources/GameDatabase.swift:33-48`
- Modify: `macOS/ReplicantApp.swift` (`registerSessionCleanup`)

**Interfaces:**
- Produces: `Directive` (`@Table`, `id: String` PK), `DirectiveKind`, `DirectiveStatus`, `DirectiveLogEntry` (`@Table`, `id: String` PK), `DirectiveLogKind`, `OperationKind.clearDirective`. Tasks 4–6 rely on these names.

- [ ] **Step 1: Write the failing test**

Create `Modules/GameModels/Tests/DirectiveSchemaTests.swift`:

```swift
//
//  DirectiveSchemaTests.swift
//  Replicould — GameModels
//
//  The Directive / DirectiveLogEntry tables round-trip through the composed
//  schema. Both are account-scoped and wiped on logout; these tests pin the
//  columns the engine (Stage 3+) and the Directives list depend on.
//

import Foundation
import GameDatabase
import SQLiteData
import Testing
@testable import GameModels

@Suite("Directive schema")
struct DirectiveSchemaTests {
    /// A custom mission round-trips every column, including the JSON target queue.
    @Test func directiveRoundTrips() throws {
        let database = try GameDatabase.bootstrap()
        let directive = Directive(
            id: "D1",
            kind: .surveyRun,
            status: .running,
            deviceCode: "VESSEL1",
            targets: ["TAU", "SHERATANON"],
            targetIndex: 1,
            step: "surveying",
            returnToOrigin: true,
            originDesignation: "SOL",
            attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try database.write { db in try Directive.insert { directive }.execute(db) }

        let loaded = try database.read { db in try Directive.all.fetchAll(db) }
        #expect(loaded == [directive])
        #expect(loaded.first?.targets == ["TAU", "SHERATANON"])
        #expect(loaded.first?.kind == .surveyRun)
        #expect(loaded.first?.returnToOrigin == true)
    }

    /// A log entry attaches to a custom directive OR to a device (a built-in
    /// AMI directive) — the optional pair is what lets one table serve both
    /// row kinds in the Directives list.
    @Test func logEntryAttachesToEitherKind() throws {
        let database = try GameDatabase.bootstrap()
        let custom = DirectiveLogEntry(
            id: "L1", directiveID: "D1", deviceCode: nil,
            kind: .stepStarted, summary: "Travelling to TAU",
            operationID: "OP1", eventID: nil,
            occurredAt: Date(timeIntervalSince1970: 10)
        )
        let builtIn = DirectiveLogEntry(
            id: "L2", directiveID: nil, deviceCode: "AMI1",
            kind: .directiveCompleted, summary: "survey_system completed",
            operationID: nil, eventID: "E9",
            occurredAt: Date(timeIntervalSince1970: 20)
        )
        try database.write { db in
            try DirectiveLogEntry.insert { custom }.execute(db)
            try DirectiveLogEntry.insert { builtIn }.execute(db)
        }

        let loaded = try database.read { db in
            try DirectiveLogEntry.order { $0.occurredAt }.fetchAll(db)
        }
        #expect(loaded == [custom, builtIn])
        #expect(loaded.first?.deviceCode == nil)
        #expect(loaded.last?.directiveID == nil)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
swift test --filter DirectiveSchemaTests --event-stream-output-path /tmp/es5.jsonl 2>&1 | tail -3
```

Expected: build failure — `cannot find 'Directive' in scope`.

- [ ] **Step 3: Write the models and migrations**

Create `Modules/GameModels/Sources/Directive.swift`:

```swift
//
//  Directive.swift
//  Replicould — Directives feature
//
//  A custom directive (a multi-step mission the app executes) and the shared
//  audit trail both directive kinds write to. Built-in AMI directives get NO
//  row here on purpose: the server owns that state and it is already carried on
//  the `Device` row (`ami_directive`), so mirroring it locally would invent a
//  drift bug. `DirectiveLogEntry` is the one thing both kinds share — hence its
//  optional `directiveID` (custom) / `deviceCode` (built-in) pair.
//
//  Both tables are account-scoped and wiped on logout (see
//  `ReplicantApp.registerSessionCleanup`).
//

import Foundation
import SQLiteData

/// Which baked-in procedure a custom directive runs.
public enum DirectiveKind: String, Codable, Equatable, Sendable, CaseIterable, QueryBindable {
    case surveyRun
    case relayRun

    /// The list row's label, e.g. "Survey Run".
    public var title: String {
        switch self {
        case .surveyRun: "Survey Run"
        case .relayRun: "Relay Run"
        }
    }
}

/// A custom directive's lifecycle state. `needsAttention` is the pause-and-surface
/// stall state — the engine never improvises or auto-retries at the mission layer.
public enum DirectiveStatus: String, Codable, Equatable, Sendable, CaseIterable, QueryBindable {
    case running
    case needsAttention
    case paused
    case completed
    case cancelled
}

/// One custom mission instance. Policy-ready by design: nothing here records
/// whether a click or a future standing policy created the row.
@Table
public struct Directive: Identifiable, Equatable, Sendable {
    @Column(primaryKey: true) public var id: String
    public var kind: DirectiveKind
    public var status: DirectiveStatus
    /// The vessel carrying out the mission.
    public var deviceCode: String
    /// The ordered queue of star-system designations still to visit.
    @Column(as: [String].JSONRepresentation.self) public var targets: [String]
    /// How far through `targets` the run is. Equal to `targets.count` when done.
    public var targetIndex: Int
    /// The current step's identifier within the mission's step machine.
    public var step: String
    /// Append a final leg home when the queue empties. Default off — the common
    /// case is chaining onward, and an unwanted return leg costs fuel and time.
    public var returnToOrigin: Bool
    /// The system the run started from, so `returnToOrigin` has a destination.
    public var originDesignation: String?
    /// Set only while `status == .needsAttention`.
    public var attentionReason: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        kind: DirectiveKind,
        status: DirectiveStatus,
        deviceCode: String,
        targets: [String],
        targetIndex: Int,
        step: String,
        returnToOrigin: Bool,
        originDesignation: String?,
        attentionReason: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.deviceCode = deviceCode
        self.targets = targets
        self.targetIndex = targetIndex
        self.step = step
        self.returnToOrigin = returnToOrigin
        self.originDesignation = originDesignation
        self.attentionReason = attentionReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Progress through the queue, for the list row's "m/n" readout.
    public var progress: (completed: Int, total: Int) {
        (min(targetIndex, targets.count), targets.count)
    }

    /// The target currently being worked, or nil when the queue is exhausted.
    public var currentTarget: String? {
        targets.indices.contains(targetIndex) ? targets[targetIndex] : nil
    }
}

/// What a log entry records.
public enum DirectiveLogKind: String, Codable, Equatable, Sendable, CaseIterable, QueryBindable {
    case stepStarted
    case commandDispatched
    case opCompleted
    case directiveCompleted
    case stalled
    case resolved
}

/// One audit-trail entry. Feeds the custom detail pane's live step timeline and
/// the built-in detail pane's completion history.
@Table
public struct DirectiveLogEntry: Identifiable, Equatable, Sendable {
    @Column(primaryKey: true) public var id: String
    /// Set for a custom mission's entry.
    public var directiveID: String?
    /// Set for a built-in AMI directive's entry (keyed by the controller).
    public var deviceCode: String?
    public var kind: DirectiveLogKind
    /// The human-readable line shown in the timeline.
    public var summary: String
    /// The op this entry created or closed, when there is one.
    public var operationID: String?
    /// The SSE event that produced this entry, when there is one.
    public var eventID: String?
    public var occurredAt: Date

    public init(
        id: String,
        directiveID: String?,
        deviceCode: String?,
        kind: DirectiveLogKind,
        summary: String,
        operationID: String?,
        eventID: String?,
        occurredAt: Date
    ) {
        self.id = id
        self.directiveID = directiveID
        self.deviceCode = deviceCode
        self.kind = kind
        self.summary = summary
        self.operationID = operationID
        self.eventID = eventID
        self.occurredAt = occurredAt
    }
}

// MARK: - Schema

extension Directive {
    /// Registers the `directives` table migration. Kept beside the model so the
    /// schema and the type never drift.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'directives' table") { db in
            try #sql(
                """
                CREATE TABLE "directives" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "kind" TEXT NOT NULL,
                  "status" TEXT NOT NULL,
                  "deviceCode" TEXT NOT NULL DEFAULT '',
                  "targets" TEXT NOT NULL DEFAULT '[]',
                  "targetIndex" INTEGER NOT NULL DEFAULT 0,
                  "step" TEXT NOT NULL DEFAULT '',
                  "returnToOrigin" INTEGER NOT NULL DEFAULT 0,
                  "originDesignation" TEXT,
                  "attentionReason" TEXT,
                  "createdAt" TEXT NOT NULL,
                  "updatedAt" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}

extension DirectiveLogEntry {
    /// Registers the `directiveLogEntries` table migration.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'directiveLogEntries' table") { db in
            try #sql(
                """
                CREATE TABLE "directiveLogEntries" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "directiveID" TEXT,
                  "deviceCode" TEXT,
                  "kind" TEXT NOT NULL,
                  "summary" TEXT NOT NULL DEFAULT '',
                  "operationID" TEXT,
                  "eventID" TEXT,
                  "occurredAt" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
            // The timeline reads are always "entries for one directive" or
            // "entries for one device", newest last.
            try #sql(
                """
                CREATE INDEX "directive_log_by_directive"
                  ON "directiveLogEntries" ("directiveID", "occurredAt")
                """
            )
            .execute(db)
            try #sql(
                """
                CREATE INDEX "directive_log_by_device"
                  ON "directiveLogEntries" ("deviceCode", "occurredAt")
                """
            )
            .execute(db)
        }
    }
}
```

**Note on `QueryBindable`:** the enums are stored as their `String` raw values. If SQLiteData's conformance name or requirements differ in this version, check how an existing enum-valued column is declared elsewhere in `GameModels` before inventing something — and if no precedent exists, store the raw `String` and expose a computed typed accessor instead. Build failure here is expected to be caught in Step 5.

- [ ] **Step 4: Name the `clear_directive` operation kind**

`set_directive` has a named kind but `clear_directive` does not, and the new feature dispatches both. Add the missing static beside it in `Modules/GameModels/Sources/Operation.swift` (line 185 area, in the immediate-commands group):

```swift
    public static let clearDirective = OperationKind(rawValue: "clear_directive")
```

`OperationKind`'s `init(rawValue:)` is already public, so this is a discoverability fix rather than a necessity — it keeps a stringly-typed literal out of `DirectivesFeature`'s dispatch path. Confirm the raw value matches the string `CommandClient+Lifecycle.swift:64` matches on (`"clear_directive"`).

- [ ] **Step 5: Register the migrations and the logout wipe**

In `Modules/GameDatabase/Sources/GameDatabase.swift`, add to `migrator()` after the `Device` line (order matters only for tables that reference others; these reference nothing):

```swift
        Directive.registerMigrations(&migrator)
        DirectiveLogEntry.registerMigrations(&migrator)
```

In `macOS/ReplicantApp.swift`'s `registerSessionCleanup()`, add a handler alongside the others (before the `eventCursor` handler):

```swift
        // Directives are account-scoped: a second account on this machine must
        // not inherit the first's missions or their audit trail. Stage 3 adds
        // the engine, whose executors are cancelled by the gameSync handler
        // registered FIRST — so the wipe below can never race a live write.
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "directives", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in
                    try Directive.delete().execute(db)
                    try DirectiveLogEntry.delete().execute(db)
                }
            })
        )
```

- [ ] **Step 6: Run the test**

```bash
swift test --filter DirectiveSchemaTests --event-stream-output-path /tmp/es5.jsonl 2>&1 | tail -3
```

Expected: both tests pass.

- [ ] **Step 7: Commit**

```bash
git add Modules/GameModels/Sources/Directive.swift \
        Modules/GameModels/Sources/Operation.swift \
        Modules/GameModels/Tests/DirectiveSchemaTests.swift \
        Modules/GameDatabase/Sources/GameDatabase.swift \
        macOS/ReplicantApp.swift
git commit -m "Add the Directive and DirectiveLogEntry tables

Custom missions get a row; built-in AMI directives deliberately do not —
the server owns that state and the Device row already carries it, so a
local mirror would only invent drift. The log entry's optional
directiveID/deviceCode pair is what lets one audit table serve both kinds,
which is what gives a built-in row a real timeline instead of a static
config readout.

Both tables are account-scoped and wiped on logout.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The `DirectiveRow` merge model

The list's core logic, kept SwiftUI-free so it is testable (per the View-statics trap).

**Files:**
- Create: `Modules/DirectivesFeature/Sources/DirectiveRow.swift`
- Create: `Modules/DirectivesFeature/Tests/DirectiveRowTests.swift`
- Modify: `Modules/Package.swift`

**Interfaces:**
- Consumes: `Device` (`currentDirective`, `currentDirectiveConfig`, `controlledDevices`, `deviceCode`, `deviceType`, `status`, `location`), `Directive` (Task 3).
- Produces: `BuiltInDirective`, `DirectiveRow` (with `.builtIn` / `.custom` cases, `id`, `title`, `deviceCode`, `sortKey`), `DirectiveRow.merge(devices:directives:)`. Tasks 5 and 6 rely on these.

- [ ] **Step 1: Add the module to `Package.swift`**

Insert alphabetically (`DirectivesFeature` sorts after `DirectiveComposerFeature`).

Append to `products`:

```swift
        .library(
            name: "DirectivesFeature",
            targets: ["DirectivesFeature"]
        ),
```

Append to `targets`:

```swift
        .target(
            name: "DirectivesFeature",
            dependencies: [
                "DirectiveComposerFeature",
                "GameModels",
                "GameServices",
                "UI",
                "Utils",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "DirectivesFeature/Sources"
        ),
        .testTarget(
            name: "DirectivesFeatureTests",
            dependencies: [
                "DirectivesFeature",
                "GameDatabase",
            ],
            path: "DirectivesFeature/Tests"
        ),
```

```bash
mkdir -p DirectivesFeature/Sources DirectivesFeature/Tests
swift package resolve
```

- [ ] **Step 2: Write the failing tests**

Create `Modules/DirectivesFeature/Tests/DirectiveRowTests.swift`:

```swift
//
//  DirectiveRowTests.swift
//  Replicould — Directives feature
//
//  The unified list's merge: built-in rows derived from Device state (never
//  persisted) beside custom rows from the Directive table, in one stable order.
//

import Foundation
import GameModels
import Testing
import Utils
@testable import DirectivesFeature

/// A device fixture. `detail` carries the in-force `ami_directive` block when
/// `directive` is set, mirroring what the backend sends.
private func device(
    code: String,
    type: String = "ami_survey_controller",
    directive: String? = nil,
    config: JSONValue? = nil,
    controlled: [JSONValue] = []
) -> Device {
    var detail: [String: JSONValue] = [:]
    if let directive {
        var block: [String: JSONValue] = ["name": .string(directive)]
        if let config { block["config"] = config }
        detail["ami_directive"] = .object(block)
    }
    if !controlled.isEmpty { detail["controlled_devices"] = .array(controlled) }
    return Device(
        deviceCode: code,
        deviceType: type,
        replicantCode: "R1",
        status: "idle",
        location: "ATIANFU-3",
        locationName: nil,
        operationalCapacity: 100,
        queueSize: 0,
        stowedInDeviceCode: nil,
        controllerDeviceCode: nil,
        attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [],
        features: [],
        tags: [],
        detail: .object(detail),
        updatedAt: Date(timeIntervalSince1970: 0),
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func mission(id: String, kind: DirectiveKind = .surveyRun) -> Directive {
    Directive(
        id: id, kind: kind, status: .running, deviceCode: "VESSEL1",
        targets: ["TAU", "SHERATANON"], targetIndex: 1, step: "surveying",
        returnToOrigin: false, originDesignation: "SOL", attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("Directive rows")
struct DirectiveRowTests {
    /// Only devices with a directive in force become built-in rows.
    @Test func derivesBuiltInRowsFromDevicesWithADirective() {
        let rows = DirectiveRow.merge(
            devices: [
                device(code: "AMI1", directive: "survey_system"),
                device(code: "AMI2"),
                device(code: "AMI3", directive: "gather_salvage"),
            ],
            directives: []
        )
        #expect(rows.count == 2)
        #expect(rows.map(\.deviceCode) == ["AMI1", "AMI3"])
    }

    /// A built-in row carries the config and controlled devices the detail pane
    /// renders, straight off the Device row.
    @Test func builtInRowCarriesConfigAndControlledDevices() {
        let rows = DirectiveRow.merge(
            devices: [device(
                code: "AMI1",
                directive: "survey_system",
                config: .object(["planets": .string("all"), "moons": .string("all")]),
                controlled: [.object([
                    "device_code": .string("DRONE1"),
                    "device_type": .string("survey_drone"),
                    "status": .string("tracking"),
                ])]
            )],
            directives: []
        )
        guard case let .builtIn(builtIn)? = rows.first else {
            Issue.record("expected a built-in row")
            return
        }
        #expect(builtIn.directive == "survey_system")
        #expect(builtIn.config?["planets"]?.stringValue == "all")
        #expect(builtIn.controlledDevices.map(\.deviceCode) == ["DRONE1"])
    }

    /// Custom rows and built-in rows coexist; custom rows sort first so an
    /// actively-running mission is never buried under the standing set.
    @Test func customRowsSortAheadOfBuiltIns() {
        let rows = DirectiveRow.merge(
            devices: [device(code: "AMI1", directive: "survey_system")],
            directives: [mission(id: "D1")]
        )
        #expect(rows.count == 2)
        #expect(rows.first?.id == "custom:D1")
        #expect(rows.last?.id == "builtin:AMI1")
    }

    /// Row ids are stable and namespaced, so a device code and a directive id
    /// can never collide in the selection.
    @Test func rowIDsAreNamespaced() {
        let rows = DirectiveRow.merge(
            devices: [device(code: "X", directive: "patrol")],
            directives: [mission(id: "X")]
        )
        #expect(Set(rows.map(\.id)) == ["custom:X", "builtin:X"])
    }

    /// A custom row's title names the mission and its current target.
    @Test func customRowTitleNamesKindAndTarget() {
        let rows = DirectiveRow.merge(devices: [], directives: [mission(id: "D1")])
        #expect(rows.first?.title == "Survey Run → SHERATANON")
    }
}
```

- [ ] **Step 3: Run and confirm failure**

```bash
swift test --filter DirectiveRowTests --event-stream-output-path /tmp/es6.jsonl 2>&1 | tail -3
```

Expected: build failure — `cannot find 'DirectiveRow' in scope`.

- [ ] **Step 4: Write the merge model**

Create `Modules/DirectivesFeature/Sources/DirectiveRow.swift`:

```swift
//
//  DirectiveRow.swift
//  Replicould — Directives feature
//
//  The unified list's row model. Two sources, one view model: custom missions
//  come from the `Directive` table, built-in AMI directives are DERIVED from
//  `Device` rows and never persisted — the server owns that state, so a derived
//  row is structurally incapable of drifting from it.
//
//  Deliberately SwiftUI-free: this is the list's only real logic, and pure
//  logic hanging off a SwiftUI View traps under `swift test`.
//

import Foundation
import GameModels
import Utils

/// An AMI directive currently in force on a device, projected for the list.
public struct BuiltInDirective: Equatable, Identifiable, Sendable {
    public let deviceCode: String
    public let deviceType: String
    /// The directive's backend name, e.g. `survey_system`.
    public let directive: String
    /// Its in-force configuration, or nil for directives that take none.
    public let config: JSONValue?
    /// The drones this controller is running, with their live status.
    public let controlledDevices: [Device.ControlledDevice]

    public var id: String { deviceCode }

    public init(
        deviceCode: String,
        deviceType: String,
        directive: String,
        config: JSONValue?,
        controlledDevices: [Device.ControlledDevice]
    ) {
        self.deviceCode = deviceCode
        self.deviceType = deviceType
        self.directive = directive
        self.config = config
        self.controlledDevices = controlledDevices
    }
}

/// One row of the Directives list — either kind.
public enum DirectiveRow: Equatable, Identifiable, Sendable {
    case custom(Directive)
    case builtIn(BuiltInDirective)

    /// Namespaced so a device code and a directive id can never collide in the
    /// list's selection.
    public var id: String {
        switch self {
        case let .custom(directive): "custom:\(directive.id)"
        case let .builtIn(builtIn): "builtin:\(builtIn.deviceCode)"
        }
    }

    /// The device the row is about — the vessel for a mission, the controller
    /// for a built-in directive.
    public var deviceCode: String {
        switch self {
        case let .custom(directive): directive.deviceCode
        case let .builtIn(builtIn): builtIn.deviceCode
        }
    }

    /// The row's headline. Missions name their current target; built-ins name
    /// the directive.
    public var title: String {
        switch self {
        case let .custom(directive):
            if let target = directive.currentTarget {
                return "\(directive.kind.title) → \(target)"
            }
            return directive.kind.title
        case let .builtIn(builtIn):
            return BlueprintPresentation.displayName(builtIn.directive)
        }
    }

    /// Custom missions sort ahead of the standing built-in set, so an actively
    /// running mission is never buried under it. Within a kind, ordering is the
    /// caller's (the queries are already ordered).
    var sortRank: Int {
        switch self {
        case .custom: 0
        case .builtIn: 1
        }
    }

    /// Merge the two sources into one ordered list. `devices` contributes a row
    /// for each device with a directive in force; `directives` contributes one
    /// per custom mission.
    public static func merge(devices: [Device], directives: [Directive]) -> [DirectiveRow] {
        let custom = directives.map { DirectiveRow.custom($0) }
        let builtIn = devices.compactMap { device -> DirectiveRow? in
            guard let directive = device.currentDirective, !directive.isEmpty else { return nil }
            return .builtIn(
                BuiltInDirective(
                    deviceCode: device.deviceCode,
                    deviceType: device.deviceType,
                    directive: directive,
                    config: device.currentDirectiveConfig,
                    controlledDevices: device.controlledDevices
                )
            )
        }
        return custom + builtIn
    }
}
```

- [ ] **Step 5: Run the tests**

```bash
swift test --filter DirectiveRowTests --event-stream-output-path /tmp/es6.jsonl 2>&1 | tail -3
```

Expected: all five pass. If the `Device` initializer's parameter list differs from the fixture, fix the **fixture** to match the real initializer — do not change `Device`.

- [ ] **Step 6: Commit**

```bash
git add Modules/DirectivesFeature Modules/Package.swift
git commit -m "Add the DirectivesFeature module and its row merge model

Two sources, one view model: custom missions from the Directive table,
built-in rows derived live from Device rows. Row ids are namespaced so a
device code and a directive id can't collide in the selection, and custom
rows sort ahead of the standing built-in set.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: The reducer and the list pane

**Files:**
- Create: `Modules/DirectivesFeature/Sources/DirectivesFeature.swift`
- Create: `Modules/DirectivesFeature/Sources/DirectivesListView.swift`
- Create: `Modules/DirectivesFeature/Sources/DirectiveRowView.swift`
- Create: `Modules/DirectivesFeature/Tests/DirectivesFeatureTests.swift`

**Interfaces:**
- Consumes: `DirectiveRow.merge(devices:directives:)` (Task 4).
- Produces: `DirectivesFeature` (`State.init(selectedRowID:)`, `state.rows: [DirectiveRow]`, `state.selectedRow: DirectiveRow?`, `Action.binding`, `.reconfigureTapped`, `.clearTapped`, `.clearConfirmed(deviceCode:)`, `.commandFinished(CommandOutcome)`, `.dismissError`), `DirectivesListView`, `DirectiveRowView`. Task 6 and Task 7 rely on these.

- [ ] **Step 1: Write the failing reducer test**

Create `Modules/DirectivesFeature/Tests/DirectivesFeatureTests.swift`:

```swift
//
//  DirectivesFeatureTests.swift
//  Replicould — Directives feature
//
//  The list reducer: rows come from the two live queries, selection resolves to
//  a row, and clearing a built-in directive dispatches clear_directive and
//  confirms through the device refresher.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import Utils
@testable import DirectivesFeature

@Suite("Directives feature")
@MainActor
struct DirectivesFeatureTests {
    /// A device with an in-force directive shows up as a built-in row, with no
    /// row ever written to the Directive table.
    @Test func builtInRowsComeFromTheFleet() async throws {
        let database = try GameDatabase.bootstrap()
        try database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "survey_system") }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        #expect(store.state.rows.map(\.id) == ["builtin:AMI1"])
        let persisted = try database.read { db in try Directive.all.fetchAll(db) }
        #expect(persisted.isEmpty)
    }

    /// Selecting a row resolves it; an unknown id resolves to nil rather than
    /// crashing the detail pane.
    @Test func selectionResolvesToARow() async throws {
        let database = try GameDatabase.bootstrap()
        try database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "patrol") }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "builtin:AMI1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        #expect(store.state.selectedRow?.deviceCode == "AMI1")

        await store.send(.binding(.set(\.selectedRowID, "builtin:NOPE")))
        #expect(store.state.selectedRow == nil)
    }

    /// Clearing dispatches clear_directive for the selected controller and
    /// confirms the result through the shared device refresher.
    @Test func clearDispatchesClearDirective() async throws {
        let database = try GameDatabase.bootstrap()
        try database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "survey_system") }.execute(db)
        }
        let dispatched = LockIsolated<(OperationKind, String)?>(nil)
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "builtin:AMI1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { kind, code, _ in
                dispatched.setValue((kind, code))
                return .accepted(operationID: nil)
            }
            $0.deviceRefresher.refresh = { _, _ in nil }
        }
        store.exhaustivity = .off

        await store.send(.clearConfirmed(deviceCode: "AMI1"))
        await store.receive(\.commandFinished)
        #expect(dispatched.value?.0 == .clearDirective)
        #expect(dispatched.value?.1 == "AMI1")
    }

    /// A rejected clear surfaces its message instead of failing silently.
    @Test func rejectedClearSurfacesTheMessage() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: DirectivesFeature.State()) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { _, _, _ in .rejected("No directive in force.") }
            $0.deviceRefresher.refresh = { _, _ in nil }
        }
        store.exhaustivity = .off

        await store.send(.clearConfirmed(deviceCode: "AMI1"))
        await store.receive(\.commandFinished)
        #expect(store.state.errorMessage == "No directive in force.")
    }

    /// An AMI controller fixture carrying an in-force directive.
    static func controller(code: String, directive: String) -> Device {
        Device(
            deviceCode: code,
            deviceType: "ami_survey_controller",
            replicantCode: "R1",
            status: "idle",
            location: "ATIANFU-3",
            locationName: nil,
            operationalCapacity: 100,
            queueSize: 0,
            stowedInDeviceCode: nil,
            controllerDeviceCode: nil,
            attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: ["set_directive", "clear_directive"],
            features: [],
            tags: [],
            detail: .object(["ami_directive": .object(["name": .string(directive)])]),
            updatedAt: Date(timeIntervalSince1970: 0),
            firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }
}
```

- [ ] **Step 2: Run and confirm failure**

```bash
swift test --filter DirectivesFeatureTests --event-stream-output-path /tmp/es7.jsonl 2>&1 | tail -3
```

Expected: build failure — `cannot find 'DirectivesFeature' in scope`.

- [ ] **Step 3: Write the reducer**

Create `Modules/DirectivesFeature/Sources/DirectivesFeature.swift`:

```swift
//
//  DirectivesFeature.swift
//  Replicould — Directives feature
//
//  The unified Directives surface: built-in AMI directives (derived from the
//  fleet, server-executed) beside custom multi-step missions (the Directive
//  table, app-executed). Both queries live in state per the house standard, so
//  the views stay pure renderers and the list never flashes empty.
//
//  There is no engine yet — Stage 3 adds it. Today the custom half of the list
//  is simply empty, and the feature's only writes are the built-in half's
//  Reconfigure (via the shared composer) and Clear.
//

import ComposableArchitecture
import DirectiveComposerFeature
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Directives")

@Reducer
public struct DirectivesFeature {
    @ObservableState
    public struct State: Equatable {
        /// The fleet — the source of every built-in row. `currentDirective` is
        /// read out of the device's JSON tail, not a column, so the filter runs
        /// in Swift (see `DirectiveRow.merge`) rather than in SQL.
        @ObservationStateIgnored
        @FetchAll(Device.order { $0.deviceCode }, animation: .default)
        public var devices: [Device]

        /// Custom missions, newest first.
        @ObservationStateIgnored
        @FetchAll(Directive.order { $0.createdAt.desc() }, animation: .default)
        public var directives: [Directive]

        /// The selected row's namespaced id (see `DirectiveRow.id`).
        public var selectedRowID: String?
        /// A failed or rejected command, shown as a banner over the list.
        public var errorMessage: String?
        /// The `set_directive` editor, presented from a built-in row's detail
        /// pane. Feature-tier sheet ⇒ `@Presents` + `.ifLet`.
        @Presents public var composer: DirectiveComposer.State?

        public init(selectedRowID: String? = nil) {
            self.selectedRowID = selectedRowID
        }

        /// The merged list.
        public var rows: [DirectiveRow] {
            DirectiveRow.merge(devices: devices, directives: directives)
        }

        /// The selected row, or nil when nothing (or something stale) is selected.
        public var selectedRow: DirectiveRow? {
            guard let selectedRowID else { return nil }
            return rows.first { $0.id == selectedRowID }
        }

        /// The full `Device` behind the selected row — the composer needs it,
        /// and the detail pane reads its status.
        public var selectedDevice: Device? {
            guard let code = selectedRow?.deviceCode else { return nil }
            return devices.first { $0.deviceCode == code }
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// Open the composer on the selected built-in row.
        case reconfigureTapped
        /// Clear the selected built-in row's directive.
        case clearTapped
        /// Confirmed clear for a specific controller.
        case clearConfirmed(deviceCode: String)
        case commandFinished(CommandOutcome)
        case dismissError
        case composer(PresentationAction<DirectiveComposer.Action>)
    }

    public init() {}

    @Dependency(\.commandClient) var commandClient
    @Dependency(\.deviceRefresher) var deviceRefresher

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .reconfigureTapped:
                guard let device = state.selectedDevice else { return .none }
                logger.info("directive composer \(device.deviceCode, privacy: .public) presented")
                state.composer = DirectiveComposer.State(device: device, fleet: state.devices)
                return .none

            case .clearTapped:
                guard let code = state.selectedRow?.deviceCode else { return .none }
                return .send(.clearConfirmed(deviceCode: code))

            case let .clearConfirmed(code):
                return dispatch(.clearDirective, code, CommandParams())

            case let .composer(.presented(.delegate(.confirmed(directive, configuration)))):
                guard let code = state.composer?.deviceCode else { return .none }
                return dispatch(
                    .setDirective,
                    code,
                    CommandParams(directive: directive, configuration: configuration)
                )

            case .composer:
                return .none

            case let .commandFinished(outcome):
                switch outcome {
                case .accepted:
                    state.errorMessage = nil
                case let .rejected(message), let .failed(message):
                    logger.notice("directive command failed: \(message, privacy: .public)")
                    state.errorMessage = message
                }
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none
            }
        }
        .ifLet(\.$composer, action: \.composer) {
            DirectiveComposer()
        }
    }

    /// Dispatch a command and confirm it with a high-priority device read, so
    /// the row reflects the new directive without waiting for the SSE echo.
    private func dispatch(
        _ kind: OperationKind,
        _ deviceCode: String,
        _ params: CommandParams
    ) -> Effect<Action> {
        let commandClient = self.commandClient
        let deviceRefresher = self.deviceRefresher
        return .run { send in
            let outcome = await commandClient.dispatch(kind, deviceCode, params)
            _ = await deviceRefresher.refresh(deviceCode, .high)
            await send(.commandFinished(outcome))
        }
    }
}
```

- [ ] **Step 4: Run the reducer tests**

```bash
swift test --filter DirectivesFeatureTests --event-stream-output-path /tmp/es7.jsonl 2>&1 | tail -3
```

Expected: all four pass. If `deviceRefresher.refresh`'s signature or `OperationKind`'s `init(rawValue:)` differ, adjust the **call site** to the real signature (check with LSP `hover`), not the dependency.

- [ ] **Step 5: Write the row view**

Create `Modules/DirectivesFeature/Sources/DirectiveRowView.swift` (its own file — the row-file rule):

```swift
//
//  DirectiveRowView.swift
//  Replicould — Directives feature
//
//  One row of the unified list. The kind badge is the whole point of the
//  surface: built-in directives the server runs, custom missions the app runs.
//

import GameModels
import SwiftUI
import UI

struct DirectiveRowView: View {
    let row: DirectiveRow

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: IconSize.m))
                .foregroundStyle(.rcAccent)
                .frame(width: IconSize.m)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(row.title)
                    .font(.rcBodyEmph)
                    .foregroundStyle(.rcTextPrimary)
                    .lineLimit(1)
                HStack(spacing: Space.xs) {
                    Text(row.deviceCode)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                    if let subtitle {
                        Text("·").foregroundStyle(.rcTextTertiary)
                        Text(subtitle)
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
            kindBadge
        }
        .padding(.vertical, Space.xs)
    }

    /// Missions carry a host glyph; built-ins carry the AMI brain.
    private var symbol: String {
        switch row {
        case .custom: "flag.checkered"
        case .builtIn: "brain.head.profile"
        }
    }

    /// Progress for a mission; the controlled-drone count for a built-in.
    private var subtitle: String? {
        switch row {
        case let .custom(directive):
            let progress = directive.progress
            return "\(progress.completed)/\(progress.total)"
        case let .builtIn(builtIn):
            let count = builtIn.controlledDevices.count
            return count > 0 ? "\(count) controlled" : nil
        }
    }

    private var kindBadge: some View {
        Text(badgeLabel)
            .font(.rcMicroMono)
            .foregroundStyle(.rcTextTertiary)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: 1)
            )
    }

    private var badgeLabel: String {
        switch row {
        case .custom: "CUSTOM"
        case .builtIn: "BUILT-IN"
        }
    }
}
```

**Token check:** `Space.xxs`, `.rcBodyEmph`, `.rcMicroMono`, `IconSize.m`, `Radius.control` must all exist in `DesignSystem.swift`. Verify with `grep -n "xxs\|rcBodyEmph\|rcMicroMono" Modules/UI/Sources/DesignSystem.swift`. If one is missing, **add the token to the design system** rather than inlining a value.

- [ ] **Step 6: Write the list view**

Create `Modules/DirectivesFeature/Sources/DirectivesListView.swift`:

```swift
//
//  DirectivesListView.swift
//  Replicould — Directives feature
//
//  The content pane: one selectable list holding both directive kinds. A pure
//  renderer — every query lives in the reducer's state.
//

import ComposableArchitecture
import SwiftUI
import UI

public struct DirectivesListView: View {
    @Bindable var store: StoreOf<DirectivesFeature>

    public init(store: StoreOf<DirectivesFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.rows.isEmpty {
                RCContentUnavailableView(
                    "No Directives",
                    systemImage: "brain.head.profile",
                    description: "Set a directive on an AMI controller from the device inspector, or launch a mission."
                )
            } else {
                List(selection: $store.selectedRowID) {
                    ForEach(store.rows) { row in
                        DirectiveRowView(row: row).tag(row.id)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let message = store.errorMessage {
                RCErrorBanner(message: message) { store.send(.dismissError) }
                    .padding(Space.s)
            }
        }
        .navigationTitle("Directives")
    }
}
```

**API check:** confirm `RCContentUnavailableView`'s and `RCErrorBanner`'s real initializers before assuming these signatures — `grep -n "struct RCErrorBanner" -A 12 Modules/UI/Sources/Controls.swift`. Match whatever is there.

- [ ] **Step 7: Build and re-run**

```bash
swift build 2>&1 | tail -5
swift test --filter DirectivesFeatureTests --event-stream-output-path /tmp/es7.jsonl 2>&1 | tail -3
swift test --filter DirectiveRowTests --event-stream-output-path /tmp/es6.jsonl 2>&1 | tail -3
```

Expected: clean build, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Modules/DirectivesFeature
git commit -m "Add the Directives list: reducer, list pane, and row

Both queries live in state per the house standard, so the views are pure
renderers and the list never flashes empty. Clear and Reconfigure are the
only writes — there is no engine yet, so the custom half of the list is
deliberately empty.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: The detail pane

**Files:**
- Create: `Modules/DirectivesFeature/Sources/DirectiveDetailView.swift`
- Modify: `Modules/DirectivesFeature/Tests/DirectivesFeatureTests.swift` (add the composer-presentation test)

**Interfaces:**
- Consumes: `DirectivesFeature` actions from Task 5, `DirectiveComposerSheet` from Task 2.
- Produces: `DirectiveDetailView(store:)` — Task 7 wires it into `MainFeature`.

- [ ] **Step 1: Write the failing test**

Append to `Modules/DirectivesFeature/Tests/DirectivesFeatureTests.swift`, inside the suite:

```swift
    /// Reconfigure opens the shared composer seeded from the selected device.
    @Test func reconfigurePresentsTheComposer() async throws {
        let database = try GameDatabase.bootstrap()
        try database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "survey_system") }.execute(db)
        }
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "builtin:AMI1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        await store.send(.reconfigureTapped)
        #expect(store.state.composer?.deviceCode == "AMI1")
        #expect(store.state.composer?.directive == "survey_system")
    }
```

- [ ] **Step 2: Run and confirm it passes already**

```bash
swift test --filter DirectivesFeatureTests --event-stream-output-path /tmp/es8.jsonl 2>&1 | tail -3
```

Expected: **PASS** — Task 5's reducer already implements `.reconfigureTapped`. This test exists to pin the behaviour the view depends on before the view is written. If it fails, fix the reducer before continuing.

- [ ] **Step 3: Write the detail view**

Create `Modules/DirectivesFeature/Sources/DirectiveDetailView.swift`:

```swift
//
//  DirectiveDetailView.swift
//  Replicould — Directives feature
//
//  The detail pane, branching on row kind. The two genuinely differ: a mission
//  has a target queue and a step timeline; a built-in AMI directive has a config
//  blob and the drones it's running. Built-in rows are editable right here —
//  in a three-pane layout this pane IS the device context, so sending the user
//  elsewhere to edit would re-introduce the asymmetry the unified surface exists
//  to remove.
//

import ComposableArchitecture
import DirectiveComposerFeature
import GameModels
import SwiftUI
import UI
import Utils

public struct DirectiveDetailView: View {
    @Bindable var store: StoreOf<DirectivesFeature>

    public init(store: StoreOf<DirectivesFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            switch store.selectedRow {
            case let .builtIn(builtIn):
                builtInDetail(builtIn)
            case let .custom(directive):
                customDetail(directive)
            case nil:
                RCContentUnavailableView("No Selection", systemImage: "square.dashed")
            }
        }
        // Feature-tier sheet: @Presents + scope, never .sheet(isPresented:).
        .sheet(item: $store.scope(state: \.composer, action: \.composer)) { composerStore in
            DirectiveComposerSheet(store: composerStore)
        }
    }

    // MARK: Built-in

    @ViewBuilder
    private func builtInDetail(_ builtIn: BuiltInDirective) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header(
                    title: BlueprintPresentation.displayName(builtIn.directive),
                    subtitle: builtIn.deviceCode,
                    caption: BlueprintPresentation.displayName(builtIn.deviceType)
                )

                if let config = builtIn.config, let pairs = configPairs(config), !pairs.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        RCSectionHeader("Configuration")
                        ForEach(pairs, id: \.key) { pair in
                            detailRow(pair.key, pair.value)
                        }
                    }
                }

                if !builtIn.controlledDevices.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        RCSectionHeader("Controlled Devices")
                        ForEach(builtIn.controlledDevices) { controlled in
                            controlledRow(controlled)
                        }
                    }
                }

                HStack(spacing: Space.s) {
                    Button("Reconfigure") { store.send(.reconfigureTapped) }
                        .buttonStyle(RCButtonStyle(.primary))
                    Button("Clear") { store.send(.clearTapped) }
                        .buttonStyle(RCButtonStyle(.secondary))
                    Spacer()
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(BlueprintPresentation.displayName(builtIn.directive))
    }

    /// One controlled drone: its code (mono — it's a designation), type, and
    /// live status.
    private func controlledRow(_ controlled: Device.ControlledDevice) -> some View {
        HStack(spacing: Space.s) {
            Text(controlled.deviceCode)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextPrimary)
            Text(BlueprintPresentation.displayName(controlled.deviceType))
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
            Spacer(minLength: 0)
            if let status = controlled.status {
                StatusBadge(status: status)
            }
        }
        .padding(.vertical, Space.xxs)
    }

    /// Flatten a directive's config object into displayable label/value pairs.
    /// Nested objects (the `delivery` route) render as `route.collect` style
    /// keys rather than being dropped.
    private func configPairs(_ config: JSONValue) -> [(key: String, value: String)]? {
        guard case let .object(fields) = config else { return nil }
        return fields.keys.sorted().flatMap { key -> [(key: String, value: String)] in
            guard let value = fields[key] else { return [] }
            if case let .object(nested) = value {
                return nested.keys.sorted().compactMap { inner in
                    nested[inner].map { (key: "\(key).\(inner)", value: scalarString($0)) }
                }
            }
            return [(key: key, value: scalarString(value))]
        }
    }

    /// Render a scalar JSON value for display. Arrays join; anything else falls
    /// back to a compact description.
    private func scalarString(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        if let bool = value.boolValue { return bool ? "Yes" : "No" }
        if let number = value.numberValue {
            return number == number.rounded() ? String(Int(number)) : String(number)
        }
        if let array = value.arrayValue {
            return array.compactMap(\.stringValue).joined(separator: ", ")
        }
        return "—"
    }

    // MARK: Custom

    /// Missions can't exist until Stage 3 lands the engine, but the pane is
    /// written now so the branch is real rather than a fatalError waiting to
    /// happen if a row is ever hand-inserted.
    @ViewBuilder
    private func customDetail(_ directive: Directive) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header(
                    title: directive.kind.title,
                    subtitle: directive.deviceCode,
                    caption: directive.status.rawValue
                )
                VStack(alignment: .leading, spacing: Space.xs) {
                    RCSectionHeader("Targets")
                    ForEach(Array(directive.targets.enumerated()), id: \.element) { index, target in
                        HStack(spacing: Space.s) {
                            Image(systemName: index < directive.targetIndex
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(index < directive.targetIndex ? .rcAccent : .rcTextTertiary)
                            Text(target)
                                .font(.rcMonoSmall)
                                .foregroundStyle(.rcTextPrimary)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(directive.kind.title)
    }

    // MARK: Shared chrome

    private func header(title: String, subtitle: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)
            HStack(spacing: Space.xs) {
                Text(subtitle)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextSecondary)
                Text("·").foregroundStyle(.rcTextTertiary)
                Text(caption)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Text(label)
                .font(.rcFieldLabel)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.rcCaption)
                .foregroundStyle(.rcTextPrimary)
            Spacer(minLength: 0)
        }
    }
}
```

**API checks before building:** `StatusBadge`'s initializer, `RCSectionHeader`, `RCButtonStyle`, `.rcFieldLabel`, and `JSONValue`'s accessor names (`stringValue`/`boolValue`/`numberValue`/`arrayValue` — these are the ones `DirectiveComposer` already uses, so they exist). Adjust to the real signatures.

- [ ] **Step 4: Build and test**

```bash
swift build 2>&1 | tail -5
swift test --filter DirectivesFeatureTests --event-stream-output-path /tmp/es8.jsonl 2>&1 | tail -3
```

Expected: clean build, all five reducer tests pass.

- [ ] **Step 5: Commit**

```bash
git add Modules/DirectivesFeature
git commit -m "Add the Directives detail pane

It branches on row kind because the two genuinely differ — a mission has a
target queue, a built-in AMI directive has a config blob and the drones
it's running. Built-ins are editable right here: in a three-pane layout
this pane is the device context, so sending the user elsewhere to edit
would re-introduce the asymmetry the unified surface exists to remove.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Sidebar and app-shell wiring

**Files:**
- Modify: `Modules/SidebarFeature/Sources/SidebarItem.swift`
- Modify: `macOS/MainFeature.swift`
- **User action:** link the `DirectivesFeature` product to the app target in Xcode

**Interfaces:**
- Consumes: `DirectivesFeature`, `DirectivesListView`, `DirectiveDetailView` (Tasks 5–6).

- [ ] **Step 1: Add the sidebar case**

In `Modules/SidebarFeature/Sources/SidebarItem.swift`:

Add `directives` to the Operations line of the case list:

```swift
    // Operations
    case directives, locationEvents, printQueue, operationsLog
```

Add to `title`:

```swift
        case .directives: "Directives"
```

Add to `symbol`:

```swift
        case .directives: "brain.head.profile"
```

Add to the Operations group, first (it's the headline Operations surface):

```swift
        Group(id: "Operations", items: [.directives, .locationEvents, .printQueue, .operationsLog]),
```

`hasDetail` needs no change — `default: true` already covers it.

- [ ] **Step 2: Run the sidebar tests**

```bash
swift test --filter SidebarFeatureTests --event-stream-output-path /tmp/es9.jsonl 2>&1 | tail -3
```

Expected: pass. If a test asserts an exact item count or group membership, update that assertion to include `.directives` — it's a deliberate change, not a regression.

- [ ] **Step 3: Wire `MainFeature`**

In `macOS/MainFeature.swift` — this file is in the `.xcodeproj`, **not** LSP-covered, so grep is acceptable here.

Add the import (alphabetically, after `DevicesFeature`):

```swift
import DirectivesFeature
```

Add to `State`:

```swift
        /// The unified Directives surface (Operations) — built-in AMI directives
        /// beside custom missions.
        var directives: DirectivesFeature.State
```

Add to `State.init`:

```swift
            self.directives = DirectivesFeature.State()
```

Add to `Action`:

```swift
        case directives(DirectivesFeature.Action)
```

Add a `Scope` alongside the others:

```swift
        Scope(state: \.directives, action: \.directives) {
            DirectivesFeature()
        }
```

Add `.directives` to the catch-all case at line 207:

```swift
            case .sidebar, .account, .messages, .bobnet, .rawAPI, .eventLog, .newStarMap, .devices, .blueprints, .civilisations, .directives, .locations, .locationEvents, .printQueue, .replicantDirectory:
                return .none
```

Add the scoped store accessor beside the others:

```swift
    /// The Directives store, scoped from the main session.
    private var directivesStore: StoreOf<DirectivesFeature> {
        store.scope(state: \.directives, action: \.directives)
    }
```

Add to `content`, before the `.locationEvents` branch:

```swift
        } else if store.sidebar.category == .directives {
            DirectivesListView(store: directivesStore)
```

Add to `detail`, before the `.locationEvents` branch:

```swift
        } else if store.sidebar.category == .directives {
            DirectiveDetailView(store: directivesStore)
```

- [ ] **Step 4: STOP — the app-target link is a manual user action**

`.pbxproj` edits are blocked in this repo. The `DirectivesFeature` library product must be linked to the app target by hand.

**Ask the user to do this, then wait:**

> In Xcode, select the **Replicant** app target → **General** → **Frameworks, Libraries, and Embedded Content** → **+** → add **DirectivesFeature**. (`DirectiveComposerFeature` needs no manual step — it reaches the app transitively through `DevicesFeature`, which is already linked.) Tell me when it's linked and I'll build.

Do not attempt to edit the `.pbxproj`. Do not proceed to Step 5 until the user confirms.

- [ ] **Step 5: Build the app and verify**

```bash
swift build 2>&1 | tail -5
```

Then build the app scheme in Xcode (or ask the user to). Expected: clean build.

Full test sweep of every target this plan touched:

```bash
swift test --filter MiningResourceTests --event-stream-output-path /tmp/f1.jsonl 2>&1 | tail -3
swift test --filter DirectiveSchemaTests --event-stream-output-path /tmp/f2.jsonl 2>&1 | tail -3
swift test --filter DirectiveComposerFeatureTests --event-stream-output-path /tmp/f3.jsonl 2>&1 | tail -3
swift test --filter DirectivesFeatureTests --event-stream-output-path /tmp/f4.jsonl 2>&1 | tail -3
swift test --filter DirectiveRowTests --event-stream-output-path /tmp/f5.jsonl 2>&1 | tail -3
swift test --filter DevicesFeatureTests --event-stream-output-path /tmp/f6.jsonl 2>&1 | tail -3
swift test --filter SidebarFeatureTests --event-stream-output-path /tmp/f7.jsonl 2>&1 | tail -3
```

Note the separate output paths — one shared path across multiple test processes truncates, which the `swift-test-event-stream` skill documents.

- [ ] **Step 6: Live sanity check (user's, or a GET probe)**

Confirm in the running app:
1. **Directives** appears at the top of the Operations sidebar group.
2. Any AMI controller with a directive in force shows as a **BUILT-IN** row with its device code in mono.
3. Selecting it shows the config, the controlled drones with live status, and Reconfigure / Clear.
4. **Reconfigure** opens the same Set Directive sheet the device inspector opens, seeded to the directive in force.
5. The device inspector's own Set Directive sheet still works unchanged (the Stage 1 regression check that matters most).
6. The list is empty of CUSTOM rows — correct; there is no engine yet.

Do not fire live POST commands (Clear, Set Directive) without asking the user first — they mutate the one live account.

- [ ] **Step 7: Commit**

```bash
git add Modules/SidebarFeature/Sources/SidebarItem.swift macOS/MainFeature.swift
git commit -m "Wire Directives into the sidebar and the app shell

Directives leads the Operations group. The custom half of the list stays
empty until Stage 3 lands the engine; the built-in half is live now.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Verification (whole plan)

1. `swift build` clean from `app/Modules/`.
2. Every suite listed in Task 7 Step 5 passes, read from its own event stream.
3. `DevicesFeatureTests` and `DirectiveComposerFeatureTests` have the **same test counts** as before Task 2 — Stage 1 is a pure refactor and any count change means behaviour moved.
4. LSP: no dangling references to `DirectiveComposer`/`DirectiveComposerSheet` inside `DevicesFeature`; `MiningResource.all` has references from both `DevicesFeature` and `DirectiveComposerFeature`.
5. The app builds and the live sanity checks in Task 7 Step 6 pass.

## Deliberately NOT done in Stages 1–2

- **No engine.** No `DirectiveEngine` module, no executors, no `CommandGovernor`. Stage 3.
- **No `directive.*` event route.** Nothing writes `DirectiveLogEntry` yet — the table exists so Stage 3 has it, and the built-in detail pane deliberately does not yet render a timeline (there would be nothing in it).
- **No `+ New Directive` flow.** Custom missions can't be created until there's an engine to run them.
- **No built-in directive *creation*** from this view (the directive-capable-device picker) — spec §9 item 1, deferred by design.
- **No device tagging** (the directive chip in the device inspector, the list-row indicator, the engaged/free filter) — it belongs with the engine, since today every directive is visible on its own device already.
- **No FTL-mesh incremental add** — it ships with Relay Run in Stage 5, which is what makes the full rebuild routine.
