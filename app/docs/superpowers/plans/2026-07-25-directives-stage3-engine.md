# Directives Stage 3 — CommandGovernor + DirectiveEngine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Directives surface an engine — a budget-aware `CommandGovernor`, a `DirectiveEngine` module that runs one serial executor per custom mission over reconciled SQLite state, and the `directive.*` event route that lands completions in the audit trail — plus the six review items Stages 1–2 deferred.

**Architecture:** Three tiers, bottom-up. `CommandGovernor` (GameServices) is a `PollCoordinator`-shaped actor: every engine dispatch consults the **actions** rate bucket and a per-device in-flight guard before it POSTs, and is vended as `@Dependency(\.commandGovernor)` over one process-shared instance. `DirectiveEngine` (new non-feature SPM module, `Dependencies` not TCA) owns a supervisor task that keeps one executor task alive per `.running` directive; each executor ticks on a clock, builds a read-only `WorldSnapshot` from SQLite, asks the mission's `MissionStepMachine` for one `MissionAction`, and applies it — dispatch / wait / stall / advance / done — writing `DirectiveLogEntry` rows as it goes. **No step machines ship in this stage**: the registry is empty in production and populated by fakes in tests, which is what proves the loop before Stages 4–5 write the real Survey/Relay missions. `DirectiveIngestion.eventRoute` matches `.category("directive")` and writes one log entry per event, deduped by the `eventID` unique index and attributed to a mission only when the issue-time-relative guard passes.

**Tech Stack:** Swift 6.4, macOS 26+, SQLiteData (`@Table`, `DatabaseMigrator`, `@FetchOne`), swift-dependencies, Swift Testing, TCA (feature layer only).

**Spec:** `app/docs/superpowers/specs/2026-07-24-directives-design.md` — §5 (completion detection), §6 (engine + governor), §8 (error handling & testing) are load-bearing. Read them before Task 6.

**Prior stage:** `app/docs/superpowers/plans/2026-07-24-directives-stage1-2-unified-surface.md` and `app/.claude/memory/directives-feature.md` (invariants — do not undo them).

## Global Constraints

- All paths are relative to the repo root. The SPM package root is `app/Modules/` (where `Package.swift` lives) — run every `swift` command from there.
- **Run tests via the event stream, never by scraping console text.** Canonical invocation, from `app/Modules/`:
  ```bash
  swift test --test-product <Product> --disable-xctest \
    --event-stream-version 0 --event-stream-output-path .build/events.jsonl
  jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
  ```
  An empty second line means no failures. Always pass `--test-product` — one output path shared by many test processes truncates to the last writer. See the repo skill `swift-test-event-stream`.
- **Built-in rows stay derived, never persisted.** No production code writes the `Directive` table for a built-in AMI directive. `DirectiveRow.merge` recomputes on every read.
- **The engine observes reconciled state, never raw events.** Executors read `Device` / `Operation` / `Directive` rows. The only code that touches a `GameEventEnvelope` is the event route in Task 9, and its sole job is writing a `DirectiveLogEntry`.
- **TCA is for feature modules only, by manifest.** `DirectiveEngine` declares `Dependencies` (+ `SQLiteData`), never `ComposableArchitecture`.
- **No hard-coded colors, spacing, or font sizes.** Use `DesignSystem.swift` tokens (`Space.*`, `Radius.*`, `.rc*`, `IconSize.*`).
- **Designations render monospace.** Any system/device/site code uses `.rcMono` / `.rcMonoSmall` / `.rcBodyEmphMono` / `.rcMicroMono`.
- **Pure logic never lives as a static on a SwiftUI `View`** — it traps under `swift test` (signal 5). Put it in a plain SwiftUI-free namespace.
- **List-row structs live in their own file**, never beside a `#Preview` (Xcode 26 preview JIT crash).
- **Logging is `os.Logger` only**, subsystem `name.pennig.replicould`, category = the module/service name (`DirectiveEngine`, `CommandGovernor`, `Directives`).
- **Loud test defaults:** a shared client's `testValue` uses `unimplemented(...)`, never a quiet stub.
- **Commits go to the worktree branch; no PRs, no pushes, origin is not a consideration.** One commit per task, message style matching `git log`.
- **Verify with SourceKit-LSP before signing off** on any task (`goToDefinition` / `findReferences`). LSP root is `app/Modules/`; **build first** — the index is only as fresh as your last build — and run `scripts/link-index-store.sh` once per checkout. An empty `findReferences` is not evidence a symbol is unused.
- New files inside an existing SPM target need no `Package.swift` edit. A new *module* needs all three edits (product, target, test target) in alphabetical order.

---

### Task 1: Stage 1–2 polish — mono designations and a status display name

The three review findings that are pure presentation: a designation baked into a proportional title string, config values rendered proportionally, and `DirectiveStatus` printing its raw case name.

**Files:**
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveRow.swift` (split `title`)
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveRowView.swift:23-26` (render the split)
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveDetailView.swift:26-63, 101-109, 158-165` (designation detection + `displayName`)
- Modify: `app/Modules/GameModels/Sources/Directive.swift:35-41` (add `DirectiveStatus.displayName`)
- Modify: `app/Modules/UI/DESIGN_SPEC.md:52` (spacing scale line)
- Test: `app/Modules/DirectivesFeature/Tests/DirectiveRowTests.swift` (append)
- Test: `app/Modules/DirectivesFeature/Tests/DirectiveDetailViewTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `DirectiveRow.headline: String`, `DirectiveRow.headlineDesignation: String?` (`title` stays, now derived from the two)
  - `DirectiveStatus.displayName: String`
  - `DirectiveConfigFlattening.isDesignation(_ value: String) -> Bool`

- [ ] **Step 1: Write the failing tests**

Append to `app/Modules/DirectivesFeature/Tests/DirectiveRowTests.swift` (inside the existing suite):

```swift
    /// The headline splits so the view can render the designation half in a
    /// mono token — a single interpolated string forces one font on both.
    @Test func missionHeadlineSplitsOffTheDesignation() {
        let row = DirectiveRow.custom(Self.mission(targets: ["SHERATANON"], targetIndex: 0))
        #expect(row.headline == "Survey Run")
        #expect(row.headlineDesignation == "SHERATANON")
        #expect(row.title == "Survey Run → SHERATANON")
    }

    /// An exhausted queue has no current target, so there is no designation half.
    @Test func exhaustedMissionHasNoDesignation() {
        let row = DirectiveRow.custom(Self.mission(targets: ["SOL"], targetIndex: 1))
        #expect(row.headline == "Survey Run")
        #expect(row.headlineDesignation == nil)
        #expect(row.title == "Survey Run")
    }
```

Append to `app/Modules/DirectivesFeature/Tests/DirectiveDetailViewTests.swift` (inside the existing suite):

```swift
    /// Config values that are designation codes render mono; prose does not.
    @Test func designationDetection() {
        #expect(DirectiveConfigFlattening.isDesignation("SOL"))
        #expect(DirectiveConfigFlattening.isDesignation("SOL-3-1"))
        #expect(DirectiveConfigFlattening.isDesignation("TAU-4-SAL-2"))
        #expect(!DirectiveConfigFlattening.isDesignation("all"))
        #expect(!DirectiveConfigFlattening.isDesignation("Yes"))
        #expect(!DirectiveConfigFlattening.isDesignation("No"))
        #expect(!DirectiveConfigFlattening.isDesignation("SO"))          // too short
        #expect(!DirectiveConfigFlattening.isDesignation("SOL AND MORE")) // has a space
    }

    /// Every status has a display name — the pane must never print `needsAttention`.
    @Test func everyStatusHasADisplayName() {
        for status in DirectiveStatus.allCases {
            #expect(status.displayName != status.rawValue)
            #expect(!status.displayName.isEmpty)
        }
    }
```

If `DirectiveRowTests` has no `mission(targets:targetIndex:)` helper yet, add one to that file:

```swift
    static func mission(targets: [String], targetIndex: Int) -> Directive {
        Directive(
            id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
            targets: targets, targetIndex: targetIndex, step: "stow",
            stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift test --test-product DirectivesFeaturePackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — `headline`, `headlineDesignation`, `isDesignation`, `displayName` do not exist.

- [ ] **Step 3: Split the headline in `DirectiveRow`**

Replace the `title` computed property in `DirectiveRow.swift` with:

```swift
    /// The row's headline, **without** any designation — see
    /// `headlineDesignation`. Split because a designation must render in a mono
    /// token (house rule) and a single interpolated string forces one font on
    /// the whole line.
    public var headline: String {
        switch self {
        case let .custom(directive): directive.kind.title
        case let .builtIn(builtIn): BlueprintPresentation.displayName(builtIn.directive)
        }
    }

    /// The designation half of the headline — a mission's current target, or nil
    /// (built-in rows name a directive, never a place).
    public var headlineDesignation: String? {
        switch self {
        case let .custom(directive): directive.currentTarget
        case .builtIn: nil
        }
    }

    /// The whole headline as one string, for `navigationTitle` and
    /// accessibility, where a single `String` is all the API accepts.
    public var title: String {
        guard let designation = headlineDesignation else { return headline }
        return "\(headline) → \(designation)"
    }
```

- [ ] **Step 4: Render the split in `DirectiveRowView`**

Replace the `Text(row.title)` line (lines 23-26) with:

```swift
                HStack(spacing: Space.xxs) {
                    Text(row.headline)
                        .font(.rcBodyEmph)
                        .foregroundStyle(.rcTextPrimary)
                        .lineLimit(1)
                    if let designation = row.headlineDesignation {
                        Text("→")
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextTertiary)
                        Text(designation)
                            .font(.rcBodyEmphMono)
                            .foregroundStyle(.rcTextPrimary)
                            .lineLimit(1)
                    }
                }
```

- [ ] **Step 5: Add `DirectiveStatus.displayName`**

In `app/Modules/GameModels/Sources/Directive.swift`, inside `DirectiveStatus`:

```swift
    /// The pane's label. Without this the detail view renders the raw case name
    /// ("needsAttention") straight at the user.
    public var displayName: String {
        switch self {
        case .running: "Running"
        case .needsAttention: "Needs Attention"
        case .paused: "Paused"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        }
    }
```

Then in `DirectiveDetailView.customDetail`, change `caption: directive.status.rawValue` to `caption: directive.status.displayName`.

- [ ] **Step 6: Detect designations in flattened config values**

In `DirectiveConfigFlattening` (same file), add:

```swift
    /// Whether a flattened config value is a designation code — which must
    /// render in a mono token — rather than prose. Designations are upper-case
    /// alphanumerics with optional `-` groups (`SOL`, `SOL-3-1`, `TAU-4-SAL-2`)
    /// and never contain spaces. Config *keys* can't drive this: each directive
    /// names its target differently (`location`, `target`, `destination`), so
    /// the value's own shape is the stable signal.
    ///
    /// Known over-match, deliberately accepted: an all-caps resource name like
    /// `IRON` also renders mono. It reads as a code either way.
    static func isDesignation(_ value: String) -> Bool {
        guard value.count >= 3, !value.contains(" ") else { return false }
        return value.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "-" }
    }
```

Then render values accordingly — replace `detailRow`'s value `Text` so the caller can ask for mono. Change `detailRow` to:

```swift
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Text(label)
                .font(.rcFieldLabel)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(DirectiveConfigFlattening.isDesignation(value) ? .rcMonoSmall : .rcCaption)
                .foregroundStyle(.rcTextPrimary)
            Spacer(minLength: 0)
        }
    }
```

- [ ] **Step 7: Fix the stale spacing line in the design spec**

In `app/Modules/UI/DESIGN_SPEC.md:52`, replace:

```
- **Spacing** 4 · 8 · 12 · 16 · 24 (`Space.xs…xl`).
```

with:

```
- **Spacing** 2 · 4 · 8 · 12 · 16 · 24 (`Space.xxs…xl`).
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
swift build 2>&1 | tail -3
swift test --test-product DirectivesFeaturePackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: build succeeds, the `jq` line prints nothing.

- [ ] **Step 9: Commit**

```bash
git add app/Modules/DirectivesFeature app/Modules/GameModels/Sources/Directive.swift app/Modules/UI/DESIGN_SPEC.md
git commit -m "Render directive designations mono and name every status"
```

---

### Task 2: Stage 1–2 polish — the two missing tests

The `set_directive` dispatch path is the feature's headline write and has no test; `merge`'s `!directive.isEmpty` guard has never been exercised.

**Files:**
- Test: `app/Modules/DirectivesFeature/Tests/DirectivesFeatureTests.swift` (append)
- Test: `app/Modules/DirectivesFeature/Tests/DirectiveRowTests.swift` (append)

**Interfaces:**
- Consumes: `DirectiveRow.merge(devices:directives:)`, `DirectivesFeature.Action.composer`, `CommandClient.dispatch`.
- Produces: nothing — tests only.

- [ ] **Step 1: Write the failing dispatch test**

Append to `DirectivesFeatureTests.swift`:

```swift
    /// The composer's confirmation dispatches `set_directive` at the controller
    /// the composer was opened on, carrying the chosen directive and config.
    /// This is the feature's headline write and the one path a regression here
    /// would silently break.
    @Test func composerConfirmationDispatchesSetDirective() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "patrol") }.execute(db)
        }
        let dispatched = LockIsolated<(OperationKind, String, CommandParams)?>(nil)
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "builtin:AMI1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { kind, code, params in
                dispatched.setValue((kind, code, params))
                return .accepted(operationID: nil)
            }
        }
        store.exhaustivity = .off

        await store.send(.reconfigureTapped)
        await store.send(
            .composer(.presented(.delegate(.confirmed(
                directive: "survey_system",
                configuration: ["planets": .string("all")]
            ))))
        )
        await store.receive(\.commandFinished)

        let call = try #require(dispatched.value)
        #expect(call.0 == .setDirective)
        #expect(call.1 == "AMI1")
        #expect(call.2.directive == "survey_system")
        #expect(call.2.configuration?["planets"]?.stringValue == "all")
    }
```

- [ ] **Step 2: Write the failing merge-guard test**

Append to `DirectiveRowTests.swift`:

```swift
    /// A device whose `ami_directive.name` is present but EMPTY contributes no
    /// built-in row. The guard exists because the backend has been seen to send
    /// an empty string for "no directive", which would otherwise render a row
    /// with a blank headline and a Clear button that clears nothing.
    @Test func emptyDirectiveNameYieldsNoBuiltInRow() {
        let device = Self.controller(code: "AMI1", directive: "")
        #expect(DirectiveRow.merge(devices: [device], directives: []).isEmpty)
    }
```

If `DirectiveRowTests` lacks a `controller(code:directive:)` helper, add one (matching the one in `DirectivesFeatureTests`):

```swift
    static func controller(code: String, directive: String) -> Device {
        var device = Device(
            deviceCode: code, deviceType: "ami_survey_controller", replicantCode: "R1",
            status: "idle", location: nil, locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [], detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
        )
        device.detail = .object(["ami_directive": .object(["name": .string(directive)])])
        return device
    }
```

- [ ] **Step 3: Run the tests**

```bash
swift test --test-product DirectivesFeaturePackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: both pass (they cover existing behavior — if either *fails*, that is a real bug: fix the production code, not the test, and say so in the commit).

- [ ] **Step 4: Commit**

```bash
git add app/Modules/DirectivesFeature/Tests
git commit -m "Cover the set_directive dispatch path and the empty-directive guard"
```

---

### Task 3: Sidebar needs-attention badge

Spec §1 calls for a needs-attention badge on the Directives sidebar item; Stages 1–2 never implemented it and never declared it deferred.

**Files:**
- Modify: `app/Modules/SidebarFeature/Sources/SidebarView.swift:26-31, 50-67`
- Test: `app/Modules/SidebarFeature/Tests/` — add `DirectiveBadgeTests.swift` **only if** that test target already exists; otherwise skip the test file and rely on Task 5's feature tests plus a manual preview check (say which you did).

**Interfaces:**
- Consumes: `Directive` (`GameModels`), `DirectiveStatus.needsAttention`.
- Produces: nothing importable — view-local.

- [ ] **Step 1: Add the live query**

In `SidebarView`, alongside the other `@FetchOne` counts:

```swift
    /// Live count of custom missions stalled in `needsAttention` — the sidebar's
    /// "a mission is waiting on you" signal (design spec §1). Missions are the
    /// only thing here the user must act on, so this drives the accent pill
    /// rather than a plain count.
    @FetchOne(Directive.where { $0.status.eq(DirectiveStatus.needsAttention) }.count())
    private var stalledDirectiveCount = 0
```

- [ ] **Step 2: Route it into both badge functions**

```swift
    private func badgeCount(for item: SidebarItem) -> Int {
        switch item {
        case .messages: unreadCount
        case .locationEvents: activeEventCount
        case .directives: stalledDirectiveCount
        default: 0
        }
    }

    private func accentCount(for item: SidebarItem) -> Int {
        switch item {
        case .messages: unreadStoryCount
        case .locationEvents: readyEventCount
        case .directives: stalledDirectiveCount
        default: 0
        }
    }
```

Both return the same count on purpose: `SidebarCategoryBadge` renders `otherCount: max(0, badgeCount - accent)`, so equal values yield a single accent pill and no plain remainder — a stalled mission is never "just informational."

- [ ] **Step 3: Build and run the package tests**

```bash
swift build 2>&1 | tail -3
swift test --test-product SidebarFeaturePackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl 2>&1 | tail -3
```
Expected: builds; if the test product doesn't exist, note that and move on.

- [ ] **Step 4: Commit**

```bash
git add app/Modules/SidebarFeature
git commit -m "Badge the Directives sidebar item when a mission needs attention"
```

---

### Task 4: `Directive.controllerCode` — the column ownership needs

The engine drives an AMI controller (Survey Run's step 4 issues `set_directive` on it). Nothing today records *which* controller, so the resulting built-in row looks like an independent directive the user can Clear mid-mission. This column is what makes ownership knowable.

**Files:**
- Modify: `app/Modules/GameModels/Sources/Directive.swift:62-133` (property + init), `:192-219` (second migration)
- Test: `app/Modules/GameModels/Tests/` — append to an existing directive test file if one exists, else create `app/Modules/GameModels/Tests/DirectiveSchemaTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Directive.controllerCode: String?`; `Directive.init(…, controllerCode: String? = nil, …)`; migration `"Add 'controllerCode' to 'directives'"`.

- [ ] **Step 1: Write the failing migration test**

Create (or append to) the GameModels test file:

```swift
//
//  DirectiveSchemaTests.swift
//  Replicould — GameModels
//
//  The directives schema, including the Stage 3 column that records which AMI
//  controller a mission is driving.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing

@Suite("Directive schema")
struct DirectiveSchemaTests {
    /// `controllerCode` round-trips, and defaults to nil for a mission that
    /// hasn't reached its `set_directive` step yet.
    @Test func controllerCodeRoundTrips() async throws {
        let database = try GameDatabase.bootstrap()
        let base = Directive(
            id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
            targets: ["SOL"], targetIndex: 0, step: "stow",
            stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        var owning = base
        owning.id = "D2"
        owning.controllerCode = "AMI1"
        try await database.write { db in
            try Directive.insert { base }.execute(db)
            try Directive.insert { owning }.execute(db)
        }
        let rows = try await database.read { db in
            try Directive.order { $0.id }.fetchAll(db)
        }
        #expect(rows.map(\.controllerCode) == [nil, "AMI1"])
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
swift test --test-product GameModelsPackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — `Directive` has no member `controllerCode`.

- [ ] **Step 3: Add the property and init parameter**

In `Directive`, after `deviceCode`:

```swift
    /// The AMI controller this mission is currently driving, once it has issued
    /// `set_directive` on one. Nil before that step and after the mission
    /// clears it.
    ///
    /// This is what makes the resulting built-in row's ownership knowable: the
    /// server-run directive on `controllerCode` is the engine's own work, not
    /// something the user should Reconfigure or Clear underneath it.
    /// `deviceCode` (the vessel) can never stand in for this — a Survey Run's
    /// vessel and its controller are two different devices.
    public var controllerCode: String?
```

In the initializer, add the parameter after `deviceCode` **with a default**, so the fixtures written in Stages 1–2 keep compiling:

```swift
        deviceCode: String,
        controllerCode: String? = nil,
```

and the assignment `self.controllerCode = controllerCode` after `self.deviceCode = deviceCode`.

- [ ] **Step 4: Add the migration**

In `extension Directive`, **after** the existing `Create 'directives' table` migration inside `registerMigrations` (never edit a shipped migration — this one is already in users' databases):

```swift
        migrator.registerMigration("Add 'controllerCode' to 'directives'") { db in
            try #sql(
                """
                ALTER TABLE "directives" ADD COLUMN "controllerCode" TEXT
                """
            )
            .execute(db)
        }
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
swift test --test-product GameModelsPackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: empty.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/GameModels
git commit -m "Record which controller a mission drives"
```

---

### Task 5: Engine-owned built-in rows — badge and lock

With `controllerCode` recorded, a built-in row whose device a live mission is driving is marked "driven by Survey Run" and its Reconfigure/Clear are refused. This is a correctness guard, not decoration: clearing a directive the engine is waiting on would stall the mission with a confusing `surveyIncomplete`.

**Files:**
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveRow.swift` (`DirectiveOwner`, `BuiltInDirective.drivenBy`, `merge`)
- Modify: `app/Modules/DirectivesFeature/Sources/DirectivesFeature.swift:97-108` (guards)
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveRowView.swift` (lock glyph)
- Modify: `app/Modules/DirectivesFeature/Sources/DirectiveDetailView.swift:92-132` (badge + disabled buttons)
- Test: `app/Modules/DirectivesFeature/Tests/DirectiveRowTests.swift`, `app/Modules/DirectivesFeature/Tests/DirectivesFeatureTests.swift`

**Interfaces:**
- Consumes: `Directive.controllerCode` (Task 4).
- Produces:
  - `DirectiveOwner` (`directiveID: String`, `kindTitle: String`), `Equatable`, `Sendable`
  - `BuiltInDirective.drivenBy: DirectiveOwner?` and an `init(deviceCode:deviceType:directive:config:controlledDevices:drivenBy:)` (`drivenBy` defaulted to nil)
  - `DirectiveRow.merge(devices:directives:)` — unchanged signature, now resolves ownership

- [ ] **Step 1: Write the failing tests**

Append to `DirectiveRowTests.swift`:

```swift
    /// A live mission driving a controller marks that controller's built-in row
    /// as engine-owned.
    @Test func liveMissionOwnsItsControllersBuiltInRow() {
        var mission = Self.mission(targets: ["SOL"], targetIndex: 0)
        mission.controllerCode = "AMI1"
        let rows = DirectiveRow.merge(
            devices: [Self.controller(code: "AMI1", directive: "survey_system")],
            directives: [mission]
        )
        let builtIn = rows.compactMap { if case let .builtIn(b) = $0 { return b } else { return nil } }
        #expect(builtIn.count == 1)
        #expect(builtIn[0].drivenBy == DirectiveOwner(directiveID: "D1", kindTitle: "Survey Run"))
    }

    /// A finished mission releases its controller — the row is the user's again.
    @Test func finishedMissionDoesNotOwnItsController() {
        for status in [DirectiveStatus.completed, .cancelled] {
            var mission = Self.mission(targets: ["SOL"], targetIndex: 1)
            mission.controllerCode = "AMI1"
            mission.status = status
            let rows = DirectiveRow.merge(
                devices: [Self.controller(code: "AMI1", directive: "survey_system")],
                directives: [mission]
            )
            let builtIn = rows.compactMap { if case let .builtIn(b) = $0 { return b } else { return nil } }
            #expect(builtIn[0].drivenBy == nil, "\(status) must not hold ownership")
        }
    }

    /// A paused or stalled mission KEEPS ownership: its directive is still in
    /// force server-side and the user resolving the stall expects it intact.
    @Test func pausedAndStalledMissionsKeepOwnership() {
        for status in [DirectiveStatus.paused, .needsAttention] {
            var mission = Self.mission(targets: ["SOL"], targetIndex: 0)
            mission.controllerCode = "AMI1"
            mission.status = status
            let rows = DirectiveRow.merge(
                devices: [Self.controller(code: "AMI1", directive: "survey_system")],
                directives: [mission]
            )
            let builtIn = rows.compactMap { if case let .builtIn(b) = $0 { return b } else { return nil } }
            #expect(builtIn[0].drivenBy != nil, "\(status) must hold ownership")
        }
    }

    /// A controller no mission is driving stays unowned — the common case.
    @Test func unrelatedControllerIsUnowned() {
        var mission = Self.mission(targets: ["SOL"], targetIndex: 0)
        mission.controllerCode = "AMI9"
        let rows = DirectiveRow.merge(
            devices: [Self.controller(code: "AMI1", directive: "survey_system")],
            directives: [mission]
        )
        let builtIn = rows.compactMap { if case let .builtIn(b) = $0 { return b } else { return nil } }
        #expect(builtIn[0].drivenBy == nil)
    }
```

Append to `DirectivesFeatureTests.swift`:

```swift
    /// Reconfigure and Clear are refused on a row the engine owns — the guard
    /// is in the reducer, not only the view, so a stale click or a future
    /// keyboard path can't slip past it.
    @Test func engineOwnedRowRefusesReconfigureAndClear() async throws {
        let database = try GameDatabase.bootstrap()
        var mission = Directive(
            id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
            controllerCode: "AMI1", targets: ["SOL"], targetIndex: 0, step: "survey",
            stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        mission.controllerCode = "AMI1"
        try await database.write { db in
            try Device.insert { Self.controller(code: "AMI1", directive: "survey_system") }.execute(db)
            try Directive.insert { mission }.execute(db)
        }
        let dispatched = LockIsolated(false)
        let store = TestStore(initialState: DirectivesFeature.State(selectedRowID: "builtin:AMI1")) {
            DirectivesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { _, _, _ in
                dispatched.setValue(true)
                return .accepted(operationID: nil)
            }
        }
        store.exhaustivity = .off

        await store.send(.reconfigureTapped)
        #expect(store.state.composer == nil)
        await store.send(.clearTapped)
        #expect(dispatched.value == false)
    }
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --test-product DirectivesFeaturePackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — no `DirectiveOwner`, no `drivenBy`.

- [ ] **Step 3: Add `DirectiveOwner` and resolve ownership in `merge`**

In `DirectiveRow.swift`, above `BuiltInDirective`:

```swift
/// The custom mission currently driving a built-in AMI directive. Present only
/// while that mission is live — the engine set the directive, so the user must
/// not Reconfigure or Clear it out from under a step that is waiting on it.
public struct DirectiveOwner: Equatable, Sendable {
    public let directiveID: String
    /// The mission's display title, e.g. "Survey Run" — what the badge says.
    public let kindTitle: String

    public init(directiveID: String, kindTitle: String) {
        self.directiveID = directiveID
        self.kindTitle = kindTitle
    }
}
```

Add to `BuiltInDirective` (property, init parameter defaulted to nil, assignment):

```swift
    /// Set when a live mission is driving this directive (see `DirectiveOwner`).
    public let drivenBy: DirectiveOwner?
```

Replace `merge` with:

```swift
    /// Statuses that still hold a controller. `paused` and `needsAttention`
    /// KEEP ownership: the directive is still in force server-side, and the
    /// user resolving a stall expects to find it intact. Only a finished
    /// mission gives the row back.
    static let owningStatuses: Set<DirectiveStatus> = [.running, .needsAttention, .paused]

    /// Merge the two sources into one ordered list. `devices` contributes a row
    /// for each device with a directive in force; `directives` contributes one
    /// per custom mission. A built-in row whose controller a live mission is
    /// driving carries that mission as `drivenBy`.
    public static func merge(devices: [Device], directives: [Directive]) -> [DirectiveRow] {
        let owners: [String: DirectiveOwner] = directives.reduce(into: [:]) { owners, directive in
            guard let controller = directive.controllerCode,
                  owningStatuses.contains(directive.status)
            else { return }
            owners[controller] = DirectiveOwner(
                directiveID: directive.id,
                kindTitle: directive.kind.title
            )
        }
        let custom = directives.map { DirectiveRow.custom($0) }
        let builtIn = devices.compactMap { device -> DirectiveRow? in
            guard let directive = device.currentDirective, !directive.isEmpty else { return nil }
            return .builtIn(
                BuiltInDirective(
                    deviceCode: device.deviceCode,
                    deviceType: device.deviceType,
                    directive: directive,
                    config: device.currentDirectiveConfig,
                    controlledDevices: device.controlledDevices,
                    drivenBy: owners[device.deviceCode]
                )
            )
        }
        return custom + builtIn
    }
```

- [ ] **Step 4: Guard the reducer**

In `DirectivesFeature.swift`, replace the two guards:

```swift
            case .reconfigureTapped:
                guard case let .builtIn(builtIn) = state.selectedRow else { return .none }
                // Engine-owned: the mission set this directive and a step is
                // waiting on it. Editing it here would stall the mission.
                guard builtIn.drivenBy == nil else {
                    logger.notice("reconfigure refused on \(builtIn.deviceCode, privacy: .public): driven by directive \(builtIn.drivenBy?.directiveID ?? "-", privacy: .public)")
                    return .none
                }
                guard let device = state.selectedDevice else { return .none }
                logger.info("directive composer \(device.deviceCode, privacy: .public) presented")
                state.composer = DirectiveComposer.State(device: device, fleet: state.devices)
                return .none

            case .clearTapped:
                guard case let .builtIn(builtIn) = state.selectedRow else { return .none }
                guard builtIn.drivenBy == nil else {
                    logger.notice("clear refused on \(builtIn.deviceCode, privacy: .public): driven by directive \(builtIn.drivenBy?.directiveID ?? "-", privacy: .public)")
                    return .none
                }
                return .send(.clearConfirmed(deviceCode: builtIn.deviceCode))
```

- [ ] **Step 5: Surface it in both views**

In `DirectiveRowView`, extend `subtitle` so an owned row says so, and add a lock glyph. Replace `subtitle`:

```swift
    /// Progress for a mission; the controlled-drone count for a built-in — or,
    /// when the engine owns it, the mission driving it.
    private var subtitle: String? {
        switch row {
        case let .custom(directive):
            let progress = directive.progress
            return "\(progress.completed)/\(progress.total)"
        case let .builtIn(builtIn):
            if let owner = builtIn.drivenBy { return "driven by \(owner.kindTitle)" }
            let count = builtIn.controlledDevices.count
            return count > 0 ? "\(count) controlled" : nil
        }
    }

    /// Whether this row's directive belongs to the engine.
    private var isEngineOwned: Bool {
        if case let .builtIn(builtIn) = row { return builtIn.drivenBy != nil }
        return false
    }
```

and add the glyph to the subtitle `HStack`, after the subtitle `Text`:

```swift
                    if isEngineOwned {
                        Image(systemName: "lock.fill")
                            .font(.system(size: IconSize.xs))
                            .foregroundStyle(.rcTextTertiary)
                    }
```

(If `IconSize.xs` does not exist, use the smallest token that does and say which.)

In `DirectiveDetailView.builtInDetail`, insert above the button row:

```swift
                if let owner = builtIn.drivenBy {
                    RCInlineNote(
                        "Driven by \(owner.kindTitle). Reconfigure and Clear are disabled while the mission is running."
                    )
                }
```

and disable both buttons:

```swift
                HStack(spacing: Space.s) {
                    Button("Reconfigure") { store.send(.reconfigureTapped) }
                        .buttonStyle(RCButtonStyle(.primary))
                    Button("Clear") { store.send(.clearTapped) }
                        .buttonStyle(RCButtonStyle(.secondary))
                    Spacer()
                }
                .disabled(builtIn.drivenBy != nil)
```

`RCInlineNote` may not exist in `Controls.swift`. **Check first** (`grep -n "struct RC" app/Modules/UI/Sources/Controls.swift`). If there is no inline-note control, render the note inline instead, using tokens only:

```swift
                if let owner = builtIn.drivenBy {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.rcTextTertiary)
                        Text("Driven by \(owner.kindTitle) — Reconfigure and Clear are disabled while the mission is running.")
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextSecondary)
                    }
                }
```

- [ ] **Step 6: Run the tests**

```bash
swift build 2>&1 | tail -3
swift test --test-product DirectivesFeaturePackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: empty.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/DirectivesFeature
git commit -m "Lock built-in rows a live mission is driving"
```

---

### Task 6: `CommandGovernor` — budget-aware, one command per device

V3.9 blocker 3. Modeled on `PollCoordinator`: an actor that gates every engine dispatch on the **actions** rate bucket and a per-device in-flight guard, vended over one process-shared instance so all callers share the guard. Built as shared infrastructure — manual UI commands can adopt it later.

**Files:**
- Create: `app/Modules/GameServices/Sources/CommandGovernor.swift`
- Create: `app/Modules/GameServices/Sources/CommandGovernorClient.swift`
- Test: `app/Modules/GameServices/Tests/CommandGovernorTests.swift`

**Interfaces:**
- Consumes: `CommandClient.dispatch`, `GameClient.budget(_:)`, `RateLimitGovernor.Bucket.actions`, `OperationKind`, `CommandParams`, `CommandOutcome`.
- Produces:
  - `public enum CommandDeferral: String, Sendable, Equatable { case budgetExhausted, commandInFlight }`
  - `public enum CommandDispatchResult: Sendable, Equatable { case dispatched(CommandOutcome), deferred(CommandDeferral) }`
  - `actor CommandGovernor` with `init(actionFloor: Int = 6)` and
    `func dispatch(_ kind: OperationKind, on deviceCode: String, params: CommandParams) async -> CommandDispatchResult`
  - `public struct CommandGovernorClient: Sendable` with
    `var dispatch: @Sendable (OperationKind, String, CommandParams) async -> CommandDispatchResult`,
    vended as `@Dependency(\.commandGovernor)`

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/GameServices/Tests/CommandGovernorTests.swift`:

```swift
//
//  CommandGovernorTests.swift
//  Replicould — GameServices
//
//  The governor spends the ACTIONS budget the way `PollCoordinator` spends the
//  reads budget: refuse under pressure, and never let two commands race at one
//  device.
//

import API
import Dependencies
import Foundation
import GameModels
import GameSession
import Testing
@testable import GameServices

private func budgetGameClient(actionsRemaining: Int) -> GameClient {
    GameClient(
        make: { ReplicantSpace.client(apiKey: "") },
        budget: { _ in
            RateLimitGovernor.Snapshot(limit: 60, remaining: actionsRemaining, resetAt: nil)
        }
    )
}

@Suite("CommandGovernor")
struct CommandGovernorTests {
    /// With budget to spare, the command goes through and the outcome is passed
    /// back untouched — the governor gates, it never reinterprets.
    @Test func dispatchesWhenBudgetAllows() async {
        let governor = CommandGovernor()
        let result = await withDependencies {
            $0.gameClient = budgetGameClient(actionsRemaining: 40)
            $0.commandClient.dispatch = { _, _, _ in .accepted(operationID: "OP1") }
        } operation: {
            await governor.dispatch(.travel, on: "VES1", params: CommandParams(destination: "SOL"))
        }
        #expect(result == .dispatched(.accepted(operationID: "OP1")))
    }

    /// At or below the floor the command is deferred, NOT failed: the engine
    /// re-evaluates on its next tick and the step is simply late, never lost.
    @Test func defersUnderBudgetPressure() async {
        let governor = CommandGovernor(actionFloor: 6)
        let posted = LockIsolated(false)
        let result = await withDependencies {
            $0.gameClient = budgetGameClient(actionsRemaining: 6)
            $0.commandClient.dispatch = { _, _, _ in
                posted.setValue(true)
                return .accepted(operationID: nil)
            }
        } operation: {
            await governor.dispatch(.travel, on: "VES1", params: CommandParams(destination: "SOL"))
        }
        #expect(result == .deferred(.budgetExhausted))
        #expect(posted.value == false, "a deferred command must never reach the network")
    }

    /// One command per device: a second dispatch while the first is in flight is
    /// deferred rather than queued. Two commands racing at one device is how a
    /// mission double-issues a step after a slow POST.
    @Test func refusesASecondCommandForTheSameDevice() async {
        let governor = CommandGovernor()
        let gate = AsyncStream<Void>.makeStream()
        let calls = LockIsolated(0)
        await withDependencies {
            $0.gameClient = budgetGameClient(actionsRemaining: 40)
            $0.commandClient.dispatch = { _, _, _ in
                calls.withValue { $0 += 1 }
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
                return .accepted(operationID: nil)
            }
        } operation: {
            async let first = governor.dispatch(.travel, on: "VES1", params: CommandParams())
            // Let the first claim the device before the second asks.
            await Task.yield()
            let second = await governor.dispatch(.stow, on: "VES1", params: CommandParams())
            #expect(second == .deferred(.commandInFlight))
            gate.continuation.yield()
            gate.continuation.finish()
            _ = await first
            #expect(calls.value == 1)
        }
    }

    /// Different devices don't block each other — the guard is per-device.
    @Test func allowsConcurrentCommandsOnDifferentDevices() async {
        let governor = CommandGovernor()
        let results = await withDependencies {
            $0.gameClient = budgetGameClient(actionsRemaining: 40)
            $0.commandClient.dispatch = { _, _, _ in .accepted(operationID: nil) }
        } operation: {
            async let a = governor.dispatch(.travel, on: "VES1", params: CommandParams())
            async let b = governor.dispatch(.travel, on: "VES2", params: CommandParams())
            return await [a, b]
        }
        #expect(results == [.dispatched(.accepted(operationID: nil)), .dispatched(.accepted(operationID: nil))])
    }

    /// The in-flight claim is released on EVERY path, including a rejection —
    /// otherwise one server 4xx would wedge that device for the session.
    @Test func releasesTheClaimAfterARejection() async {
        let governor = CommandGovernor()
        await withDependencies {
            $0.gameClient = budgetGameClient(actionsRemaining: 40)
            $0.commandClient.dispatch = { _, _, _ in .rejected("device busy") }
        } operation: {
            let first = await governor.dispatch(.travel, on: "VES1", params: CommandParams())
            #expect(first == .dispatched(.rejected("device busy")))
            let second = await governor.dispatch(.travel, on: "VES1", params: CommandParams())
            #expect(second == .dispatched(.rejected("device busy")), "the claim must not survive a rejection")
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --test-product GameServicesPackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — no `CommandGovernor`.

- [ ] **Step 3: Write the actor**

Create `app/Modules/GameServices/Sources/CommandGovernor.swift`:

```swift
//
//  CommandGovernor.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Spends the ACTIONS budget the way `PollCoordinator` spends the reads budget
//  (design spec §6, V3.9 blocker 3). Every engine-issued command passes through
//  here, which buys two things one directive executor could not give itself:
//
//    • Budget-aware deferral: under actions-bucket pressure the command is
//      DEFERRED, not failed — the executor re-evaluates on its next tick, so a
//      busy minute makes a step late rather than stalling the mission.
//    • Per-device in-flight guard: one command per device at a time. Two
//      executors (or an executor and a future UI adopter) cannot race a second
//      POST at a device whose first POST is still open — the shape that
//      double-issues a step after a slow response.
//
//  An actor so the claim set stays consistent under concurrent dispatches.
//  Deliberately does NOT reinterpret outcomes: the gate is the whole job.
//

import API
import Dependencies
import Foundation
import GameModels
import GameSession
import OSLog

private let logger = Logger(subsystem: "name.pennig.replicould", category: "CommandGovernor")

/// Why the governor declined to POST. Both are retryable on the next tick — a
/// deferral is never a failure and never touches the directive's status.
public enum CommandDeferral: String, Sendable, Equatable {
    /// The actions bucket is at or below the reserve floor.
    case budgetExhausted
    /// Another command for this device is still in flight.
    case commandInFlight
}

/// The result of asking the governor to dispatch.
public enum CommandDispatchResult: Sendable, Equatable {
    /// The command reached `CommandClient`; the outcome is its verdict verbatim.
    case dispatched(CommandOutcome)
    /// The command never left — retry on the next evaluation.
    case deferred(CommandDeferral)
}

actor CommandGovernor {
    /// Defer once the actions bucket drops to this many tokens. Proportional to
    /// `PollCoordinator`'s reads floor (12 of 120) against the 60/min actions
    /// limit, leaving headroom for manual UI commands and the CLI.
    private let actionFloor: Int
    /// Devices with a command in flight right now.
    private var inFlight: Set<String> = []

    init(actionFloor: Int = 6) {
        self.actionFloor = actionFloor
    }

    func dispatch(
        _ kind: OperationKind,
        on deviceCode: String,
        params: CommandParams
    ) async -> CommandDispatchResult {
        guard !inFlight.contains(deviceCode) else {
            logger.debug("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): deferred (command in flight)")
            return .deferred(.commandInFlight)
        }

        @Dependency(\.gameClient) var gameClient
        let budget = await gameClient.budget(.actions)
        // Re-check after the suspension: another dispatch may have claimed the
        // device while this one awaited the budget snapshot.
        guard !inFlight.contains(deviceCode) else {
            logger.debug("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): deferred (command claimed during budget read)")
            return .deferred(.commandInFlight)
        }
        guard budget.remaining > actionFloor else {
            logger.notice("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): deferred (actions budget \(budget.remaining) ≤ floor \(self.actionFloor))")
            return .deferred(.budgetExhausted)
        }

        inFlight.insert(deviceCode)
        defer { inFlight.remove(deviceCode) }

        @Dependency(\.commandClient) var commandClient
        let outcome = await commandClient.dispatch(kind, deviceCode, params)
        logger.info("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): \(String(describing: outcome), privacy: .public)")
        return .dispatched(outcome)
    }
}
```

- [ ] **Step 4: Write the client**

Create `app/Modules/GameServices/Sources/CommandGovernorClient.swift`:

```swift
//
//  CommandGovernorClient.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The seam every engine dispatch goes through, fronting one process-shared
//  `CommandGovernor` so the per-device in-flight claim is global rather than
//  per-executor. Vended as `@Dependency(\.commandGovernor)`, mirroring
//  `DeviceRefreshClient` over `PollCoordinator`.
//

import Dependencies
import Foundation
import GameModels

public struct CommandGovernorClient: Sendable {
    /// Dispatch a command subject to the actions budget and the per-device
    /// in-flight guard. Never throws; a refusal comes back as `.deferred`.
    public var dispatch: @Sendable (
        _ kind: OperationKind,
        _ deviceCode: String,
        _ params: CommandParams
    ) async -> CommandDispatchResult

    public init(
        dispatch: @escaping @Sendable (OperationKind, String, CommandParams) async -> CommandDispatchResult
    ) {
        self.dispatch = dispatch
    }
}

extension CommandGovernorClient: DependencyKey {
    /// One governor for the whole process — the in-flight claim only means
    /// anything if every caller shares it.
    public static let liveValue: CommandGovernorClient = {
        let governor = CommandGovernor()
        return CommandGovernorClient { kind, deviceCode, params in
            await governor.dispatch(kind, on: deviceCode, params: params)
        }
    }()

    /// Loud by default: a test that dispatches without stubbing this must fail.
    public static let testValue = CommandGovernorClient(
        dispatch: unimplemented(
            "\(Self.self).dispatch",
            placeholder: .deferred(.budgetExhausted)
        )
    )

    public static let previewValue = CommandGovernorClient { _, _, _ in
        .dispatched(.accepted(operationID: nil))
    }
}

extension DependencyValues {
    public var commandGovernor: CommandGovernorClient {
        get { self[CommandGovernorClient.self] }
        set { self[CommandGovernorClient.self] = newValue }
    }
}
```

`unimplemented` comes from `IssueReporting` via `Dependencies` — if the import doesn't resolve, add `import IssueReporting` (see the pfw-issue-reporting skill and how other clients in this module do it).

- [ ] **Step 5: Run the tests to verify they pass**

```bash
swift build 2>&1 | tail -3
swift test --test-product GameServicesPackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: empty.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/GameServices
git commit -m "Add CommandGovernor: gate engine dispatches on budget and one-per-device"
```

---

### Task 7: The `DirectiveEngine` module and its mission seam

The new SPM module plus the pure types Stages 4–5 write their missions against. No behavior yet — this task is done when the module builds, its types are tested, and nothing else changed.

**Files:**
- Modify: `app/Modules/Package.swift` (three edits, alphabetical: after `DirectiveComposerFeature`, before `DirectivesFeature`)
- Create: `app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift`
- Create: `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift`
- Test: `app/Modules/DirectiveEngine/Tests/WorldSnapshotTests.swift`

**Interfaces:**
- Consumes: `Device`, `Operation`, `Directive`, `DirectiveAttentionReason`, `DirectiveKind` (GameModels); `OperationKind`, `CommandParams` (GameServices/GameModels).
- Produces:
  - `public struct WorldSnapshot: Equatable, Sendable` — `devices: [String: Device]`, `openOperations: [String: Operation]`, `now: Date`; `func device(_ code: String) -> Device?`, `func openOperation(for code: String) -> Operation?`; `static func read(from database: any DatabaseReader, now: Date) async throws -> WorldSnapshot`
  - `public enum MissionAction: Equatable, Sendable` — `.dispatch(kind: OperationKind, deviceCode: String, params: CommandParams, nextStep: String)`, `.wait`, `.stall(DirectiveAttentionReason)`, `.advanceTarget`, `.done`
  - `public protocol MissionStepMachine: Sendable` — `var kind: DirectiveKind { get }`, `var firstStep: String { get }`, `func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction`

- [ ] **Step 1: Create the module directories and Package.swift entries**

```bash
mkdir -p app/Modules/DirectiveEngine/Sources app/Modules/DirectiveEngine/Tests
```

In `app/Modules/Package.swift`, add the product (after the `DirectiveComposerFeature` library line, before `DirectivesFeature`):

```swift
        .library(name: "DirectiveEngine", targets: ["DirectiveEngine"]),
```

the target (in the same alphabetical position among targets):

```swift
        .target(
            name: "DirectiveEngine",
            dependencies: [
                "API",
                "GameModels",
                "GameServices",
                "Utils",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "DirectiveEngine/Sources"
        ),
```

and the test target:

```swift
        .testTarget(
            name: "DirectiveEngineTests",
            dependencies: [
                "API",
                "DirectiveEngine",
                "GameDatabase",
                "GameModels",
                "GameServices",
                "GameSession",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "DirectiveEngine/Tests"
        ),
```

No `ComposableArchitecture` — TCA is for feature modules by manifest.

- [ ] **Step 2: Write the failing snapshot test**

Create `app/Modules/DirectiveEngine/Tests/WorldSnapshotTests.swift`:

```swift
//
//  WorldSnapshotTests.swift
//  Replicould — DirectiveEngine
//
//  The read-only view of reconciled state a step machine reasons over. Built
//  from SQLite, never from raw events — that invariant is what makes missions
//  replay-immune and loop-proof.
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import DirectiveEngine

private typealias Operation = GameModels.Operation

@Suite("WorldSnapshot")
struct WorldSnapshotTests {
    /// Devices and the one open op per device are keyed for O(1) lookup, and a
    /// CLOSED op is absent — a step machine asking "is this device busy?" must
    /// never see a completed op as in-progress.
    @Test func readsDevicesAndOnlyOpenOperations() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert { Self.device("VES1") }.execute(db)
            try Device.insert { Self.device("AMI1") }.execute(db)
            try Operation.insert { Self.op("OP1", device: "VES1", status: .active) }.execute(db)
            try Operation.insert { Self.op("OP2", device: "AMI1", status: .completed) }.execute(db)
        }
        let now = Date(timeIntervalSince1970: 5_000)
        let world = try await WorldSnapshot.read(from: database, now: now)

        #expect(world.devices.keys.sorted() == ["AMI1", "VES1"])
        #expect(world.device("VES1")?.deviceCode == "VES1")
        #expect(world.openOperation(for: "VES1")?.id == "OP1")
        #expect(world.openOperation(for: "AMI1") == nil)
        #expect(world.now == now)
    }

    static func device(_ code: String) -> Device {
        Device(
            deviceCode: code, deviceType: "transport_hauler", replicantCode: "R1",
            status: "idle", location: nil, locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [], detail: .object([:]),
            updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func op(_ id: String, device: String, status: OperationStatus) -> Operation {
        Operation(
            id: id, entityCode: device, kind: OperationKind.travel.rawValue,
            status: status, source: OperationSource.optimistic,
            startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
            lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
        )
    }
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
swift test --test-product DirectiveEnginePackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — no `WorldSnapshot`.

- [ ] **Step 4: Write `WorldSnapshot`**

Create `app/Modules/DirectiveEngine/Sources/WorldSnapshot.swift`:

```swift
//
//  WorldSnapshot.swift
//  Replicould — DirectiveEngine
//
//  The world as a step machine sees it: one consistent read of reconciled
//  SQLite state, keyed for lookup. Missions are pure functions over this — they
//  perform no I/O and never see a raw event, which is what makes them testable
//  as fixtures and immune to replay (design spec §4/§6).
//

import Foundation
import GameModels
import SQLiteData

private typealias Operation = GameModels.Operation

public struct WorldSnapshot: Equatable, Sendable {
    /// The fleet, by device code.
    public let devices: [String: Device]
    /// The single OPEN operation per device, by device code. Closed ops are
    /// excluded — a step machine asks "is this device busy?" and a completed op
    /// is not busy.
    public let openOperations: [String: Operation]
    /// The moment this snapshot was taken; every time comparison in a mission
    /// uses this rather than `Date()`, so tests are deterministic.
    public let now: Date

    public init(devices: [String: Device], openOperations: [String: Operation], now: Date) {
        self.devices = devices
        self.openOperations = openOperations
        self.now = now
    }

    public func device(_ code: String) -> Device? { devices[code] }
    public func openOperation(for code: String) -> Operation? { openOperations[code] }

    /// One consistent read of the tables a mission reasons over.
    public static func read(from database: any DatabaseReader, now: Date) async throws -> WorldSnapshot {
        try await database.read { db in
            let devices = try Device.all.fetchAll(db)
            let operations = try Operation
                .where { $0.status.in(OperationStatus.openCases) }
                .fetchAll(db)
            return WorldSnapshot(
                devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
                openOperations: Dictionary(operations.map { ($0.entityCode, $0) }, uniquingKeysWith: { _, last in last }),
                now: now
            )
        }
    }
}
```

- [ ] **Step 5: Write the mission seam**

Create `app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift`:

```swift
//
//  MissionStepMachine.swift
//  Replicould — DirectiveEngine
//
//  A mission is a pure step machine: (directive state, world snapshot) → ONE
//  action. The engine owns every side effect — dispatching, writing rows,
//  waiting — and mission logic owns none, so the stall matrix (design spec §8)
//  is a table of plain function calls over fixtures.
//
//  No machines ship in this stage: Survey Run is Stage 4, Relay Run is Stage 5.
//  The engine's registry is empty in production and populated by fakes in tests.
//

import Foundation
import GameModels
import GameServices

/// What a mission wants to happen next. Exactly one per evaluation — a machine
/// that needs two things in a row expresses the second on the next tick, which
/// is what keeps every step recoverable after a relaunch.
public enum MissionAction: Equatable, Sendable {
    /// POST a command, then move to `nextStep`. The engine routes it through
    /// `CommandGovernor`, so a deferral is invisible to the machine — it simply
    /// gets asked again.
    case dispatch(kind: OperationKind, deviceCode: String, params: CommandParams, nextStep: String)
    /// Nothing to do yet — something server-side is still in progress. Expected
    /// and cheap; the engine takes no action at all.
    case wait
    /// Pause and surface. The engine sets `needsAttention` + the reason and
    /// stops evaluating until the user resolves it. Never auto-retried at the
    /// mission layer (design spec §8).
    case stall(DirectiveAttentionReason)
    /// This target is finished; move to the next one (or finish the run).
    case advanceTarget
    /// The whole run is finished.
    case done
}

/// One mission kind's procedure.
public protocol MissionStepMachine: Sendable {
    /// The directive kind this machine runs.
    var kind: DirectiveKind { get }
    /// The step a freshly-started target begins on — the engine writes it when
    /// advancing the queue, so the machine owns its own step vocabulary.
    var firstStep: String { get }
    /// The single next action. MUST be pure: no I/O, no clock reads (use
    /// `world.now`), no randomness.
    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction
}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
swift build --build-tests 2>&1 | tail -3
swift test --test-product DirectiveEnginePackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: empty. Re-run `scripts/link-index-store.sh` after this build so LSP sees the new module.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/Package.swift app/Modules/DirectiveEngine
git commit -m "Add the DirectiveEngine module and its mission seam"
```

---

### Task 8: The executor loop

The engine proper: a supervisor that keeps one serial executor alive per running directive, and an executor that evaluates its mission on a clock tick and applies the single resulting action — writing the `DirectiveLogEntry` timeline as it goes. Proven end-to-end with a fake step machine.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift`
- Create: `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift`
- Test: `app/Modules/DirectiveEngine/Tests/DirectiveEngineTests.swift`

**Interfaces:**
- Consumes: `MissionStepMachine`, `MissionAction`, `WorldSnapshot` (Task 7); `@Dependency(\.commandGovernor)` (Task 6); `Directive`, `DirectiveLogEntry`, `DirectiveStatus`.
- Produces:
  - `public struct DirectiveEngine: Sendable` — `var start: @Sendable () async -> Void`, `var stop: @Sendable () async -> Void`; `static func makeLive(machines: [any MissionStepMachine] = []) -> DirectiveEngine`; `@Dependency(\.directiveEngine)`
  - `actor DirectiveEngineCore` — `init(machines:tick:)`, `func start()`, `func stop() async`, `func evaluateOnce(directiveID: String) async` (internal, the unit the tests drive)

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/DirectiveEngine/Tests/DirectiveEngineTests.swift`:

```swift
//
//  DirectiveEngineTests.swift
//  Replicould — DirectiveEngine
//
//  The executor loop, driven by fake step machines. No real mission ships until
//  Stage 4, so these tests ARE the proof the loop is correct: one action per
//  evaluation, every action's row writes, and a timeline entry for each.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
@testable import DirectiveEngine

/// A machine that returns a scripted sequence, one action per evaluation.
private struct ScriptedMachine: MissionStepMachine {
    let kind: DirectiveKind = .surveyRun
    let firstStep = "start"
    let script: LockIsolated<[MissionAction]>

    init(_ actions: [MissionAction]) { script = LockIsolated(actions) }

    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction {
        script.withValue { remaining in
            remaining.isEmpty ? .wait : remaining.removeFirst()
        }
    }
}

@Suite("DirectiveEngine executor")
struct DirectiveEngineTests {
    /// A `.dispatch` action POSTs through the governor, advances the step, and
    /// writes both timeline entries.
    @Test func dispatchAdvancesTheStepAndLogsIt() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(step: "start") }.execute(db)
        }
        let machine = ScriptedMachine([
            .dispatch(kind: .travel, deviceCode: "VES1", params: CommandParams(destination: "SOL"), nextStep: "travelling")
        ])
        let core = DirectiveEngineCore(machines: [machine], tick: .seconds(5))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.commandGovernor.dispatch = { _, _, _ in .dispatched(.accepted(operationID: "OP1")) }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")

            let directive = try await database.read { db in
                try Directive.find("D1").fetchOne(db)
            }
            #expect(directive?.step == "travelling")
            #expect(directive?.stepStartedAt == Date(timeIntervalSince1970: 1_000))
            #expect(directive?.status == .running)

            let entries = try await database.read { db in
                try DirectiveLogEntry.order { $0.occurredAt }.fetchAll(db)
            }
            #expect(entries.map(\.kind) == [.stepStarted, .commandDispatched])
            #expect(entries.allSatisfy { $0.directiveID == "D1" })
            #expect(entries.last?.operationID == "OP1")
        }
    }

    /// A DEFERRED dispatch changes nothing: the step doesn't move, nothing is
    /// logged, and the next tick simply asks again. A deferral is not a failure.
    @Test func deferredDispatchLeavesTheDirectiveUntouched() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(step: "start") }.execute(db)
        }
        let machine = ScriptedMachine([
            .dispatch(kind: .travel, deviceCode: "VES1", params: CommandParams(), nextStep: "travelling")
        ])
        let core = DirectiveEngineCore(machines: [machine], tick: .seconds(5))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.commandGovernor.dispatch = { _, _, _ in .deferred(.budgetExhausted) }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in try Directive.find("D1").fetchOne(db) }
            #expect(directive?.step == "start")
            #expect(directive?.status == .running)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.isEmpty)
        }
    }

    /// A REJECTED command stalls the mission with `commandRejected` — the
    /// engine never improvises or retries at the mission layer.
    @Test func rejectedCommandStallsTheMission() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(step: "start") }.execute(db)
        }
        let machine = ScriptedMachine([
            .dispatch(kind: .travel, deviceCode: "VES1", params: CommandParams(), nextStep: "travelling")
        ])
        let core = DirectiveEngineCore(machines: [machine], tick: .seconds(5))

        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.commandGovernor.dispatch = { _, _, _ in .dispatched(.rejected("device busy")) }
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in try Directive.find("D1").fetchOne(db) }
            #expect(directive?.status == .needsAttention)
            #expect(directive?.attentionReason == .commandRejected)
            #expect(directive?.step == "start", "a stall must not advance the step")
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind) == [.stalled])
        }
    }

    /// `.stall` sets the typed reason and logs it.
    @Test func stallSetsTheReason() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(
            machines: [ScriptedMachine([.stall(.noSurveyDroneAboard)])],
            tick: .seconds(5)
        )
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in try Directive.find("D1").fetchOne(db) }
            #expect(directive?.status == .needsAttention)
            #expect(directive?.attentionReason == .noSurveyDroneAboard)
        }
    }

    /// `.advanceTarget` moves the queue on and resets the step to the machine's
    /// first step.
    @Test func advanceTargetMovesTheQueue() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(step: "surveying", targets: ["SOL", "TAU"], targetIndex: 0) }.execute(db)
        }
        let core = DirectiveEngineCore(machines: [ScriptedMachine([.advanceTarget])], tick: .seconds(5))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in try Directive.find("D1").fetchOne(db) }
            #expect(directive?.targetIndex == 1)
            #expect(directive?.step == "start")
        }
    }

    /// `.done` completes the run and stops it being executed again.
    @Test func doneCompletesTheRun() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(step: "surveying") }.execute(db)
        }
        let core = DirectiveEngineCore(machines: [ScriptedMachine([.done])], tick: .seconds(5))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in try Directive.find("D1").fetchOne(db) }
            #expect(directive?.status == .completed)
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.map(\.kind) == [.directiveCompleted])
        }
    }

    /// A directive whose kind has no registered machine is left completely
    /// alone — in this stage that is EVERY production directive, so a bug here
    /// would corrupt rows the moment the engine starts.
    @Test func unknownKindIsLeftAlone() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(step: "start", kind: .relayRun) }.execute(db)
        }
        let core = DirectiveEngineCore(machines: [ScriptedMachine([.done])], tick: .seconds(5))
        try await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
        } operation: {
            await core.evaluateOnce(directiveID: "D1")
            let directive = try await database.read { db in try Directive.find("D1").fetchOne(db) }
            #expect(directive?.status == .running)
            #expect(directive?.step == "start")
            let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
            #expect(entries.isEmpty)
        }
    }

    /// A stalled or paused directive is not evaluated — resolution is the
    /// user's move, and a tick must never resume one behind their back.
    @Test func nonRunningDirectivesAreNotEvaluated() async throws {
        for status in [DirectiveStatus.needsAttention, .paused, .completed, .cancelled] {
            let database = try GameDatabase.bootstrap()
            try await database.write { db in
                try Directive.insert { Self.mission(step: "start", status: status) }.execute(db)
            }
            let core = DirectiveEngineCore(machines: [ScriptedMachine([.done])], tick: .seconds(5))
            try await withDependencies {
                $0.defaultDatabase = database
                $0.date = .constant(Date(timeIntervalSince1970: 1_000))
                $0.uuid = .incrementing
            } operation: {
                await core.evaluateOnce(directiveID: "D1")
                let directive = try await database.read { db in try Directive.find("D1").fetchOne(db) }
                #expect(directive?.status == status, "\(status) must not be advanced by a tick")
            }
        }
    }

    /// `stop()` cancels the supervisor and every executor — a logout must not
    /// leave a task writing into freshly-wiped tables.
    @Test func stopCancelsEverything() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(step: "start") }.execute(db)
        }
        let core = DirectiveEngineCore(machines: [ScriptedMachine([.wait])], tick: .seconds(5))
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
        } operation: {
            await core.start()
            await core.stop()
            let running = await core.executorCount
            #expect(running == 0)
        }
    }

    static func mission(
        step: String,
        kind: DirectiveKind = .surveyRun,
        status: DirectiveStatus = .running,
        targets: [String] = ["SOL"],
        targetIndex: Int = 0
    ) -> Directive {
        Directive(
            id: "D1", kind: kind, status: status, deviceCode: "VES1",
            targets: targets, targetIndex: targetIndex, step: step,
            stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --test-product DirectiveEnginePackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — no `DirectiveEngineCore`.

- [ ] **Step 3: Write the executor**

Create `app/Modules/DirectiveEngine/Sources/DirectiveExecutor.swift`:

```swift
//
//  DirectiveExecutor.swift
//  Replicould — DirectiveEngine
//
//  Applying one `MissionAction` to the database. Split out from the engine so
//  the state transitions — the part a bug would corrupt rows with — are a plain
//  function over (directive, action) rather than something tangled in task
//  lifecycle.
//
//  Every write here also appends the `DirectiveLogEntry` that makes the step
//  visible in the detail pane's timeline (V3.9 blocker 5: the audit trail IS
//  the browsing UI).
//

import Dependencies
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

enum DirectiveExecutor {
    /// Apply one action. Returns whether the directive is still runnable — a
    /// stall or a completion retires its executor.
    @discardableResult
    static func apply(
        _ action: MissionAction,
        to directive: Directive,
        machine: any MissionStepMachine
    ) async -> Bool {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid

        switch action {
        case .wait:
            return true

        case let .dispatch(kind, deviceCode, params, nextStep):
            @Dependency(\.commandGovernor) var commandGovernor
            let result = await commandGovernor.dispatch(kind, deviceCode, params)
            switch result {
            case let .deferred(reason):
                // Not a failure: the governor will let it through on a later
                // tick. Deliberately writes nothing — a deferral that logged
                // would fill the timeline with noise the user can't act on.
                logger.debug("directive \(directive.id, privacy: .public): \(kind.rawValue, privacy: .public) deferred (\(reason.rawValue, privacy: .public))")
                return true

            case let .dispatched(outcome):
                switch outcome {
                case let .accepted(operationID):
                    var updated = directive
                    updated.step = nextStep
                    updated.stepStartedAt = date.now
                    updated.updatedAt = date.now
                    await write { db in
                        try Directive.upsert { updated }.execute(db)
                        try DirectiveLogEntry.insert {
                            entry(directive: directive, kind: .stepStarted,
                                  summary: "Step: \(nextStep)", step: nextStep,
                                  operationID: nil, id: uuid().uuidString, at: date.now)
                        }.execute(db)
                        try DirectiveLogEntry.insert {
                            entry(directive: directive, kind: .commandDispatched,
                                  summary: "Dispatched \(kind.rawValue) to \(deviceCode)",
                                  step: nextStep, operationID: operationID,
                                  id: uuid().uuidString, at: date.now)
                        }.execute(db)
                    }
                    return true

                case let .rejected(message), let .failed(message):
                    await stall(directive, reason: .commandRejected, detail: message)
                    return false
                }
            }

        case let .stall(reason):
            await stall(directive, reason: reason, detail: nil)
            return false

        case .advanceTarget:
            var updated = directive
            updated.targetIndex += 1
            updated.step = machine.firstStep
            updated.stepStartedAt = date.now
            updated.updatedAt = date.now
            await write { db in
                try Directive.upsert { updated }.execute(db)
                try DirectiveLogEntry.insert {
                    entry(directive: directive, kind: .stepStarted,
                          summary: updated.currentTarget.map { "Target: \($0)" } ?? "Queue exhausted",
                          step: machine.firstStep, operationID: nil,
                          id: uuid().uuidString, at: date.now)
                }.execute(db)
            }
            return true

        case .done:
            var updated = directive
            updated.status = .completed
            updated.attentionReason = nil
            updated.updatedAt = date.now
            await write { db in
                try Directive.upsert { updated }.execute(db)
                try DirectiveLogEntry.insert {
                    entry(directive: directive, kind: .directiveCompleted,
                          summary: "\(directive.kind.title) completed", step: nil,
                          operationID: nil, id: uuid().uuidString, at: date.now)
                }.execute(db)
            }
            logger.info("directive \(directive.id, privacy: .public) completed")
            return false
        }
    }

    /// Pause and surface (design spec §8) — a typed reason, never a retry.
    private static func stall(
        _ directive: Directive,
        reason: DirectiveAttentionReason,
        detail: String?
    ) async {
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid
        var updated = directive
        updated.status = .needsAttention
        updated.attentionReason = reason
        updated.updatedAt = date.now
        let summary = detail.map { "\(reason.rawValue): \($0)" } ?? reason.rawValue
        await write { db in
            try Directive.upsert { updated }.execute(db)
            try DirectiveLogEntry.insert {
                entry(directive: directive, kind: .stalled, summary: summary,
                      step: directive.step, operationID: nil,
                      id: uuid().uuidString, at: date.now)
            }.execute(db)
        }
        logger.notice("directive \(directive.id, privacy: .public) stalled: \(summary, privacy: .public)")
    }

    private static func entry(
        directive: Directive,
        kind: DirectiveLogKind,
        summary: String,
        step: String?,
        operationID: String?,
        id: String,
        at occurredAt: Date
    ) -> DirectiveLogEntry {
        DirectiveLogEntry(
            id: id, directiveID: directive.id, deviceCode: nil, kind: kind,
            summary: summary, step: step, operationID: operationID,
            eventID: nil, occurredAt: occurredAt
        )
    }

    /// One write transaction, reported rather than thrown — an executor must
    /// never take the engine down over a transient write failure; the next tick
    /// re-evaluates from whatever the row still says.
    private static func write(_ body: @escaping @Sendable (Database) throws -> Void) async {
        @Dependency(\.defaultDatabase) var database
        do {
            try await database.write { db in try body(db) }
        } catch {
            logger.error("directive write failed: \(error)")
        }
    }
}
```

If `Database` is not the right parameter type for this codebase's `database.write { db in … }` closure, match whatever `Reconciler.completeOpenOperation` uses and say so.

- [ ] **Step 4: Write the engine**

Create `app/Modules/DirectiveEngine/Sources/DirectiveEngine.swift`:

```swift
//
//  DirectiveEngine.swift
//  Replicould — DirectiveEngine
//
//  One serial executor per RUNNING custom directive, off the event-dispatch hot
//  path (design spec §6). Built-in directives have no executor — the server runs
//  them.
//
//  Evaluation is clock-driven rather than event-driven on purpose: an
//  evaluation is a local SQLite read plus a pure function, and it only touches
//  the network when the mission actually wants a command. That buys replay
//  immunity for free (the engine never sees an event) and makes every test
//  deterministic under `TestClock` — no observation plumbing to get wrong.
//
//  Lifecycle is owned by the composition root: started with the sync engine on
//  login, and stopped BEFORE the directive tables are wiped on logout.
//

import Dependencies
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public struct DirectiveEngine: Sendable {
    /// Begin supervising running directives. Idempotent.
    public var start: @Sendable () async -> Void
    /// Cancel the supervisor and every executor. Must complete before the
    /// directive tables are wiped.
    public var stop: @Sendable () async -> Void

    public init(
        start: @escaping @Sendable () async -> Void,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.start = start
        self.stop = stop
    }

    /// `machines` is EMPTY in this stage — Survey Run lands in Stage 4, Relay
    /// Run in Stage 5. With no machine for a kind the engine leaves the row
    /// completely alone, so starting it today is a no-op on real data.
    public static func makeLive(machines: [any MissionStepMachine] = []) -> DirectiveEngine {
        let core = DirectiveEngineCore(machines: machines, tick: .seconds(5))
        return DirectiveEngine(
            start: { await core.start() },
            stop: { await core.stop() }
        )
    }
}

actor DirectiveEngineCore {
    private let machines: [DirectiveKind: any MissionStepMachine]
    private let tick: Duration
    private var supervisor: Task<Void, Never>?
    private var executors: [String: Task<Void, Never>] = [:]

    /// Test seam: how many executors are alive.
    var executorCount: Int { executors.count }

    init(machines: [any MissionStepMachine], tick: Duration) {
        self.machines = Dictionary(machines.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        self.tick = tick
    }

    /// Synchronous on the actor before any suspension, so a concurrent start
    /// can't double-supervise (the `GameSyncEngine.start()` shape).
    func start() {
        guard supervisor == nil else {
            logger.debug("start ignored — already running")
            return
        }
        logger.info("starting — \(self.machines.count) mission machine(s) registered")
        @Dependency(\.continuousClock) var clock
        supervisor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcileExecutors()
                try? await clock.sleep(for: self?.tick ?? .seconds(5))
            }
        }
    }

    func stop() async {
        logger.info("stopping")
        supervisor?.cancel()
        supervisor = nil
        for (_, task) in executors { task.cancel() }
        executors.removeAll()
    }

    /// Spawn an executor for each running directive that lacks one, and retire
    /// executors whose directive is no longer running.
    private func reconcileExecutors() async {
        @Dependency(\.defaultDatabase) var database
        let running: [Directive]
        do {
            running = try await database.read { db in
                try Directive.where { $0.status.eq(DirectiveStatus.running) }.fetchAll(db)
            }
        } catch {
            logger.error("supervisor read failed: \(error)")
            return
        }

        let runningIDs = Set(running.map(\.id))
        for (id, task) in executors where !runningIDs.contains(id) {
            task.cancel()
            executors[id] = nil
        }
        for directive in running where executors[directive.id] == nil {
            executors[directive.id] = makeExecutor(directiveID: directive.id)
        }
    }

    private func makeExecutor(directiveID: String) -> Task<Void, Never> {
        @Dependency(\.continuousClock) var clock
        let tick = self.tick
        return Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluateOnce(directiveID: directiveID)
                try? await clock.sleep(for: tick)
            }
        }
    }

    /// One evaluation: re-read the row (it may have changed under us), ask the
    /// machine for a single action, apply it. Re-reading each time is what makes
    /// the directive row the checkpoint a relaunch resumes from (spec §11).
    func evaluateOnce(directiveID: String) async {
        @Dependency(\.defaultDatabase) var database
        @Dependency(\.date) var date

        let directive: Directive?
        do {
            directive = try await database.read { db in try Directive.find(directiveID).fetchOne(db) }
        } catch {
            logger.error("executor read failed for \(directiveID, privacy: .public): \(error)")
            return
        }
        guard let directive, directive.status == .running else { return }
        guard let machine = machines[directive.kind] else {
            // Expected in Stage 3 for every real directive: no machines ship
            // until Stage 4. Leave the row entirely alone.
            logger.debug("no machine for \(directive.kind.rawValue, privacy: .public) — directive \(directiveID, privacy: .public) left alone")
            return
        }

        let world: WorldSnapshot
        do {
            world = try await WorldSnapshot.read(from: database, now: date.now)
        } catch {
            logger.error("world snapshot failed: \(error)")
            return
        }

        let action = machine.nextAction(directive: directive, world: world)
        let stillRunnable = await DirectiveExecutor.apply(action, to: directive, machine: machine)
        if !stillRunnable {
            executors[directiveID]?.cancel()
            executors[directiveID] = nil
        }
    }
}

// MARK: - Dependency

extension DirectiveEngine: DependencyKey {
    public static let liveValue = DirectiveEngine.makeLive()
}

extension DirectiveEngine: TestDependencyKey {
    /// Inert: engine tests drive `DirectiveEngineCore` directly, and no feature
    /// should be starting the engine.
    public static let testValue = DirectiveEngine(start: {}, stop: {})
}

extension DependencyValues {
    public var directiveEngine: DirectiveEngine {
        get { self[DirectiveEngine.self] }
        set { self[DirectiveEngine.self] = newValue }
    }
}
```

Note the executor cancels *itself* from inside `evaluateOnce` when the action retires the directive; because `evaluateOnce` runs on the actor and the executor task awaits it, the cancel lands before the next sleep. If that self-cancel proves awkward under the compiler, cancel via the supervisor's next `reconcileExecutors()` instead (the row is no longer `.running`, so it retires within one tick) — and say which you did.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
swift build --build-tests 2>&1 | tail -3
swift test --test-product DirectiveEnginePackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: empty.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DirectiveEngine
git commit -m "Run one serial executor per directive over reconciled state"
```

---

### Task 9: The `directive.*` event route

Nothing routes `directive.*` today. This route's only job is writing a `DirectiveLogEntry` — the engine then observes the row, which is what keeps the observe-reconciled-state invariant intact (spec §6) and yields the timeline entry for free.

**Files:**
- Create: `app/Modules/DirectiveEngine/Sources/DirectiveIngestion.swift`
- Test: `app/Modules/DirectiveEngine/Tests/DirectiveIngestionTests.swift`

**Interfaces:**
- Consumes: `EventRoute`, `EventMatcher` (GameServices); `GameEventEnvelope` (API); `Directive.controllerCode` (Task 4).
- Produces: `public enum DirectiveIngestion { public static var eventRoute: EventRoute }`

**Behaviour, exactly:**
1. Matches `.category("directive")`; handles `directive.completed` and logs-and-skips any other `directive.*` name.
2. Always writes one entry with `deviceCode` = the envelope's device code, `eventID` = the envelope id, `kind` = `.directiveCompleted`.
3. Attributes `directiveID` **only** when a live directive has `controllerCode == deviceCode` **and** `event.date >= directive.stepStartedAt - 5s` — the issue-time-relative guard `Reconciler.completeOpenOperation` already implements (spec §5). A replayed pre-step completion is still recorded as history but is never attributed to the current step.
4. Idempotent: a re-delivered event writes nothing new (existence check inside the transaction; the `directive_log_unique_event` index is the backstop).

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/DirectiveEngine/Tests/DirectiveIngestionTests.swift`:

```swift
//
//  DirectiveIngestionTests.swift
//  Replicould — DirectiveEngine
//
//  The `directive.*` route: one log entry per completion, deduped by event id,
//  attributed to a mission only when the issue-time-relative guard passes.
//

import API
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
import Utils
@testable import DirectiveEngine

@Suite("Directive ingestion")
struct DirectiveIngestionTests {
    /// A completion with no owning mission still lands as built-in history,
    /// keyed by the controller.
    @Test func recordsABuiltInCompletion() async throws {
        let database = try GameDatabase.bootstrap()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await DirectiveIngestion.eventRoute.apply(Self.completion(id: "E1", device: "AMI1"))
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries.count == 1)
        #expect(entries[0].deviceCode == "AMI1")
        #expect(entries[0].directiveID == nil)
        #expect(entries[0].eventID == "E1")
        #expect(entries[0].kind == .directiveCompleted)
    }

    /// Re-delivery (catch-up replay, reconnect) must not duplicate the timeline.
    @Test func isIdempotentPerEventID() async throws {
        let database = try GameDatabase.bootstrap()
        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await DirectiveIngestion.eventRoute.apply(Self.completion(id: "E1", device: "AMI1"))
            await DirectiveIngestion.eventRoute.apply(Self.completion(id: "E1", device: "AMI1"))
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries.count == 1)
    }

    /// A live mission driving that controller gets the entry attributed to it,
    /// so the mission timeline shows the completion it was waiting for.
    @Test func attributesToTheOwningMission() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(stepStartedAt: Date(timeIntervalSince1970: 900)) }.execute(db)
        }
        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await DirectiveIngestion.eventRoute.apply(
                Self.completion(id: "E1", device: "AMI1", at: Date(timeIntervalSince1970: 1_000))
            )
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries[0].directiveID == "D1")
        #expect(entries[0].deviceCode == "AMI1")
    }

    /// A completion stamped BEFORE the current step started belongs to an
    /// earlier action — recorded as history, never attributed. This is the
    /// replay guard from spec §5, issue-time relative (not wall-clock), so a
    /// post-close catch-up completion still lands correctly.
    @Test func doesNotAttributeAReplayedPreStepCompletion() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(stepStartedAt: Date(timeIntervalSince1970: 1_000)) }.execute(db)
        }
        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await DirectiveIngestion.eventRoute.apply(
                Self.completion(id: "E1", device: "AMI1", at: Date(timeIntervalSince1970: 800))
            )
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries.count == 1)
        #expect(entries[0].directiveID == nil, "a pre-step completion must not close the current step")
        #expect(entries[0].deviceCode == "AMI1")
    }

    /// Within the 5s skew tolerance an event marginally older than the step
    /// start still counts — client/server clocks are not identical.
    @Test func toleratesClockSkew() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Directive.insert { Self.mission(stepStartedAt: Date(timeIntervalSince1970: 1_000)) }.execute(db)
        }
        try await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
        } operation: {
            await DirectiveIngestion.eventRoute.apply(
                Self.completion(id: "E1", device: "AMI1", at: Date(timeIntervalSince1970: 997))
            )
        }
        let entries = try await database.read { db in try DirectiveLogEntry.all.fetchAll(db) }
        #expect(entries[0].directiveID == "D1")
    }

    static func mission(stepStartedAt: Date) -> Directive {
        var directive = Directive(
            id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
            targets: ["SOL"], targetIndex: 0, step: "surveying",
            stepStartedAt: stepStartedAt, returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        directive.controllerCode = "AMI1"
        return directive
    }

    /// Build the envelope the way `GameEventEnvelope` is constructed elsewhere
    /// in the tests — match `GameSyncTests`' helper if the initializer differs.
    static func completion(
        id: String,
        device: String,
        at date: Date = Date(timeIntervalSince1970: 1_000)
    ) -> GameEventEnvelope {
        GameEventEnvelope(
            id: id,
            event: "directive.completed",
            category: "directive",
            deviceCode: device,
            location: "SOL",
            date: date,
            provenance: .stream,
            payload: ["directive": .string("survey_system")]
        )
    }
}
```

**Before writing these, open `app/Modules/GameSync/Tests/GameSyncTests.swift` and copy its `GameEventEnvelope` construction verbatim** — the initializer's exact labels are what the test compiles against.

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --test-product DirectiveEnginePackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```
Expected: compile failure — no `DirectiveIngestion`.

- [ ] **Step 3: Write the route**

Create `app/Modules/DirectiveEngine/Sources/DirectiveIngestion.swift`:

```swift
//
//  DirectiveIngestion.swift
//  Replicould — DirectiveEngine
//
//  The `directive.*` ingestion policy, declared beside the engine that consumes
//  its output (the `MessagesIngestion` / `LocationsIngestion` shape — the
//  composition root only wires it).
//
//  Its ONLY job is writing one `DirectiveLogEntry`. It never advances a mission:
//  the engine observes the row instead, which is what keeps
//  observe-reconciled-state intact and makes the timeline entry free.
//

import API
import Dependencies
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

public enum DirectiveIngestion {
    /// Tolerance when comparing an event's timestamp against a step's start —
    /// the same value and the same reasoning as
    /// `Reconciler.eventTimeSkewTolerance`: absorb clock skew without letting an
    /// earlier action's completion leak forward.
    static let eventTimeSkewTolerance: TimeInterval = 5

    public static var eventRoute: EventRoute {
        EventRoute(id: "directive", match: .category("directive")) { event in
            guard event.event == "directive.completed" else {
                // A directive event we don't recognise. The generic
                // unhandled-event notice can't fire (this route matched), so
                // announce it here — a new name in the taxonomy is a one-line
                // edit once it shows up in live traffic.
                logger.notice("⚠️ unhandled directive event \(event.event, privacy: .public) — payload keys: [\(event.payload?.keys.sorted().joined(separator: ", ") ?? "none", privacy: .public)]")
                return
            }
            guard let deviceCode = event.deviceCode, !deviceCode.isEmpty else {
                logger.notice("directive.completed without a device code — skipped")
                return
            }

            @Dependency(\.defaultDatabase) var database
            @Dependency(\.uuid) var uuid

            let directiveName = event.payload?["directive"]?.stringValue ?? "directive"
            let where_ = event.location.map { " at \($0)" } ?? ""
            let summary = "\(BlueprintPresentation.displayName(directiveName)) completed\(where_)"
            let eventID = event.id
            let eventDate = event.date
            let entryID = uuid().uuidString

            do {
                try await database.write { db in
                    // Idempotent: catch-up replay and reconnects re-deliver.
                    // The `directive_log_unique_event` partial index is the
                    // backstop; this check is what keeps a re-delivery from
                    // being an error path at all.
                    let existing = try DirectiveLogEntry
                        .where { $0.eventID.eq(eventID) }
                        .fetchCount(db)
                    guard existing == 0 else { return }

                    // Attribute to a live mission only when it is driving this
                    // controller AND the completion is not older than the
                    // current step. Issue-time relative, not wall-clock: a
                    // completion delivered by catch-up after the app was closed
                    // still lands, while a replayed pre-step event does not
                    // close a step it never belonged to (design spec §5).
                    let owner = try Directive
                        .where {
                            $0.controllerCode.eq(deviceCode)
                                && $0.status.eq(DirectiveStatus.running)
                        }
                        .fetchAll(db)
                        .first { directive in
                            eventDate >= directive.stepStartedAt
                                .addingTimeInterval(-eventTimeSkewTolerance)
                        }

                    try DirectiveLogEntry.insert {
                        DirectiveLogEntry(
                            id: entryID,
                            directiveID: owner?.id,
                            deviceCode: deviceCode,
                            kind: .directiveCompleted,
                            summary: summary,
                            step: owner?.step,
                            operationID: nil,
                            eventID: eventID,
                            occurredAt: eventDate
                        )
                    }
                    .execute(db)
                }
                logger.info("directive.completed on \(deviceCode, privacy: .public) recorded")
            } catch {
                logger.error("directive.completed write failed: \(error)")
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift build --build-tests 2>&1 | tail -3
swift test --test-product DirectiveEnginePackageTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events.jsonl | sort -u
```
Expected: empty.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine
git commit -m "Land directive.completed in the audit trail"
```

---

### Task 10: Wire it into the app, and record what Stage 3 established

The composition root opts the app into the engine. **The app target must link the new `DirectiveEngine` product — a pbxproj edit that only the user can make in Xcode.** The package stays green either way; the *app* will not compile until that link exists, so this task ends by saying so plainly rather than by claiming a working app.

**Files:**
- Modify: `app/macOS/ReplicantApp.swift:8-23` (import), `:57-106` (registration + lifecycle)
- Modify: `app/.claude/memory/directives-feature.md` (Stage 3 section)
- Modify: `app/.claude/memory/MEMORY.md` (index line for the directives note)

**Interfaces:**
- Consumes: `DirectiveIngestion.eventRoute` (Task 9), `@Dependency(\.directiveEngine)` (Task 8).
- Produces: nothing importable.

- [ ] **Step 1: Import and register the route**

Add `import DirectiveEngine` to the import block (alphabetical, after `BlueprintsFeature`).

In `registerGameSync()`, beside the other route registrations:

```swift
        gameSync.registerRoute(DirectiveIngestion.eventRoute)
```

- [ ] **Step 2: Hook the engine into the session lifecycle**

In `registerGameSync()`, resolve the dependency alongside the others:

```swift
        @Dependency(\.directiveEngine) var directiveEngine
```

and extend the existing `"gameSync"` handler — the engine starts after ingestion and stops **before** it, so no executor outlives the stream it depends on, and both are gone before `registerSessionCleanup`'s wipes (which run later, being registered later):

```swift
        accountManager.registerHandler(
            SessionLifecycleHandler(
                id: "gameSync",
                onLogin: {
                    await gameSync.start()
                    await directiveEngine.start()
                },
                onLogout: {
                    // Executors first: a directive step must never POST — or
                    // write a log row — after the tables it reads are cleared.
                    await directiveEngine.stop()
                    await gameSync.stop()
                    locationsIngestion.cancelPendingWork()
                    domainFreshness.reset()
                }
            )
        )
```

and start it on the restored-session launch path:

```swift
        if accountManager.restoredAPIKey() != nil {
            Task {
                await gameSync.start()
                await directiveEngine.start()
            }
        }
```

- [ ] **Step 3: Verify the package still builds and the full suite is green**

```bash
swift build --build-tests 2>&1 | tail -3
for product in $(swift package describe --type json | jq -r '.targets[] | select(.type=="test") | .name'); do
  swift test --test-product "${product%Tests}PackageTests" --disable-xctest \
    --event-stream-version 0 --event-stream-output-path ".build/events-$product.jsonl" >/dev/null 2>&1
done
jq -r 'select(.kind=="event" and .payload.kind=="issueRecorded" and (.payload.issue.isKnown|not)).payload.testID' .build/events-*.jsonl | sort -u
```
Expected: the final line prints nothing. If the product-name derivation above doesn't match this package's actual test products, list them with `swift package describe --type json | jq -r '.products[].name'` and loop over the real names instead.

`app/macOS/*` is **not** covered by `swift build` — it lives in the Xcode project. Do not claim the app compiles.

- [ ] **Step 4: Update the memory note**

In `app/.claude/memory/directives-feature.md`, replace the "Deferred to Stage 3" list (it is now done) and append a Stage 3 section recording:

- Stage 3 shipped: `CommandGovernor` (actions-budget floor 6 + per-device in-flight claim, `@Dependency(\.commandGovernor)`), the `DirectiveEngine` module (supervisor + one executor per running directive, 5s tick), `DirectiveIngestion.eventRoute`, and `Directive.controllerCode`.
- **Invariants not to undo:** evaluation is clock-driven, not event-driven (replay immunity + deterministic tests); a `.deferred` dispatch writes nothing and is not a failure; a directive with no registered machine is left entirely alone; `paused`/`needsAttention` KEEP controller ownership, only `completed`/`cancelled` release it; the engine stops before `gameSync` on logout, and both before the table wipes.
- **No mission machines ship yet** — the registry is empty in production, so starting the engine is a no-op on real data until Stage 4.
- The open design question is settled: engine-owned built-in rows are badged and locked (not hidden), which is why `controllerCode` exists.
- Whether the user has linked `DirectiveEngine` into the app target yet.

Update the matching index line in `app/.claude/memory/MEMORY.md` so it reads as Stage 3 shipped, engine skeleton live, missions pending.

- [ ] **Step 5: Commit**

```bash
git add app/macOS/ReplicantApp.swift app/.claude/memory
git commit -m "Wire the directive engine into the session lifecycle"
```

- [ ] **Step 6: Hand off the Xcode link**

State clearly in the final report: **`DirectiveEngine` must be added to the Replicould app target's linked libraries in Xcode** (General ▸ Frameworks, Libraries, and Embedded Content ▸ +) before the app will build. Until then `swift build` / `swift test` are green but the `.xcodeproj` is not. See `app/.claude/memory/pbxproj-link-is-manual.md`.

---

## Self-review

**Spec coverage.** §6 governor → Task 6. §6 engine (serial executor per custom directive, observes reconciled state, lifecycle with sync engine, executors cancelled before wipes) → Tasks 7, 8, 10. §6 `directive.*` route writing a log entry under the event-time guard → Task 9. §5 issue-time-relative guard → Task 9 (the mission-attribution half; the completion-detection half that *advances* a Survey Run is Stage 4 by staging). §8 stall semantics (`needsAttention` + typed reason, no auto-retry) → Task 8. §2 `DirectiveLogEntry` as the audit trail → Tasks 8, 9. §10 staging boundary honoured: no Survey Run, no Relay Run, no FTL-mesh incremental add (Stage 5), no new-directive creation flow (§9 out of scope).

**Deliberately out of this stage, and why:** the `.opCompleted` log kind is unwritten until Stage 4 gives the engine an op to watch; `MissionRegistry` ships empty, so `DirectiveEngine.makeLive()` takes machines as a parameter that Stage 4 fills; `firstStep` is on the protocol rather than the `Directive` row because each kind owns its own step vocabulary (the `step: String` comment in `Directive` says exactly this — do not "fix" it to an enum).

**Known risk to watch during execution:** the exact SQLiteData query spellings (`Directive.find(_:)`, `.fetchCount(db)`, `$0.status.eq(DirectiveStatus.running)` against a `QueryBindable` enum) are written from the patterns in `Reconciler.swift`, `PollAndDeadlineTests.swift` and `Directive.swift`. If any doesn't compile, match the shape used in `Reconciler.completeOpenOperation` rather than inventing one, and note the correction in the task's commit.
