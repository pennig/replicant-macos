# Device List Organisation — Stage 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganise the 104-device fleet master list into a collapsible containment tree with a Needs Attention pin and a search field, dropping the top level from 104 rows to ~70 and making any device findable in a few keystrokes.

**Architecture:** All organisation logic lives in a new `DeviceListLayout` enum namespace inside `DevicesFeature` — pure, SwiftUI-free, unit-tested directly. It takes the observed fleet plus the `needsAttention` directives and returns `[DeviceListSection]`, each holding an already-flattened `[DeviceEntry]` with `depth` as a rendering hint. `DevicesFeature.State` exposes the result as a derived property; `DevicesListView` becomes a pure renderer over it, driving the existing `SelectableList` through its custom-content initialiser.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), Composable Architecture, SQLiteData (`@FetchAll`), Swift Testing + CustomDump.

**Source spec:** `app/docs/superpowers/specs/2026-08-05-device-list-organisation-design.md`. This plan covers **Stage 1 only** (Carrier mode, search, attention, row changes). Stage 2 (the grouping picker, Type/System/Mission/Flat, readout headers on every section, `@Shared` persistence) is a separate plan.

---

## Global Constraints

- **Never hard-code colours, spacing, or font sizes.** Use `DesignSystem.swift` tokens (`.rcTextPrimary`, `Space.m`, `Radius.card`, `Font.rcBodyEmph`, `IconSize.s`, `Hairline.regular`, …). If a token is missing, add it to `DesignSystem.swift` rather than inlining a value.
- **No new colours.** Section status bars colour through the existing `DeviceStatus.tone(for:)` → `StatusTone.color` taxonomy only.
- **Any system or location designation renders monospaced** (`.rcMono`, `.rcMonoSmall`, `.rcMicroMono`, `.rcBodyEmphMono`). Device codes follow the same convention in this list, matching the existing row.
- **List-row structs live in their own file, never beside a `#Preview`** — the Xcode 26 preview JIT crashes otherwise. This plan extracts `DeviceRow` into `DeviceRow.swift` for that reason; do not add a `#Preview` to that file.
- **Pure logic must NOT be a static or nested type on a SwiftUI `View`** — it traps with signal 5 under `swift test` (see `.claude/memory/swiftui-view-statics-trap-in-tests.md`). `DeviceListLayout` is a plain `enum` namespace in a file with **no `import SwiftUI`**.
- **Sections of flat entries, not a nested tree.** Nothing recurses in the view; `DisclosureGroup`/`children:` produced a metadata and ARC storm at scale in the Locations catalog (`.claude/memory/locations-list-flatten-perf.md`).
- **`os.Logger` only, never `print`.** Subsystem `name.pennig.replicould`, category `Devices`. Stage 1 adds no new logging.
- **Nothing about selection, the inspector, or command dispatch changes.** `State.selectedDevice` already resolves against the full `devices` array, so a filtered-out selection keeps its detail pane. Do not touch it.
- **Running tests:** the package has many test targets and the `swiftbuild` backend truncates a shared event-stream file down to the last product. Always scope with `--test-product DevicesFeatureTests`. See the `swift-test-event-stream` skill. The canonical invocation used throughout this plan:

  ```bash
  cd app/Modules && swift test \
    --test-product DevicesFeatureTests \
    --disable-xctest \
    --filter '<TestSuiteTypeName>' \
    --event-stream-version 0 \
    --event-stream-output-path .build/events.jsonl
  ```

  Read results from `.build/events.jsonl`, never from console text. `--filter` matches the suite's **Swift type name**, not its `@Suite("display name")`.
- **LSP setup, once per worktree, before any code work:** `cd app/Modules && swift build --build-tests` then `./scripts/link-index-store.sh`. Without the symlink every reference query silently returns zero.
- **Commits go to local `main` or a worktree branch merged to `main`.** No PRs, no pushes to `origin`.

### One deliberate deviation from the spec

The spec declares `case directive(DirectiveAttentionReason)`. `Directive.attentionReason` is **nullable** (`DirectiveAttentionReason?`), so a directive can sit in `needsAttention` with no reason recorded. This plan uses `case directive(DirectiveAttentionReason?)` and renders a nil reason as `"Directive needs attention"`. Dropping the flag instead would hide a genuinely-flagged device.

---

## File Structure

**Created — `DevicesFeature/Sources/`**

| File | Responsibility |
| --- | --- |
| `DeviceListModel.swift` | The output value types only: `DeviceListSection`, `DeviceListHeader`, `StatusShare`, `DeviceEntry`, `HostRelation`, `AttentionFlag`. No logic beyond display labels and symbol names. |
| `DeviceListSearch.swift` | `DeviceListLayout.Query`, the per-device haystack, `matches(_:query:)`, and forest pruning with forced-open ancestors. |
| `DeviceListAttention.swift` | `DeviceListLayout.attentionFlags(for:directives:)`, the directive join, the damaged threshold constant, and the Needs Attention sort order. |
| `DeviceListLayout.swift` | The namespace declaration, the internal `Node` tree, `forest(fleet:)`, `flatten(...)`, `promote(...)`, and the `sections(...)` entry point. **No `import SwiftUI`.** |
| `DeviceRow.swift` | The list row, extracted from `DevicesView.swift` and extended (indent, disclosure, attention dot, host badge, tag chip). No `#Preview` in this file. |

**Created — `UI/Sources/`**

| File | Responsibility |
| --- | --- |
| `RCReadoutSectionHeader.swift` | A domain-free collapsible section header: chevron, title, count, warning marker, and a stacked share bar. Takes pre-coloured `Share` values so `UI` stays free of device vocabulary. |

**Modified**

| File | Change |
| --- | --- |
| `DevicesFeature/Sources/DevicesFeature.swift` | `State` gains `attentionDirectives`, `searchText`, `expandedHosts`, `collapsedGroups`, and the derived `sections` / `matchCount`. `Action` gains `hostDisclosureToggled` / `groupDisclosureToggled`; the reducer handles both. |
| `DevicesFeature/Sources/DevicesView.swift` | Rewritten onto `SelectableList`'s custom-content initialiser with pinned section headers, `.searchable`, the "N of M devices" subtitle, and the search empty state. The private `DeviceRow` struct moves out. |

**Tests — `DevicesFeature/Tests/`**

`DeviceListFixtures.swift` (shared builders), `DeviceListSearchTests.swift`, `DeviceListAttentionTests.swift`, `DeviceListContainmentTests.swift`, `DeviceListCollapseTests.swift`, `DeviceListSectionsTests.swift`, plus new cases appended to `DevicesFeatureTests.swift`.

`Package.swift` needs **no change**: `DevicesFeature` already links `GameModels` (where `Directive` lives), `UI`, and `SQLiteData`; `DevicesFeatureTests` already links `CustomDump`, `GameDatabase`, and `GameModels`.

---

## Task 1: Search matching

**Files:**
- Create: `app/Modules/DevicesFeature/Sources/DeviceListLayout.swift`
- Create: `app/Modules/DevicesFeature/Sources/DeviceListSearch.swift`
- Create: `app/Modules/DevicesFeature/Tests/DeviceListFixtures.swift`
- Test: `app/Modules/DevicesFeature/Tests/DeviceListSearchTests.swift`

**Interfaces:**
- Consumes: `GameModels.Device`, `DevicesFeature.DevicePresentation.displayName(_:)`.
- Produces:
  - `enum DeviceListLayout` (the namespace every later task extends)
  - `DeviceListLayout.Query.init(_ text: String)`, `.isEmpty: Bool`
  - `DeviceListLayout.matches(_ device: Device, query: Query) -> Bool`
  - Test helper `makeDevice(...) -> Device` used by every later test file.

- [ ] **Step 1: Write the shared test fixture builder**

Create `app/Modules/DevicesFeature/Tests/DeviceListFixtures.swift`:

```swift
//
//  DeviceListFixtures.swift
//  Replicould — Devices feature tests
//
//  Shared builders for the `DeviceListLayout` suites. Named `makeDevice` (not
//  `device`) so it can't collide with the file-private `device(_:status:)` in
//  `DevicesFeatureTests.swift`.
//

import Foundation
import GameModels
import Utils

func makeDevice(
    _ code: String,
    type: String = "survey_drone",
    status: String = "idle",
    location: String? = nil,
    locationName: String? = nil,
    capacity: Double = 100,
    tags: [String] = [],
    stowedIn: String? = nil,
    controlledBy: String? = nil,
    attachedTo: String? = nil,
    detail: JSONValue = .object([:])
) -> Device {
    Device(
        deviceCode: code,
        deviceType: type,
        replicantCode: "R1",
        status: status,
        location: location,
        locationName: locationName,
        operationalCapacity: capacity,
        queueSize: 0,
        stowedInDeviceCode: stowedIn,
        controllerDeviceCode: controlledBy,
        attachedToDeviceCode: attachedTo,
        createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [],
        features: [],
        tags: tags,
        detail: detail,
        updatedAt: Date(timeIntervalSince1970: 1_000),
        firstSeenAt: Date(timeIntervalSince1970: 1_000)
    )
}

func makeDirective(
    id: String = "D1",
    kind: DirectiveKind = .surveyRun,
    status: DirectiveStatus = .needsAttention,
    deviceCode: String,
    controllerCode: String? = nil,
    fleetTag: String? = nil,
    reason: DirectiveAttentionReason? = .commandRejected
) -> Directive {
    Directive(
        id: id,
        kind: kind,
        status: status,
        deviceCode: deviceCode,
        controllerCode: controllerCode,
        roamCentre: nil,
        fleetTag: fleetTag,
        sourceRelayCode: nil,
        targets: [],
        targetIndex: 0,
        step: "idle",
        stepStartedAt: Date(timeIntervalSince1970: 0),
        returnToOrigin: false,
        originDesignation: nil,
        attentionReason: reason,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}
```

> If `Directive`'s memberwise initialiser argument list has drifted from the
> above, open `app/Modules/GameModels/Sources/Directive.swift` and match it
> exactly — do not guess. The only fields this plan's tests care about are
> `status`, `deviceCode`, `controllerCode`, `fleetTag`, and `attentionReason`.

- [ ] **Step 2: Write the failing search test**

Create `app/Modules/DevicesFeature/Tests/DeviceListSearchTests.swift`:

```swift
//
//  DeviceListSearchTests.swift
//  Replicould — Devices feature tests
//
//  `DeviceListLayout` search: AND across whitespace-split terms, OR across the
//  per-device haystack fields, case- and diacritic-insensitive.
//

import Foundation
import GameModels
import Testing
@testable import DevicesFeature

@Suite struct DeviceListSearchTests {

    @Test func emptyQueryMatchesEverything() {
        let query = DeviceListLayout.Query("   ")
        #expect(query.isEmpty)
        #expect(DeviceListLayout.matches(makeDevice("A1B2C3D4"), query: query))
    }

    @Test func matchesOnDeviceCode() {
        let device = makeDevice("A1B2C3D4")
        #expect(DeviceListLayout.matches(device, query: .init("b2c3")))
        #expect(!DeviceListLayout.matches(device, query: .init("zzzz")))
    }

    @Test func matchesOnDisplayNameAndRawType() {
        // "survey_drone" displays as "Survey Drone", so both the display name
        // and the raw type are in the haystack and both are reachable.
        let device = makeDevice("A1B2C3D4", type: "survey_drone")
        #expect(DeviceListLayout.matches(device, query: .init("Survey Drone")))
        #expect(DeviceListLayout.matches(device, query: .init("survey")))
        #expect(DeviceListLayout.matches(device, query: .init("survey_drone")))
    }

    @Test func matchesOnLocationAndLocationName() {
        let device = makeDevice("A1B2C3D4", location: "ATIANFU-1-L4", locationName: "Atianfu Prime")
        #expect(DeviceListLayout.matches(device, query: .init("atianfu-1")))
        #expect(DeviceListLayout.matches(device, query: .init("prime")))
    }

    @Test func matchesOnTagsAndStatusBase() {
        let device = makeDevice("A1B2C3D4", status: "mining (iron)", tags: ["auto:survey"])
        #expect(DeviceListLayout.matches(device, query: .init("auto:survey")))
        #expect(DeviceListLayout.matches(device, query: .init("mining")))
        // The status *parameter* is not part of the haystack — `statusBase` is.
        #expect(!DeviceListLayout.matches(device, query: .init("iron")))
    }

    @Test func everyTermMustMatchSomeField() {
        let device = makeDevice("A1B2C3D4", type: "survey_drone", location: "ATIANFU-1-L4")
        #expect(DeviceListLayout.matches(device, query: .init("survey ATIANFU")))
        #expect(!DeviceListLayout.matches(device, query: .init("survey POLARISUM")))
    }

    @Test func caseAndDiacriticInsensitive() {
        let device = makeDevice("A1B2C3D4", locationName: "Ésellusau")
        #expect(DeviceListLayout.matches(device, query: .init("esellusau")))
        #expect(DeviceListLayout.matches(device, query: .init("ÉSELLUSAU")))
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListSearchTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: compile failure — `cannot find 'DeviceListLayout' in scope`.

- [ ] **Step 4: Create the namespace**

Create `app/Modules/DevicesFeature/Sources/DeviceListLayout.swift`:

```swift
//
//  DeviceListLayout.swift
//  Replicould — Devices feature
//
//  How the fleet master list is organised. A pure, SwiftUI-free namespace: the
//  whole of search, containment, collapse, and attention promotion is plain
//  functions over values, so it is unit-tested directly rather than through the
//  view. Deliberately NOT a static on `DevicesListView` — pure logic hung off a
//  SwiftUI `View` traps with signal 5 under `swift test`
//  (.claude/memory/swiftui-view-statics-trap-in-tests.md).
//
//  DO NOT `import SwiftUI` in this file.
//

import Foundation
import GameModels

public enum DeviceListLayout {

    /// Rows deeper than this share the deepest indent. The containment tree is
    /// genuinely two levels (Vessel → AMI controller → drones); anything below
    /// that is a data surprise and should not run the row off the edge.
    static let maxIndentDepth = 2
}
```

- [ ] **Step 5: Implement search**

Create `app/Modules/DevicesFeature/Sources/DeviceListSearch.swift`:

```swift
//
//  DeviceListSearch.swift
//  Replicould — Devices feature
//
//  The list's search: AND across whitespace-split terms, OR across each device's
//  haystack fields, case- and diacritic-insensitive. Folding happens once per
//  term at parse time and once per field at match time.
//

import Foundation
import GameModels

extension DeviceListLayout {

    /// A parsed search query. Empty (no non-whitespace terms) matches everything.
    public struct Query: Equatable, Sendable {
        let terms: [String]

        public init(_ text: String) {
            terms = text
                .split(whereSeparator: \.isWhitespace)
                .map { Self.fold(String($0)) }
                .filter { !$0.isEmpty }
        }

        public var isEmpty: Bool { terms.isEmpty }

        /// Case- and diacritic-insensitive normalisation. `locale: nil` keeps the
        /// fold locale-independent so tests don't depend on the host locale.
        static func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
    }

    /// Every field a query term may match, folded.
    static func haystack(for device: Device) -> [String] {
        var fields = [
            device.deviceCode,
            DevicePresentation.displayName(device.deviceType),
            device.deviceType,
            device.statusBase,
        ]
        if let location = device.location { fields.append(location) }
        if let locationName = device.locationName { fields.append(locationName) }
        fields.append(contentsOf: device.tags)
        return fields.map(Query.fold)
    }

    /// Every term must match some field; a term matches a field on substring.
    public static func matches(_ device: Device, query: Query) -> Bool {
        guard !query.isEmpty else { return true }
        let fields = haystack(for: device)
        return query.terms.allSatisfy { term in
            fields.contains { $0.contains(term) }
        }
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListSearchTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Verify via the event stream (7 tests started, 0 failing issues, `runEnded` present):

```bash
jq -s 'map(select(.kind=="event").payload) as $e
  | { started: ($e|map(select(.kind=="testStarted"))|length),
      failed:  ($e|map(select(.kind=="issueRecorded" and .issue.isFailure != false).testID)|unique|length),
      ended:   ($e|map(select(.kind=="runEnded"))|length) }' .build/events.jsonl
```

Expected: `started` > 0, `failed` 0, `ended` 1.

- [ ] **Step 7: Commit**

```bash
git add app/Modules/DevicesFeature/Sources/DeviceListLayout.swift \
        app/Modules/DevicesFeature/Sources/DeviceListSearch.swift \
        app/Modules/DevicesFeature/Tests/DeviceListFixtures.swift \
        app/Modules/DevicesFeature/Tests/DeviceListSearchTests.swift
git commit -m "feat(devices): DeviceListLayout search over the per-device haystack"
```

---

## Task 2: Attention flags and ordering

**Files:**
- Create: `app/Modules/DevicesFeature/Sources/DeviceListModel.swift`
- Create: `app/Modules/DevicesFeature/Sources/DeviceListAttention.swift`
- Test: `app/Modules/DevicesFeature/Tests/DeviceListAttentionTests.swift`

**Interfaces:**
- Consumes: `makeDevice`, `makeDirective` (Task 1), `GameModels.Directive`, `Device.isOutOfControlRange`.
- Produces:
  - `public enum AttentionFlag: Equatable, Sendable` with `.damaged(capacity:)`, `.outOfControlRange`, `.directive(DirectiveAttentionReason?)` and `var label: String`
  - `DeviceListLayout.damagedCapacityThreshold: Double`
  - `DeviceListLayout.attentionFlags(for: Device, directives: [Directive]) -> [AttentionFlag]`
  - `DeviceListLayout.attentionRank(_ flags: [AttentionFlag]) -> Int`
  - `DeviceListLayout.attentionPrecedes(_ a: Device, _ b: Device, attention: [String: [AttentionFlag]]) -> Bool`

- [ ] **Step 1: Write the failing attention test**

Create `app/Modules/DevicesFeature/Tests/DeviceListAttentionTests.swift`:

```swift
//
//  DeviceListAttentionTests.swift
//  Replicould — Devices feature tests
//
//  The three Needs Attention predicates, the three directive join paths, and
//  the section's own sort order.
//

import CustomDump
import Foundation
import GameModels
import Testing
import Utils
@testable import DevicesFeature

@Suite struct DeviceListAttentionTests {

    @Test func damagedBelowThresholdOnly() {
        let hurt = makeDevice("A1", capacity: 42)
        let fine = makeDevice("A2", capacity: 60)
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: hurt, directives: []),
            [.damaged(capacity: 42)]
        )
        expectNoDifference(DeviceListLayout.attentionFlags(for: fine, directives: []), [])
    }

    @Test func thresholdIsExclusive() {
        let edge = makeDevice("A1", capacity: DeviceListLayout.damagedCapacityThreshold)
        expectNoDifference(DeviceListLayout.attentionFlags(for: edge, directives: []), [])
    }

    @Test func outOfControlRangeFlags() {
        let cut = makeDevice("A1", detail: .object(["in_control_range": .bool(false)]))
        let ok = makeDevice("A2", detail: .object(["in_control_range": .bool(true)]))
        let unknown = makeDevice("A3")
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: cut, directives: []),
            [.outOfControlRange]
        )
        expectNoDifference(DeviceListLayout.attentionFlags(for: ok, directives: []), [])
        expectNoDifference(DeviceListLayout.attentionFlags(for: unknown, directives: []), [])
    }

    @Test func directiveJoinsOnDeviceCode() {
        let device = makeDevice("A1")
        let directive = makeDirective(deviceCode: "A1", reason: .commandRejected)
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: device, directives: [directive]),
            [.directive(.commandRejected)]
        )
    }

    @Test func directiveJoinsOnControllerCode() {
        let device = makeDevice("CTRL1")
        let directive = makeDirective(deviceCode: "VESSEL1", controllerCode: "CTRL1", reason: .noSurveyDroneAboard)
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: device, directives: [directive]),
            [.directive(.noSurveyDroneAboard)]
        )
    }

    @Test func directiveJoinsOnFleetTag() {
        let device = makeDevice("A1", tags: ["auto:haul"])
        let directive = makeDirective(deviceCode: "OTHER", fleetTag: "auto:haul", reason: .noHaulControllerTagged)
        let untagged = makeDevice("A2")
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: device, directives: [directive]),
            [.directive(.noHaulControllerTagged)]
        )
        expectNoDifference(DeviceListLayout.attentionFlags(for: untagged, directives: [directive]), [])
    }

    @Test func directiveWithNoRecordedReasonStillFlags() {
        let device = makeDevice("A1")
        let directive = makeDirective(deviceCode: "A1", reason: nil)
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: device, directives: [directive]),
            [.directive(nil)]
        )
        #expect(AttentionFlag.directive(nil).label == "Directive needs attention")
    }

    @Test func flagsAccumulate() {
        let device = makeDevice("A1", capacity: 10, detail: .object(["in_control_range": .bool(false)]))
        let directive = makeDirective(deviceCode: "A1", reason: .commandRejected)
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: device, directives: [directive]),
            [.outOfControlRange, .damaged(capacity: 10), .directive(.commandRejected)]
        )
    }

    /// Out-of-control-range first, then damaged ascending by capacity, then
    /// directive-flagged, then device code.
    @Test func sectionOrdering() {
        let cut = makeDevice("Z9", detail: .object(["in_control_range": .bool(false)]))
        let badlyHurt = makeDevice("M5", capacity: 10)
        let hurt = makeDevice("B2", capacity: 40)
        let flagged = makeDevice("A1")
        let alsoFlagged = makeDevice("A0")
        let directives = [
            makeDirective(id: "D1", deviceCode: "A1"),
            makeDirective(id: "D2", deviceCode: "A0"),
        ]
        let fleet = [flagged, hurt, cut, badlyHurt, alsoFlagged]
        let attention = Dictionary(
            uniqueKeysWithValues: fleet.map {
                ($0.deviceCode, DeviceListLayout.attentionFlags(for: $0, directives: directives))
            }
        )
        let ordered = fleet
            .sorted { DeviceListLayout.attentionPrecedes($0, $1, attention: attention) }
            .map(\.deviceCode)
        expectNoDifference(ordered, ["Z9", "M5", "B2", "A0", "A1"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListAttentionTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: compile failure — `cannot find 'AttentionFlag' in scope`.

- [ ] **Step 3: Declare the attention flag in the model file**

Create `app/Modules/DevicesFeature/Sources/DeviceListModel.swift`. Only the
attention type is needed now; Task 3 appends the rest to this file.

```swift
//
//  DeviceListModel.swift
//  Replicould — Devices feature
//
//  The value types `DeviceListLayout` returns. Pure data plus display labels;
//  no SwiftUI, no logic. The view renders these and nothing else.
//

import Foundation
import GameModels

/// Why a device is in the Needs Attention section. A device can carry several.
public enum AttentionFlag: Equatable, Sendable {
    /// Operational capacity below `DeviceListLayout.damagedCapacityThreshold`.
    case damaged(capacity: Double)
    /// `detail.in_control_range == false` — cut off from its AMI controller.
    case outOfControlRange
    /// A directive in `needsAttention` covers this device. The reason is
    /// optional because `Directive.attentionReason` is nullable: a directive can
    /// be flagged without a recorded reason, and the device still needs a look.
    case directive(DirectiveAttentionReason?)

    /// The short label the row shows. The directive case reuses the existing
    /// `DirectiveAttentionReason` display text rather than inventing new copy.
    public var label: String {
        switch self {
        case let .damaged(capacity):
            "Damaged · \(Int(capacity.rounded()))%"
        case .outOfControlRange:
            "Out of control range"
        case let .directive(reason):
            reason?.displayName ?? "Directive needs attention"
        }
    }
}
```

- [ ] **Step 4: Implement the attention predicates and ordering**

Create `app/Modules/DevicesFeature/Sources/DeviceListAttention.swift`:

```swift
//
//  DeviceListAttention.swift
//  Replicould — Devices feature
//
//  Which devices need the operator right now, and in what order they read.
//

import Foundation
import GameModels

extension DeviceListLayout {

    /// Below this operational capacity a device reads as damaged. 50 flags 3
    /// devices on the 2026-08-05 fleet; 100 would flag 17 and be noise.
    public static let damagedCapacityThreshold: Double = 50

    /// Every reason `device` needs attention, in display order.
    ///
    /// `directives` must already be filtered to `DirectiveStatus.needsAttention`
    /// — the caller's `@FetchAll` does that in SQL, and this function does not
    /// re-check, so passing unfiltered directives over-flags.
    public static func attentionFlags(
        for device: Device,
        directives: [Directive]
    ) -> [AttentionFlag] {
        var flags: [AttentionFlag] = []
        if device.isOutOfControlRange {
            flags.append(.outOfControlRange)
        }
        if device.operationalCapacity < damagedCapacityThreshold {
            flags.append(.damaged(capacity: device.operationalCapacity))
        }
        for directive in directives where covers(directive, device) {
            flags.append(.directive(directive.attentionReason))
        }
        return flags
    }

    /// The three join paths from a flagged directive to a device.
    static func covers(_ directive: Directive, _ device: Device) -> Bool {
        if directive.deviceCode == device.deviceCode { return true }
        if directive.controllerCode == device.deviceCode { return true }
        if let tag = directive.fleetTag, device.tags.contains(tag) { return true }
        return false
    }

    /// The Needs Attention section's own order: out-of-control-range (0),
    /// damaged (1), directive-flagged (2).
    static func attentionRank(_ flags: [AttentionFlag]) -> Int {
        if flags.contains(.outOfControlRange) { return 0 }
        if flags.contains(where: { if case .damaged = $0 { true } else { false } }) { return 1 }
        return 2
    }

    /// Out-of-control-range first, then damaged ascending by capacity (the worst
    /// device leads), then directive-flagged, then device code.
    static func attentionPrecedes(
        _ a: Device,
        _ b: Device,
        attention: [String: [AttentionFlag]]
    ) -> Bool {
        let rankA = attentionRank(attention[a.deviceCode] ?? [])
        let rankB = attentionRank(attention[b.deviceCode] ?? [])
        if rankA != rankB { return rankA < rankB }
        if rankA == 1, a.operationalCapacity != b.operationalCapacity {
            return a.operationalCapacity < b.operationalCapacity
        }
        return a.deviceCode < b.deviceCode
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListAttentionTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: 10 tests, 0 failures, `runEnded` present.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DevicesFeature/Sources/DeviceListModel.swift \
        app/Modules/DevicesFeature/Sources/DeviceListAttention.swift \
        app/Modules/DevicesFeature/Tests/DeviceListAttentionTests.swift
git commit -m "feat(devices): the three Needs Attention predicates and their order"
```

---

## Task 3: The containment forest

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/DeviceListModel.swift` (append `HostRelation`)
- Modify: `app/Modules/DevicesFeature/Sources/DeviceListLayout.swift` (append `Node`, `forest`, host resolution)
- Test: `app/Modules/DevicesFeature/Tests/DeviceListContainmentTests.swift`

**Interfaces:**
- Consumes: `makeDevice` (Task 1), `DeviceListLayout` (Task 1).
- Produces:
  - `public enum HostRelation: Equatable, Sendable` with `.controlled(by:)`, `.stowed(in:)`, `.attached(to:)`, `var hostCode: String`, `var symbol: String`, `var label: String`
  - `DeviceListLayout.Node` (internal): `var device: Device`, `var children: [Node]`
  - `DeviceListLayout.forest(fleet: [Device]) -> [Node]`
  - `DeviceListLayout.hostRelations(of:) -> [HostRelation]`, `.hostCode(of:) -> String?`, `.badge(for:parentCode:) -> HostRelation?`

- [ ] **Step 1: Write the failing containment test**

Create `app/Modules/DevicesFeature/Tests/DeviceListContainmentTests.swift`:

```swift
//
//  DeviceListContainmentTests.swift
//  Replicould — Devices feature tests
//
//  Carrier mode's tree: controller-first precedence, the real two-level shape,
//  unresolved hosts, cycles, and sort order.
//

import CustomDump
import Foundation
import GameModels
import Testing
@testable import DevicesFeature

@Suite struct DeviceListContainmentTests {

    /// Flattens a forest to `code(depth)` strings for readable assertions.
    private func shape(_ nodes: [DeviceListLayout.Node], depth: Int = 0) -> [String] {
        nodes.flatMap { node in
            ["\(node.device.deviceCode)(\(depth))"] + shape(node.children, depth: depth + 1)
        }
    }

    /// In all 10 live stowed-and-controlled cases the AMI controller is stowed
    /// in the very carrier its drones are stowed in. Controller-first renders
    /// Vessel → Controller → drones; stowed-first would render seven siblings.
    @Test func controllerBeatsStowed() {
        let vessel = makeDevice("VESSEL", type: "heaven_vessel")
        let controller = makeDevice("CTRL", type: "ami_survey_controller", stowedIn: "VESSEL")
        let droneA = makeDevice("DRONEA", stowedIn: "VESSEL", controlledBy: "CTRL")
        let droneB = makeDevice("DRONEB", stowedIn: "VESSEL", controlledBy: "CTRL")

        let forest = DeviceListLayout.forest(fleet: [droneB, vessel, droneA, controller])
        expectNoDifference(
            shape(forest),
            ["VESSEL(0)", "CTRL(1)", "DRONEA(2)", "DRONEB(2)"]
        )
    }

    @Test func attachedIsLowestPrecedence() {
        let plate = makeDevice("PLATE", type: "surge_plate")
        let beacon = makeDevice("BEACON", type: "ftl_beacon", attachedTo: "PLATE")
        let forest = DeviceListLayout.forest(fleet: [beacon, plate])
        expectNoDifference(shape(forest), ["PLATE(0)", "BEACON(1)"])
    }

    /// The non-winning relationship survives as the row's badge.
    @Test func nonWinningRelationBecomesTheBadge() {
        let drone = makeDevice("DRONEA", stowedIn: "VESSEL", controlledBy: "CTRL")
        expectNoDifference(
            DeviceListLayout.badge(for: drone, parentCode: "CTRL"),
            .stowed(in: "VESSEL")
        )
    }

    /// A promoted (top-level) device still badges its declared relation, so an
    /// unresolved host stays visible on the row.
    @Test func promotedDeviceBadgesItsFirstRelation() {
        let orphan = makeDevice("ORPHAN", controlledBy: "GONE")
        expectNoDifference(
            DeviceListLayout.badge(for: orphan, parentCode: nil),
            .controlled(by: "GONE")
        )
    }

    @Test func unresolvedHostPromotesToTopLevel() {
        let orphan = makeDevice("ORPHAN", stowedIn: "NOTINFLEET")
        let other = makeDevice("OTHER")
        let forest = DeviceListLayout.forest(fleet: [orphan, other])
        expectNoDifference(shape(forest), ["ORPHAN(0)", "OTHER(0)"])
    }

    @Test func selfHostPromotesToTopLevel() {
        let looped = makeDevice("SELF", stowedIn: "SELF")
        expectNoDifference(shape(DeviceListLayout.forest(fleet: [looped])), ["SELF(0)"])
    }

    /// A cycle terminates and places every member exactly once, at top level.
    @Test func cycleDissolvesToRoots() {
        let a = makeDevice("AAAA", stowedIn: "BBBB")
        let b = makeDevice("BBBB", stowedIn: "CCCC")
        let c = makeDevice("CCCC", stowedIn: "AAAA")
        let forest = DeviceListLayout.forest(fleet: [a, b, c])
        expectNoDifference(shape(forest), ["AAAA(0)", "BBBB(0)", "CCCC(0)"])
    }

    /// A device dangling off a cycle is not itself in the cycle and must still
    /// nest, and every device is placed exactly once.
    @Test func everyDeviceIsPlacedExactlyOnce() {
        let a = makeDevice("AAAA", stowedIn: "BBBB")
        let b = makeDevice("BBBB", stowedIn: "AAAA")
        let hanger = makeDevice("HANG", stowedIn: "AAAA")
        let loose = makeDevice("LOOS")
        let forest = DeviceListLayout.forest(fleet: [a, b, hanger, loose])
        let placed = shape(forest).map { String($0.prefix(while: { $0 != "(" })) }
        expectNoDifference(placed.sorted(), ["AAAA", "BBBB", "HANG", "LOOS"])
        expectNoDifference(Set(placed).count, placed.count)
    }

    /// Sort within a level: type display name, then device code.
    /// "ftl_relay" displays as "FTL Relay" and "survey_drone" as "Survey Drone",
    /// so the two relays lead, ordered by code.
    @Test func sortsByTypeDisplayNameThenCode() {
        let forest = DeviceListLayout.forest(fleet: [
            makeDevice("ZZZZ", type: "ftl_relay"),
            makeDevice("AAAA", type: "survey_drone"),
            makeDevice("BBBB", type: "ftl_relay"),
        ])
        expectNoDifference(shape(forest), ["BBBB(0)", "ZZZZ(0)", "AAAA(0)"])
    }
}
```

`DevicePresentation.displayName` delegates to
`GameModels.BlueprintPresentation.displayName`, which title-cases the
underscore-separated tokens with `heaven`/`ftl`/`ami` fixed as all-caps —
`"ftl_relay"` → `"FTL Relay"`, `"survey_drone"` → `"Survey Drone"`,
`"ami_survey_controller"` → `"AMI Survey Controller"`,
`"heaven_vessel"` → `"HEAVEN Vessel"`. Every sort expectation in this plan is
derived from those strings.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListContainmentTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: compile failure — `type 'DeviceListLayout' has no member 'forest'`.

- [ ] **Step 3: Append `HostRelation` to the model file**

Append to `app/Modules/DevicesFeature/Sources/DeviceListModel.swift`:

```swift
/// How a device relates to its host device. The row badges the relationship
/// that did *not* determine its position in the tree, so nothing is lost.
public enum HostRelation: Equatable, Sendable {
    case controlled(by: String)
    case stowed(in: String)
    case attached(to: String)

    public var hostCode: String {
        switch self {
        case let .controlled(code), let .stowed(code), let .attached(code): code
        }
    }

    /// SF Symbol for the badge glyph.
    public var symbol: String {
        switch self {
        case .controlled: "dot.radiowaves.left.and.right"
        case .stowed:     "shippingbox"
        case .attached:   "paperclip"
        }
    }

    public var label: String {
        switch self {
        case let .controlled(code): "Controlled by \(code)"
        case let .stowed(code):     "Stowed in \(code)"
        case let .attached(code):   "Attached to \(code)"
        }
    }
}
```

- [ ] **Step 4: Implement the forest**

Append to `app/Modules/DevicesFeature/Sources/DeviceListLayout.swift`:

```swift
extension DeviceListLayout {

    /// One node of the containment forest, before flattening. Internal: the view
    /// never sees a tree, only `[DeviceEntry]`.
    struct Node: Equatable {
        var device: Device
        var children: [Node]
    }

    /// Every host relationship this device declares, in precedence order:
    /// controller → stowed → attached.
    static func hostRelations(of device: Device) -> [HostRelation] {
        var relations: [HostRelation] = []
        if let code = device.controllerDeviceCode { relations.append(.controlled(by: code)) }
        if let code = device.stowedInDeviceCode { relations.append(.stowed(in: code)) }
        if let code = device.attachedToDeviceCode { relations.append(.attached(to: code)) }
        return relations
    }

    /// The host this device nests under — the highest-precedence relation it
    /// declares, resolved or not.
    static func hostCode(of device: Device) -> String? {
        hostRelations(of: device).first?.hostCode
    }

    /// The badge relationship: the first declared relation that isn't the one
    /// the row actually nests under. A top-level device (`parentCode == nil`)
    /// badges its first relation, so an unresolved host stays visible.
    static func badge(for device: Device, parentCode: String?) -> HostRelation? {
        hostRelations(of: device).first { $0.hostCode != parentCode }
    }

    /// Walks `code` up its declared host chain and reports whether the walk
    /// re-enters a code it has already seen. Every member of a cycle answers
    /// true, so a cycle dissolves entirely into roots — each of its devices is
    /// placed exactly once and the walk provably terminates (the seen set grows
    /// on every step over a finite fleet).
    static func closesCycle(_ code: String, in byCode: [String: Device]) -> Bool {
        var seen: Set<String> = [code]
        var current = code
        while let device = byCode[current], let next = hostCode(of: device) {
            if seen.contains(next) { return true }
            seen.insert(next)
            current = next
        }
        return false
    }

    /// Sort within a level: type display name, then device code.
    static func precedes(_ a: Device, _ b: Device) -> Bool {
        let nameA = DevicePresentation.displayName(a.deviceType)
        let nameB = DevicePresentation.displayName(b.deviceType)
        if nameA != nameB { return nameA < nameB }
        return a.deviceCode < b.deviceCode
    }

    /// Builds the containment forest. A device whose declared host is absent from
    /// the fleet, is itself, or would close a cycle is promoted to top level —
    /// the fleet syncs incrementally, so a dangling reference is cheap to guard
    /// and expensive to hit.
    static func forest(fleet: [Device]) -> [Node] {
        let byCode = Dictionary(fleet.map { ($0.deviceCode, $0) }, uniquingKeysWith: { first, _ in first })

        var childCodes: [String: [String]] = [:]
        var roots: [Device] = []
        for device in fleet {
            guard let host = hostCode(of: device),
                  host != device.deviceCode,
                  byCode[host] != nil,
                  !closesCycle(device.deviceCode, in: byCode)
            else {
                roots.append(device)
                continue
            }
            childCodes[host, default: []].append(device.deviceCode)
        }

        func node(for device: Device) -> Node {
            Node(
                device: device,
                children: (childCodes[device.deviceCode] ?? [])
                    .compactMap { byCode[$0] }
                    .sorted(by: precedes)
                    .map(node(for:))
            )
        }

        return roots.sorted(by: precedes).map(node(for:))
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListContainmentTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: 9 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DevicesFeature/Sources/DeviceListModel.swift \
        app/Modules/DevicesFeature/Sources/DeviceListLayout.swift \
        app/Modules/DevicesFeature/Tests/DeviceListContainmentTests.swift
git commit -m "feat(devices): controller-first containment forest with cycle and orphan guards"
```

---

## Task 4: Flatten with collapse, depth clamp, and badges

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/DeviceListModel.swift` (append `DeviceEntry`)
- Modify: `app/Modules/DevicesFeature/Sources/DeviceListLayout.swift` (append `flatten`)
- Test: `app/Modules/DevicesFeature/Tests/DeviceListCollapseTests.swift`

**Interfaces:**
- Consumes: `DeviceListLayout.Node`, `HostRelation`, `AttentionFlag`.
- Produces:
  - `public struct DeviceEntry: Identifiable, Equatable, Sendable` — `device`, `depth`, `childCount`, `isExpanded`, `host`, `attention`, `var id: String { device.deviceCode }`
  - `DeviceListLayout.flatten(_ nodes: [Node], depth: Int, parentCode: String?, expandedHosts: Set<String>, forcedOpen: Set<String>, attention: [String: [AttentionFlag]]) -> [DeviceEntry]`

- [ ] **Step 1: Write the failing collapse test**

Create `app/Modules/DevicesFeature/Tests/DeviceListCollapseTests.swift`:

```swift
//
//  DeviceListCollapseTests.swift
//  Replicould — Devices feature tests
//
//  Flattening: a collapsed host contributes no entries, depth clamps, and the
//  emitted order *is* `orderedIDs` — arrow-key navigation skips hidden rows by
//  construction rather than by a second rule that could drift.
//

import CustomDump
import Foundation
import GameModels
import Testing
@testable import DevicesFeature

@Suite struct DeviceListCollapseTests {

    private var fleet: [Device] {
        [
            makeDevice("VESSEL", type: "heaven_vessel"),
            makeDevice("CTRL", type: "ami_survey_controller", stowedIn: "VESSEL"),
            makeDevice("DRONEA", stowedIn: "VESSEL", controlledBy: "CTRL"),
            makeDevice("DRONEB", stowedIn: "VESSEL", controlledBy: "CTRL"),
        ]
    }

    private func flatten(expanded: Set<String>, forced: Set<String> = []) -> [DeviceEntry] {
        DeviceListLayout.flatten(
            DeviceListLayout.forest(fleet: fleet),
            expandedHosts: expanded,
            forcedOpen: forced,
            attention: [:]
        )
    }

    @Test func hostsDefaultCollapsed() {
        expectNoDifference(flatten(expanded: []).map(\.id), ["VESSEL"])
    }

    @Test func expandingOneLevelRevealsOnlyThatLevel() {
        expectNoDifference(flatten(expanded: ["VESSEL"]).map(\.id), ["VESSEL", "CTRL"])
    }

    @Test func expandingBothLevelsRevealsTheDrones() {
        expectNoDifference(
            flatten(expanded: ["VESSEL", "CTRL"]).map(\.id),
            ["VESSEL", "CTRL", "DRONEA", "DRONEB"]
        )
    }

    @Test func childCountAndExpansionAreReported() {
        let entries = flatten(expanded: ["VESSEL"])
        expectNoDifference(entries.map(\.childCount), [1, 2])
        expectNoDifference(entries.map(\.isExpanded), [true, false])
    }

    /// A leaf is never "expanded" even if its code sits in `expandedHosts`.
    @Test func leavesAreNeverExpanded() throws {
        let entries = flatten(expanded: ["VESSEL", "CTRL", "DRONEA"])
        let drone = try #require(entries.first { $0.id == "DRONEA" })
        expectNoDifference(drone.childCount, 0)
        expectNoDifference(drone.isExpanded, false)
    }

    @Test func depthIsCarriedAndClamped() {
        let deep = [
            makeDevice("L0", type: "heaven_vessel"),
            makeDevice("L1", type: "ami_survey_controller", stowedIn: "L0"),
            makeDevice("L2", type: "survey_drone", controlledBy: "L1"),
            makeDevice("L3", type: "mining_drone", controlledBy: "L2"),
        ]
        let entries = DeviceListLayout.flatten(
            DeviceListLayout.forest(fleet: deep),
            expandedHosts: ["L0", "L1", "L2"],
            forcedOpen: [],
            attention: [:]
        )
        expectNoDifference(entries.map(\.id), ["L0", "L1", "L2", "L3"])
        expectNoDifference(entries.map(\.depth), [0, 1, 2, 2])
    }

    /// `forcedOpen` reveals a subtree the operator has not opened — the reveal a
    /// search query applies, with `expandedHosts` left empty.
    @Test func forcedOpenRevealsWithoutTouchingExpandedHosts() {
        expectNoDifference(
            flatten(expanded: [], forced: ["VESSEL", "CTRL"]).map(\.id),
            ["VESSEL", "CTRL", "DRONEA", "DRONEB"]
        )
        // And with neither set, the same forest is closed again — proving the
        // reveal lives entirely in the argument, not in any stored state.
        expectNoDifference(flatten(expanded: []).map(\.id), ["VESSEL"])
    }

    @Test func badgeCarriesTheNonWinningRelation() throws {
        let entries = flatten(expanded: ["VESSEL", "CTRL"])
        let drone = try #require(entries.first { $0.id == "DRONEA" })
        expectNoDifference(drone.host, .stowed(in: "VESSEL"))
        let controller = try #require(entries.first { $0.id == "CTRL" })
        expectNoDifference(controller.host, nil)
    }

    @Test func attentionFlagsAreAttachedByCode() {
        let entries = DeviceListLayout.flatten(
            DeviceListLayout.forest(fleet: fleet),
            expandedHosts: [],
            forcedOpen: [],
            attention: ["VESSEL": [.outOfControlRange]]
        )
        expectNoDifference(entries.map(\.attention), [[.outOfControlRange]])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListCollapseTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: compile failure — `cannot find 'DeviceEntry' in scope`.

- [ ] **Step 3: Append `DeviceEntry` to the model file**

Append to `app/Modules/DevicesFeature/Sources/DeviceListModel.swift`:

```swift
/// One visible row. `depth` is a rendering hint on an already-flattened array —
/// nothing recurses in the view.
public struct DeviceEntry: Identifiable, Equatable, Sendable {
    public var device: Device
    /// Indent level, clamped at `DeviceListLayout.maxIndentDepth`.
    public var depth: Int
    /// Number of children this row hosts. 0 ⇒ not a host, so no chevron.
    /// While a search query is active this counts *retained* children only.
    public var childCount: Int
    public var isExpanded: Bool
    /// The relationship badge — the containment relation that did not decide
    /// this row's position.
    public var host: HostRelation?
    public var attention: [AttentionFlag]

    public var id: String { device.deviceCode }

    public init(
        device: Device,
        depth: Int,
        childCount: Int,
        isExpanded: Bool,
        host: HostRelation?,
        attention: [AttentionFlag]
    ) {
        self.device = device
        self.depth = depth
        self.childCount = childCount
        self.isExpanded = isExpanded
        self.host = host
        self.attention = attention
    }
}
```

- [ ] **Step 4: Implement `flatten`**

Append to `app/Modules/DevicesFeature/Sources/DeviceListLayout.swift`:

```swift
extension DeviceListLayout {

    /// Walks the forest in render order, emitting a node's children only when it
    /// is open. A collapsed host contributes no entries, so
    /// `sections.flatMap(\.entries).map(\.id)` — the list's `orderedIDs` — skips
    /// hidden rows by construction.
    ///
    /// `expandedHosts` is the operator's own disclosure state; `forcedOpen` is
    /// the transient reveal a search query applies to a match's ancestors, and
    /// never writes back.
    static func flatten(
        _ nodes: [Node],
        depth: Int = 0,
        parentCode: String? = nil,
        expandedHosts: Set<String>,
        forcedOpen: Set<String>,
        attention: [String: [AttentionFlag]]
    ) -> [DeviceEntry] {
        var entries: [DeviceEntry] = []
        for node in nodes {
            let code = node.device.deviceCode
            let isOpen = !node.children.isEmpty
                && (expandedHosts.contains(code) || forcedOpen.contains(code))
            entries.append(
                DeviceEntry(
                    device: node.device,
                    depth: min(depth, maxIndentDepth),
                    childCount: node.children.count,
                    isExpanded: isOpen,
                    host: badge(for: node.device, parentCode: parentCode),
                    attention: attention[code] ?? []
                )
            )
            if isOpen {
                entries.append(
                    contentsOf: flatten(
                        node.children,
                        depth: depth + 1,
                        parentCode: code,
                        expandedHosts: expandedHosts,
                        forcedOpen: forcedOpen,
                        attention: attention
                    )
                )
            }
        }
        return entries
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListCollapseTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: 9 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DevicesFeature/Sources/DeviceListModel.swift \
        app/Modules/DevicesFeature/Sources/DeviceListLayout.swift \
        app/Modules/DevicesFeature/Tests/DeviceListCollapseTests.swift
git commit -m "feat(devices): flatten the forest to visible entries with depth and collapse"
```

---

## Task 5: `sections(...)` with attention promotion

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/DeviceListModel.swift` (append `DeviceListSection`, `DeviceListHeader`, `StatusShare`)
- Modify: `app/Modules/DevicesFeature/Sources/DeviceListLayout.swift` (append `promote`, `sections`, `statusShares`)
- Test: `app/Modules/DevicesFeature/Tests/DeviceListSectionsTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–4.
- Produces:
  - `public struct StatusShare: Identifiable, Equatable, Sendable` — `status: String`, `count: Int`, `id: String { status }`
  - `public struct DeviceListHeader: Equatable, Sendable` — `title`, `count`, `isCollapsed`, `statusShares: [StatusShare]`, `hasDamaged: Bool`
  - `public struct DeviceListSection: Identifiable, Equatable, Sendable` — `id: String`, `header: DeviceListHeader?`, `entries: [DeviceEntry]`, plus `static let attentionID = "attention"` and `static let fleetID = "all"`
  - `DeviceListLayout.sections(fleet:attentionDirectives:searchText:expandedHosts:collapsedGroups:) -> [DeviceListSection]`

  `searchText` is accepted now and ignored until Task 6, so the state wiring in
  Task 7 does not need a signature change. Task 6's test suite is what proves it
  is honoured.

- [ ] **Step 1: Write the failing sections test**

Create `app/Modules/DevicesFeature/Tests/DeviceListSectionsTests.swift`:

```swift
//
//  DeviceListSectionsTests.swift
//  Replicould — Devices feature tests
//
//  The entry point: a pinned Needs Attention section above one unheadered
//  carrier section, with flagged devices *promoted* (not duplicated).
//

import CustomDump
import Foundation
import GameModels
import Testing
@testable import DevicesFeature

@Suite struct DeviceListSectionsTests {

    private func sections(
        fleet: [Device],
        directives: [Directive] = [],
        search: String = "",
        expanded: Set<String> = [],
        collapsedGroups: Set<String> = []
    ) -> [DeviceListSection] {
        DeviceListLayout.sections(
            fleet: fleet,
            attentionDirectives: directives,
            searchText: search,
            expandedHosts: expanded,
            collapsedGroups: collapsedGroups
        )
    }

    @Test func noAttentionSectionWhenNothingIsFlagged() {
        let result = sections(fleet: [makeDevice("AAAA"), makeDevice("BBBB")])
        expectNoDifference(result.map(\.id), [DeviceListSection.fleetID])
        expectNoDifference(result[0].header, nil)
    }

    @Test func flaggedDeviceIsPromotedNotDuplicated() {
        let fleet = [makeDevice("AAAA", capacity: 10), makeDevice("BBBB")]
        let result = sections(fleet: fleet)
        expectNoDifference(result.map(\.id), [DeviceListSection.attentionID, DeviceListSection.fleetID])
        expectNoDifference(result[0].entries.map(\.id), ["AAAA"])
        expectNoDifference(result[1].entries.map(\.id), ["BBBB"])
    }

    /// A flagged device is lifted out at whatever depth it sat, taking its own
    /// subtree with it, and re-rooted at depth 0 of the attention section. Its
    /// former host stays put with `childCount` reduced.
    @Test func promotionLiftsTheSubtreeAndReducesTheFormerHostsChildCount() throws {
        let fleet = [
            makeDevice("VESSEL", type: "heaven_vessel"),
            makeDevice("CTRL", type: "ami_survey_controller", stowedIn: "VESSEL", capacity: 20),
            makeDevice("DRONEA", stowedIn: "VESSEL", controlledBy: "CTRL"),
            makeDevice("OTHER", type: "ami_survey_controller", stowedIn: "VESSEL"),
        ]
        let result = sections(fleet: fleet, expanded: ["VESSEL", "CTRL"])

        let attention = result[0]
        expectNoDifference(attention.entries.map(\.id), ["CTRL", "DRONEA"])
        expectNoDifference(attention.entries.map(\.depth), [0, 1])

        let vessel = try #require(result[1].entries.first { $0.id == "VESSEL" })
        expectNoDifference(vessel.childCount, 1)
        expectNoDifference(result[1].entries.map(\.id), ["VESSEL", "OTHER"])
    }

    /// A flagged device inside a flagged device's subtree appears once, under it.
    @Test func nestedFlaggedDeviceAppearsOnlyOnce() {
        let fleet = [
            makeDevice("CTRL", type: "ami_survey_controller", capacity: 20),
            makeDevice("DRONEA", controlledBy: "CTRL", capacity: 10),
        ]
        let result = sections(fleet: fleet, expanded: ["CTRL"])
        expectNoDifference(result.map(\.id), [DeviceListSection.attentionID])
        expectNoDifference(result[0].entries.map(\.id), ["CTRL", "DRONEA"])
    }

    @Test func attentionSectionOrdersByReason() {
        let fleet = [
            makeDevice("AAAA", capacity: 40),
            makeDevice("BBBB", detail: .object(["in_control_range": .bool(false)])),
            makeDevice("CCCC", capacity: 10),
        ]
        let result = sections(fleet: fleet)
        expectNoDifference(result[0].entries.map(\.id), ["BBBB", "CCCC", "AAAA"])
    }

    @Test func collapsedAttentionSectionKeepsItsHeaderAndDropsItsEntries() throws {
        let fleet = [makeDevice("AAAA", capacity: 10), makeDevice("BBBB")]
        let result = sections(fleet: fleet, collapsedGroups: [DeviceListSection.attentionID])
        expectNoDifference(result[0].entries, [])
        let header = try #require(result[0].header)
        expectNoDifference(header.isCollapsed, true)
        expectNoDifference(header.count, 1)
        expectNoDifference(header.hasDamaged, true)
    }

    @Test func headerReportsItsStatusDistribution() throws {
        let fleet = [
            makeDevice("AAAA", status: "relaying", capacity: 10),
            makeDevice("BBBB", status: "relaying", capacity: 20),
            makeDevice("CCCC", status: "idle", capacity: 30),
        ]
        let header = try #require(sections(fleet: fleet)[0].header)
        expectNoDifference(
            header.statusShares,
            [StatusShare(status: "relaying", count: 2), StatusShare(status: "idle", count: 1)]
        )
    }

    @Test func directiveFlaggedDeviceIsPromoted() {
        let fleet = [makeDevice("AAAA"), makeDevice("BBBB")]
        let directives = [makeDirective(deviceCode: "BBBB", reason: .commandRejected)]
        let result = sections(fleet: fleet, directives: directives)
        expectNoDifference(result[0].entries.map(\.id), ["BBBB"])
        expectNoDifference(result[0].entries[0].attention, [.directive(.commandRejected)])
        expectNoDifference(result[1].entries.map(\.id), ["AAAA"])
    }

    @Test func orderedIDsAreTheVisibleOrderExactly() {
        let fleet = [
            makeDevice("VESSEL", type: "heaven_vessel"),
            makeDevice("CTRL", type: "ami_survey_controller", stowedIn: "VESSEL"),
            makeDevice("DRONEA", stowedIn: "VESSEL", controlledBy: "CTRL"),
            makeDevice("HURT", capacity: 5),
        ]
        let result = sections(fleet: fleet, expanded: ["VESSEL"])
        expectNoDifference(
            result.flatMap(\.entries).map(\.id),
            ["HURT", "VESSEL", "CTRL"]
        )
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListSectionsTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: compile failure — `cannot find 'DeviceListSection' in scope`.

- [ ] **Step 3: Append the section types to the model file**

Append to `app/Modules/DevicesFeature/Sources/DeviceListModel.swift`:

```swift
/// One segment of a section header's status-distribution bar.
public struct StatusShare: Identifiable, Equatable, Sendable {
    /// The raw `statusBase`, mapped to a colour by `DeviceStatus.tone(for:)`.
    public var status: String
    public var count: Int
    public var id: String { status }

    public init(status: String, count: Int) {
        self.status = status
        self.count = count
    }
}

/// A section's readout header. Nil on an unheadered section.
public struct DeviceListHeader: Equatable, Sendable {
    public var title: String
    public var count: Int
    public var isCollapsed: Bool
    /// The section's status distribution, count descending then status name —
    /// what makes a collapsed section still worth reading.
    public var statusShares: [StatusShare]
    /// Any member below `DeviceListLayout.damagedCapacityThreshold`.
    public var hasDamaged: Bool

    public init(
        title: String,
        count: Int,
        isCollapsed: Bool,
        statusShares: [StatusShare],
        hasDamaged: Bool
    ) {
        self.title = title
        self.count = count
        self.isCollapsed = isCollapsed
        self.statusShares = statusShares
        self.hasDamaged = hasDamaged
    }
}

/// A section of already-flattened rows. Real `Section`s (rather than one wholly
/// flat array) are what let the list keep `pinnedViews: [.sectionHeaders]` and
/// its sticky Liquid Glass headers.
public struct DeviceListSection: Identifiable, Equatable, Sendable {
    public static let attentionID = "attention"
    public static let fleetID = "all"

    public var id: String
    /// Nil ⇒ unheadered (the Carrier-mode fleet section).
    public var header: DeviceListHeader?
    /// Already flattened; empty when the section is collapsed.
    public var entries: [DeviceEntry]

    public init(id: String, header: DeviceListHeader?, entries: [DeviceEntry]) {
        self.id = id
        self.header = header
        self.entries = entries
    }
}
```

- [ ] **Step 4: Implement promotion and the entry point**

Append to `app/Modules/DevicesFeature/Sources/DeviceListLayout.swift`:

```swift
extension DeviceListLayout {

    /// Lifts every flagged node out of the forest — at whatever depth it sat,
    /// taking its own subtree with it — and returns it alongside what's left.
    /// A flagged node inside another flagged node's subtree travels with its
    /// host rather than being lifted again, so it appears exactly once.
    static func promote(_ nodes: [Node], flagged: Set<String>) -> (promoted: [Node], remaining: [Node]) {
        var promoted: [Node] = []
        var remaining: [Node] = []
        for node in nodes {
            if flagged.contains(node.device.deviceCode) {
                promoted.append(node)
            } else {
                let split = promote(node.children, flagged: flagged)
                promoted.append(contentsOf: split.promoted)
                remaining.append(Node(device: node.device, children: split.remaining))
            }
        }
        return (promoted, remaining)
    }

    /// Every device a forest holds, roots and descendants alike.
    static func devices(in nodes: [Node]) -> [Device] {
        nodes.flatMap { [$0.device] + devices(in: $0.children) }
    }

    /// The section's status distribution, count descending then status name.
    static func statusShares(_ devices: [Device]) -> [StatusShare] {
        Dictionary(grouping: devices, by: \.statusBase)
            .map { StatusShare(status: $0.key, count: $0.value.count) }
            .sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.status < $1.status
            }
    }

    /// The list's one entry point. Returns a pinned Needs Attention section (when
    /// anything is flagged) above one unheadered Carrier section. Empty sections
    /// are dropped, except a *collapsed* Needs Attention, which keeps its header
    /// so the operator can open it again.
    public static func sections(
        fleet: [Device],
        attentionDirectives: [Directive],
        searchText: String,
        expandedHosts: Set<String>,
        collapsedGroups: Set<String>
    ) -> [DeviceListSection] {
        let attention = Dictionary(
            fleet.map { ($0.deviceCode, attentionFlags(for: $0, directives: attentionDirectives)) },
            uniquingKeysWith: { first, _ in first }
        )
        let flagged = Set(attention.filter { !$0.value.isEmpty }.keys)

        let split = promote(forest(fleet: fleet), flagged: flagged)
        let attentionRoots = split.promoted.sorted {
            attentionPrecedes($0.device, $1.device, attention: attention)
        }

        var sections: [DeviceListSection] = []

        if !attentionRoots.isEmpty {
            let isCollapsed = collapsedGroups.contains(DeviceListSection.attentionID)
            let members = devices(in: attentionRoots)
            sections.append(
                DeviceListSection(
                    id: DeviceListSection.attentionID,
                    header: DeviceListHeader(
                        title: "Needs Attention",
                        count: attentionRoots.count,
                        isCollapsed: isCollapsed,
                        statusShares: statusShares(members),
                        hasDamaged: members.contains { $0.operationalCapacity < damagedCapacityThreshold }
                    ),
                    entries: isCollapsed ? [] : flatten(
                        attentionRoots,
                        expandedHosts: expandedHosts,
                        forcedOpen: [],
                        attention: attention
                    )
                )
            )
        }

        let fleetEntries = flatten(
            split.remaining,
            expandedHosts: expandedHosts,
            forcedOpen: [],
            attention: attention
        )
        if !fleetEntries.isEmpty {
            sections.append(
                DeviceListSection(id: DeviceListSection.fleetID, header: nil, entries: fleetEntries)
            )
        }

        return sections
    }
}
```

Note `header.count` is the number of promoted **roots**, matching the "N of M"
reading of the section as a triage list rather than a subtree census. The status
bar, by contrast, covers every member including promoted subtrees — a collapsed
section should describe everything it hides.

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListSectionsTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: 9 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DevicesFeature/Sources/DeviceListModel.swift \
        app/Modules/DevicesFeature/Sources/DeviceListLayout.swift \
        app/Modules/DevicesFeature/Tests/DeviceListSectionsTests.swift
git commit -m "feat(devices): pin Needs Attention above the fleet, promoting flagged subtrees"
```

---

## Task 6: Search pruning with forced-open ancestors

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/DeviceListSearch.swift` (append `pruned`)
- Modify: `app/Modules/DevicesFeature/Sources/DeviceListLayout.swift` (`sections` honours `searchText`)
- Test: `app/Modules/DevicesFeature/Tests/DeviceListSearchTests.swift` (append a suite)

**Interfaces:**
- Consumes: `DeviceListLayout.Node`, `Query`, `matches`, `sections`.
- Produces: `DeviceListLayout.pruned(_ nodes: [Node], query: Query) -> (nodes: [Node], forcedOpen: Set<String>)`

- [ ] **Step 1: Write the failing search-×-collapse test**

Append to `app/Modules/DevicesFeature/Tests/DeviceListSearchTests.swift`:

```swift
@Suite struct DeviceListSearchPruningTests {

    private var fleet: [Device] {
        [
            makeDevice("VESSEL", type: "heaven_vessel", location: "ATIANFU-1-L4"),
            makeDevice("CTRL", type: "ami_survey_controller", stowedIn: "VESSEL"),
            makeDevice("DRONEA", type: "survey_drone", stowedIn: "VESSEL", controlledBy: "CTRL"),
            makeDevice("RELAY", type: "ftl_relay", status: "relaying", location: "POLARISUM-1"),
        ]
    }

    private func sections(_ search: String, expanded: Set<String> = []) -> [DeviceListSection] {
        DeviceListLayout.sections(
            fleet: fleet,
            attentionDirectives: [],
            searchText: search,
            expandedHosts: expanded,
            collapsedGroups: []
        )
    }

    /// A match on a child of a collapsed host is revealed, ancestors and all.
    @Test func matchOnACollapsedChildIsRevealed() {
        let entries = sections("survey_drone").flatMap(\.entries)
        expectNoDifference(entries.map(\.id), ["VESSEL", "CTRL", "DRONEA"])
    }

    /// The reveal is transient: `expandedHosts` is an input and is never written.
    @Test func revealDoesNotMutateExpandedHosts() {
        let expanded: Set<String> = []
        _ = sections("survey_drone", expanded: expanded)
        expectNoDifference(expanded, [])
    }

    /// A host that matches on its own keeps its own collapse state — its
    /// children are pruned out, so it reports no children to disclose.
    @Test func aHostMatchingAloneKeepsItsChildrenHidden() {
        let entries = sections("POLARISUM").flatMap(\.entries)
        expectNoDifference(entries.map(\.id), ["RELAY"])
    }

    @Test func nonMatchingBranchesAreDropped() {
        let entries = sections("ftl_relay").flatMap(\.entries)
        expectNoDifference(entries.map(\.id), ["RELAY"])
    }

    /// Search runs before sectioning; a section left with nothing is dropped.
    @Test func noMatchesYieldsNoSections() {
        expectNoDifference(sections("zzzznothing"), [])
    }

    /// Ancestors are retained even though they don't match, and their
    /// `childCount` reflects the retained children only.
    @Test func retainedAncestorReportsRetainedChildCount() {
        let entries = sections("DRONEA").flatMap(\.entries)
        expectNoDifference(entries.map(\.id), ["VESSEL", "CTRL", "DRONEA"])
        expectNoDifference(entries.map(\.childCount), [1, 1, 0])
    }

    /// A flagged device promoted into Needs Attention is searchable there too.
    @Test func attentionSectionIsFilteredToo() {
        let flaggedFleet = fleet + [makeDevice("HURT", type: "mining_drone", capacity: 5)]
        let result = DeviceListLayout.sections(
            fleet: flaggedFleet,
            attentionDirectives: [],
            searchText: "mining",
            expandedHosts: [],
            collapsedGroups: []
        )
        expectNoDifference(result.map(\.id), [DeviceListSection.attentionID])
        expectNoDifference(result[0].entries.map(\.id), ["HURT"])
    }
}
```

`import CustomDump` and `import GameModels` must be present at the top of
`DeviceListSearchTests.swift`; add them if Task 1's version doesn't have them.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListSearchPruningTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: FAIL — every case returns the unfiltered fleet, since `sections` still
ignores `searchText`.

- [ ] **Step 3: Implement pruning**

Append to `app/Modules/DevicesFeature/Sources/DeviceListSearch.swift`:

```swift
extension DeviceListLayout {

    /// Prunes the forest to nodes that match, or that have a matching
    /// descendant, and reports the ancestors to force open for the duration of
    /// the query. A match is never unreachable behind a collapsed host, and the
    /// operator's own `expandedHosts` is untouched.
    static func pruned(_ nodes: [Node], query: Query) -> (nodes: [Node], forcedOpen: Set<String>) {
        guard !query.isEmpty else { return (nodes, []) }

        var kept: [Node] = []
        var forcedOpen: Set<String> = []
        for node in nodes {
            let below = pruned(node.children, query: query)
            guard matches(node.device, query: query) || !below.nodes.isEmpty else { continue }
            kept.append(Node(device: node.device, children: below.nodes))
            forcedOpen.formUnion(below.forcedOpen)
            if !below.nodes.isEmpty { forcedOpen.insert(node.device.deviceCode) }
        }
        return (kept, forcedOpen)
    }
}
```

- [ ] **Step 4: Wire pruning into `sections`**

In `app/Modules/DevicesFeature/Sources/DeviceListLayout.swift`, edit `sections`.
Replace the block from `let split = promote(...)` down to the `return sections`
with:

```swift
        let query = Query(searchText)
        let split = promote(forest(fleet: fleet), flagged: flagged)

        let attentionPruned = pruned(split.promoted, query: query)
        let attentionRoots = attentionPruned.nodes.sorted {
            attentionPrecedes($0.device, $1.device, attention: attention)
        }
        let fleetPruned = pruned(split.remaining, query: query)

        var sections: [DeviceListSection] = []

        if !attentionRoots.isEmpty {
            let isCollapsed = collapsedGroups.contains(DeviceListSection.attentionID)
            let members = devices(in: attentionRoots)
            sections.append(
                DeviceListSection(
                    id: DeviceListSection.attentionID,
                    header: DeviceListHeader(
                        title: "Needs Attention",
                        count: attentionRoots.count,
                        isCollapsed: isCollapsed,
                        statusShares: statusShares(members),
                        hasDamaged: members.contains { $0.operationalCapacity < damagedCapacityThreshold }
                    ),
                    entries: isCollapsed ? [] : flatten(
                        attentionRoots,
                        expandedHosts: expandedHosts,
                        forcedOpen: attentionPruned.forcedOpen,
                        attention: attention
                    )
                )
            )
        }

        let fleetEntries = flatten(
            fleetPruned.nodes,
            expandedHosts: expandedHosts,
            forcedOpen: fleetPruned.forcedOpen,
            attention: attention
        )
        if !fleetEntries.isEmpty {
            sections.append(
                DeviceListSection(id: DeviceListSection.fleetID, header: nil, entries: fleetEntries)
            )
        }

        return sections
```

- [ ] **Step 5: Run both search suites and the whole target**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: every `DevicesFeatureTests` case passes — including the pre-existing
reducer suites, which this task must not have disturbed. Check for crashes as
well as failures:

```bash
jq -s 'map(select(.kind=="event").payload) as $e
  | { failed: ($e|map(select(.kind=="issueRecorded" and .issue.isFailure != false).testID)|unique),
      crashed: (($e|map(select(.kind=="testStarted").testID)) - ($e|map(select(.kind=="testEnded" or .kind=="testSkipped").testID))),
      completed: ($e|map(select(.kind=="runEnded"))|length) }' .build/events.jsonl
```

Expected: `failed` `[]`, `crashed` `[]`, `completed` `1`.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DevicesFeature/Sources/DeviceListSearch.swift \
        app/Modules/DevicesFeature/Sources/DeviceListLayout.swift \
        app/Modules/DevicesFeature/Tests/DeviceListSearchTests.swift
git commit -m "feat(devices): search retains matching subtrees and reveals their ancestors"
```

---

## Task 7: Feature state, actions, and the reducer

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/DevicesFeature.swift`
- Test: `app/Modules/DevicesFeature/Tests/DevicesFeatureTests.swift` (append a suite)

**Interfaces:**
- Consumes: `DeviceListLayout.sections(...)`, `DeviceListLayout.Query`, `DeviceListLayout.matches(_:query:)`.
- Produces:
  - `DevicesFeature.State.searchText: String`, `.expandedHosts: Set<String>`, `.collapsedGroups: Set<String>`, `.attentionDirectives: [Directive]`
  - `DevicesFeature.State.sections: [DeviceListSection]`, `.orderedIDs: [String]`, `.matchCount: Int`
  - `DevicesFeature.Action.hostDisclosureToggled(String)`, `.groupDisclosureToggled(String)`

- [ ] **Step 1: Write the failing reducer test**

Append to `app/Modules/DevicesFeature/Tests/DevicesFeatureTests.swift`:

```swift
/// The list's organisation state: binding-driven search, the two disclosure
/// gestures, and the derived sections the view renders.
@MainActor
@Suite struct DeviceListStateTests {

    @Test func hostDisclosureTogglesOnAndOff() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }

        await store.send(.hostDisclosureToggled("VESSEL")) {
            $0.expandedHosts = ["VESSEL"]
        }
        await store.send(.hostDisclosureToggled("VESSEL")) {
            $0.expandedHosts = []
        }
    }

    @Test func groupDisclosureTogglesOnAndOff() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }

        await store.send(.groupDisclosureToggled(DeviceListSection.attentionID)) {
            $0.collapsedGroups = [DeviceListSection.attentionID]
        }
        await store.send(.groupDisclosureToggled(DeviceListSection.attentionID)) {
            $0.collapsedGroups = []
        }
    }

    @Test func searchTextIsDrivenByTheBindingReducer() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }

        await store.send(\.binding.searchText, "survey") {
            $0.searchText = "survey"
        }
    }

    /// Hosts default collapsed, so the top level is roots only — and the
    /// disclosure gesture opens exactly one level.
    @Test func derivedSectionsCollapseHostsByDefault() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert {
                makeDevice("VESSEL", type: "heaven_vessel")
                makeDevice("CTRL", type: "ami_survey_controller", stowedIn: "VESSEL")
            }
            .execute(db)
        }

        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        #expect(store.state.orderedIDs == ["VESSEL"])
        await store.send(.hostDisclosureToggled("VESSEL"))
        #expect(store.state.orderedIDs == ["VESSEL", "CTRL"])
    }

    /// `matchCount` counts the whole fleet's matches, not the visible rows —
    /// the "N" in the "N of M devices" subtitle.
    @Test func matchCountCountsMatchesNotVisibleRows() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.insert {
                makeDevice("VESSEL", type: "heaven_vessel")
                makeDevice("DRONEA", type: "survey_drone", stowedIn: "VESSEL")
            }
            .execute(db)
        }

        let store = TestStore(initialState: DevicesFeature.State()) {
            DevicesFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off

        #expect(store.state.matchCount == 2)
        await store.send(\.binding.searchText, "survey_drone")
        #expect(store.state.matchCount == 1)
        // The ancestor is revealed but is not itself a match.
        #expect(store.state.orderedIDs == ["VESSEL", "DRONEA"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListStateTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: compile failure — `type 'DevicesFeature.Action' has no member 'hostDisclosureToggled'`.

- [ ] **Step 3: Add the state**

In `app/Modules/DevicesFeature/Sources/DevicesFeature.swift`, add `import GameModels`
if absent (it is already there), then insert directly after the `devices`
property in `State`:

```swift
        /// Directives currently flagged for the operator — the third Needs
        /// Attention predicate. Filtered in SQL (`DirectiveStatus` is
        /// `QueryBindable`) so the layout never re-checks status.
        @ObservationStateIgnored
        @FetchAll(Directive.where { $0.status.eq(DirectiveStatus.needsAttention) })
        public var attentionDirectives: [Directive]

        /// The list's search query. Driven by `.searchable` through the
        /// `BindingReducer()` — no bespoke action.
        public var searchText = ""

        /// Codes of the hosts the operator has opened. Empty ⇒ every host
        /// collapsed, which is the default and needs no seeding.
        public var expandedHosts: Set<String> = []

        /// IDs of the sections the operator has closed. Empty ⇒ every section
        /// open. The two disclosure sets are asymmetric on purpose: each
        /// defaults to the desired state at an empty set.
        public var collapsedGroups: Set<String> = []
```

Then add these derived properties beside `selectedDevice`:

```swift
        /// The organised list. `State` derives it, the view renders it — the
        /// established "list query in state, view is a pure renderer" standard.
        /// Recomputed on access, so a view body should bind it to a `let` once
        /// rather than reading `store.sections` several times.
        public var sections: [DeviceListSection] {
            DeviceListLayout.sections(
                fleet: devices,
                attentionDirectives: attentionDirectives,
                searchText: searchText,
                expandedHosts: expandedHosts,
                collapsedGroups: collapsedGroups
            )
        }

        /// Arrow-key navigation order. A collapsed host contributes no entries,
        /// so hidden rows are absent by construction rather than by a second
        /// rule that could drift out of step with the renderer.
        public var orderedIDs: [String] {
            sections.flatMap(\.entries).map(\.id)
        }

        /// Devices matching the active query across the *whole* fleet — the "N"
        /// in the "N of M devices" subtitle. Not the visible row count, which
        /// also includes the non-matching ancestors a match reveals.
        public var matchCount: Int {
            let query = DeviceListLayout.Query(searchText)
            guard !query.isEmpty else { return devices.count }
            return devices.filter { DeviceListLayout.matches($0, query: query) }.count
        }
```

- [ ] **Step 4: Add the actions and handle them**

Add to `DevicesFeature.Action`, next to the other list-level cases:

```swift
        /// The disclosure gestures. Named for the gesture rather than the logic,
        /// because the logic is `DeviceListLayout`'s.
        case groupDisclosureToggled(String)
        case hostDisclosureToggled(String)
```

Add to the reducer's `switch`, immediately after `case .binding: return .none`:

```swift
            case let .groupDisclosureToggled(sectionID):
                if state.collapsedGroups.contains(sectionID) {
                    state.collapsedGroups.remove(sectionID)
                } else {
                    state.collapsedGroups.insert(sectionID)
                }
                return .none

            case let .hostDisclosureToggled(deviceCode):
                if state.expandedHosts.contains(deviceCode) {
                    state.expandedHosts.remove(deviceCode)
                } else {
                    state.expandedHosts.insert(deviceCode)
                }
                return .none
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --filter 'DeviceListStateTests' \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

Expected: 5 tests, 0 failures.

If `derivedSectionsCollapseHostsByDefault` or `matchCountCountsMatchesNotVisibleRows`
sees an empty fleet, the `@FetchAll` has not observed the seeded rows yet — seed
the database *before* constructing the `TestStore` (as written above), not after.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DevicesFeature/Sources/DevicesFeature.swift \
        app/Modules/DevicesFeature/Tests/DevicesFeatureTests.swift
git commit -m "feat(devices): derive the organised list in state, with the two disclosure gestures"
```

---

## Task 8: The collapsible readout section header

**Files:**
- Create: `app/Modules/UI/Sources/RCReadoutSectionHeader.swift`

**Interfaces:**
- Consumes: `Space`, `Radius`, `IconSize`, `Hairline`, `Font.rcSectionLabel`, `Font.rcMonoSmall`, `Color.rcTextTertiary`, `Color.rcWarning`.
- Produces: `RCReadoutSectionHeader.init(title:count:isCollapsed:isWarning:shares:onToggle:)` and `RCReadoutSectionHeader.Share(label:count:color:)`.

This task is a view with no unit test — SwiftUI views in this repo are verified
by building and by looking at them. The verification step is a clean build of the
`UI` target plus a visual check in the running app at the end of Task 10.

- [ ] **Step 1: Write the header view**

Create `app/Modules/UI/Sources/RCReadoutSectionHeader.swift`:

```swift
//
//  RCReadoutSectionHeader.swift
//  Replicould — UI
//
//  A collapsible list section header that doubles as a readout: title, member
//  count, an optional warning marker, and a thin stacked bar of the section's
//  composition. Domain-free on purpose — the caller supplies already-coloured
//  `Share` values, so this file knows nothing about devices or status strings.
//
//  Rides the same Liquid Glass band as `SelectableList`'s built-in inline
//  header, so a pinned (sticky) instance blurs the rows scrolling beneath it.
//

import SwiftUI

public struct RCReadoutSectionHeader: View {

    /// One segment of the stacked bar.
    public struct Share: Identifiable, Equatable {
        public let label: String
        public let count: Int
        public let color: Color
        public var id: String { label }

        public init(label: String, count: Int, color: Color) {
            self.label = label
            self.count = count
            self.color = color
        }
    }

    private let title: String
    private let count: Int
    private let isCollapsed: Bool
    private let isWarning: Bool
    private let shares: [Share]
    private let onToggle: () -> Void

    public init(
        title: String,
        count: Int,
        isCollapsed: Bool,
        isWarning: Bool = false,
        shares: [Share] = [],
        onToggle: @escaping () -> Void
    ) {
        self.title = title
        self.count = count
        self.isCollapsed = isCollapsed
        self.isWarning = isWarning
        self.shares = shares
        self.onToggle = onToggle
    }

    private var total: Int { shares.reduce(0) { $0 + $1.count } }

    public var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: IconSize.s))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(.rcTextTertiary)
                    Text(title.uppercased())
                        .font(.rcSectionLabel)
                        .kerning(1)
                        .foregroundStyle(.rcTextTertiary)
                    Text("\(count)")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                    if isWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: IconSize.s))
                            .foregroundStyle(.rcWarning)
                    }
                    Spacer(minLength: Space.xs)
                }
                if total > 0 {
                    shareBar
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
            .glassEffect(.regular, in: Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title), \(count) items"))
        .accessibilityAddTraits(.isHeader)
    }

    /// The composition bar. `GeometryReader` is fenced inside an explicit
    /// `frame(height:)` so it can never report an unbounded ideal height — a
    /// header is chrome, and chrome that reports a tall minimum pins the whole
    /// window's minimum height (see the chrome-min-height memory note).
    private var shareBar: some View {
        GeometryReader { proxy in
            HStack(spacing: Hairline.regular) {
                ForEach(shares) { share in
                    Rectangle()
                        .fill(share.color)
                        .frame(
                            width: max(
                                Hairline.regular,
                                proxy.size.width * CGFloat(share.count) / CGFloat(max(total, 1))
                            )
                        )
                }
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
    }
}
```

- [ ] **Step 2: Build the UI target to verify it compiles**

```bash
cd app/Modules && swift build --target UI 2>&1 | tail -20
```

Expected: `Build complete!` with no warnings from this file. If `.glassEffect`
is unavailable, confirm the deployment target — the app targets macOS 26 and
`SelectableList.swift` already calls it in `InlineHeaderGlass`.

- [ ] **Step 3: Commit**

```bash
git add app/Modules/UI/Sources/RCReadoutSectionHeader.swift
git commit -m "feat(ui): collapsible readout section header with a composition bar"
```

---

## Task 9: The device row

**Files:**
- Create: `app/Modules/DevicesFeature/Sources/DeviceRow.swift`
- Modify: `app/Modules/DevicesFeature/Sources/DevicesView.swift` (delete the private `DeviceRow`)

**Interfaces:**
- Consumes: `DeviceEntry`, `HostRelation`, `AttentionFlag` (Tasks 2–4); `RCGlyphTile`, `RCMeterBar`, `StatusBadge`, design tokens.
- Produces: `struct DeviceRow: View` with `init(entry: DeviceEntry, onDisclosureToggle: @escaping () -> Void)`.

- [ ] **Step 1: Move and extend the row**

Create `app/Modules/DevicesFeature/Sources/DeviceRow.swift`. This is the existing
row body from `DevicesView.swift` plus the indent, disclosure, attention dot,
host badge, and tag chip. **No `#Preview` in this file** — the Xcode 26 preview
JIT crashes when a list-row struct shares a file with one.

```swift
//
//  DeviceRow.swift
//  Replicould — Devices feature
//
//  One row of the fleet master list. Renders a `DeviceEntry` and nothing else:
//  containment is already resolved into `depth` / `childCount` / `host` by
//  `DeviceListLayout`, so this view never walks the fleet.
//
//  No `#Preview` in this file — the Xcode 26 preview JIT crashes when a list-row
//  struct sits beside one (.claude/memory/list-row-preview-crash.md).
//

import GameModels
import SwiftUI
import UI

struct DeviceRow: View {
    let entry: DeviceEntry
    let onDisclosureToggle: () -> Void

    private var device: Device { entry.device }

    /// Reserved so a leaf's glyph lines up with a host's, one indent per depth.
    private static let disclosureWidth: CGFloat = 22

    var body: some View {
        HStack(spacing: Space.s) {
            disclosure
            VStack(spacing: Space.xs) {
                RCGlyphTile(Image.rcSymbol("device.\(device.deviceType)"))
                RCMeterBar(fraction: device.operationalCapacity / 100)
                    .frame(width: 30)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                titleLine
                metaLine
            }
        }
        .padding(.vertical, Space.xs)
        .padding(.leading, CGFloat(entry.depth) * Space.l)
    }

    @ViewBuilder
    private var disclosure: some View {
        if entry.childCount > 0 {
            Button(action: onDisclosureToggle) {
                VStack(spacing: Space.xxs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: IconSize.s))
                        .rotationEffect(.degrees(entry.isExpanded ? 90 : 0))
                    Text("\(entry.childCount)")
                        .font(.rcMicroMono)
                }
                .foregroundStyle(.rcTextTertiary)
                .frame(width: Self.disclosureWidth)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.isExpanded ? "Collapse" : "Expand")
        } else {
            Color.clear.frame(width: Self.disclosureWidth, height: 1)
        }
    }

    private var titleLine: some View {
        HStack(spacing: Space.s) {
            if !entry.attention.isEmpty {
                Circle()
                    .fill(.rcDanger)
                    .frame(width: 6, height: 6)
                    .help(entry.attention.map(\.label).joined(separator: " · "))
            }
            Text(DevicePresentation.displayName(device.deviceType))
                .font(.rcBodyEmph)
                .foregroundStyle(.rcTextPrimary)
                .lineLimit(1)
            Text(device.deviceCode)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextTertiary)
            Spacer(minLength: Space.xs)
        }
    }

    private var metaLine: some View {
        HStack(spacing: Space.s) {
            StatusBadge(device.statusBase)
            if let location = device.location {
                Text(location)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
                    .lineLimit(1)
            } else if let destination = travelDestination {
                Label(destination, systemImage: "location.north.line")
                    .labelStyle(.titleAndIcon)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
                    .lineLimit(1)
            }
            if let host = entry.host {
                Label(host.hostCode, systemImage: host.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
                    .lineLimit(1)
                    .help(host.label)
            }
            ForEach(device.tags, id: \.self) { tag in
                Text(tag)
                    .font(.rcMicro)
                    .foregroundStyle(.rcTextSecondary)
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, Space.xxs)
                    .background(Capsule().fill(.rcSurfaceRaised))
            }
            Spacer(minLength: Space.xs)
        }
    }

    /// The trip's destination code while the device is en route — surfaced only
    /// when there's no settled `location` to show instead. Prefers the whole
    /// route's `final_destination` over the active leg's `destination`.
    private var travelDestination: String? {
        guard device.derivedActivity?.kind == .travel else { return nil }
        return device.detail["travel"]?["final_destination"]?.stringValue
            ?? device.detail["travel"]?["destination"]?.stringValue
    }
}
```

- [ ] **Step 2: Delete the old row from `DevicesView.swift`**

Remove the entire `// MARK: - Row` section and the `private struct DeviceRow`
below it from `app/Modules/DevicesFeature/Sources/DevicesView.swift`. Leave the
`DevicesListView` struct alone for now — Task 10 rewrites it, and it will not
compile between these two tasks.

- [ ] **Step 3: Commit**

The build is red between Tasks 9 and 10 by construction (the old view still calls
`DeviceRow(device:)`), so commit the row on its own and let Task 10 close the loop:

```bash
git add app/Modules/DevicesFeature/Sources/DeviceRow.swift \
        app/Modules/DevicesFeature/Sources/DevicesView.swift
git commit -m "refactor(devices): extract DeviceRow and give it indent, disclosure, badges"
```

---

## Task 10: Wire the list view

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/DevicesView.swift`

**Interfaces:**
- Consumes: `State.sections`, `.orderedIDs`, `.matchCount`, `.searchText`; `Action.hostDisclosureToggled`, `.groupDisclosureToggled`; `SelectableList(selection:orderedIDs:style:pinnedViews:content:)`, `SelectableRow`, `RCReadoutSectionHeader`, `DeviceRow`.
- Produces: the finished Stage 1 list.

- [ ] **Step 1: Rewrite the list view**

Replace the body of `DevicesListView` in
`app/Modules/DevicesFeature/Sources/DevicesView.swift`:

```swift
    public var body: some View {
        // Bound once: `sections` is derived on access, so reading it from the
        // list, the overlay, and the subtitle would recompute the whole layout
        // three times per body evaluation.
        let sections = store.sections

        SelectableList(
            selection: $store.selectedDeviceCode,
            orderedIDs: sections.flatMap(\.entries).map(\.id),
            style: .inline,
            pinnedViews: [.sectionHeaders]
        ) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        SelectableRow(id: entry.id) { isSelected in
                            DeviceRow(entry: entry) {
                                store.send(.hostDisclosureToggled(entry.id))
                            }
                            .rcSidebarRow(isSelected: isSelected)
                        }
                    }
                } header: {
                    if let header = section.header {
                        RCReadoutSectionHeader(
                            title: header.title,
                            count: header.count,
                            isCollapsed: header.isCollapsed,
                            isWarning: header.hasDamaged,
                            shares: header.statusShares.map {
                                RCReadoutSectionHeader.Share(
                                    label: $0.status,
                                    count: $0.count,
                                    color: DeviceStatus.tone(for: $0.status).color
                                )
                            }
                        ) {
                            store.send(.groupDisclosureToggled(section.id))
                        }
                    }
                }
            }
        }
        .background(.rcContentBackground)
        .overlay {
            if sections.isEmpty { emptyState }
        }
        .navigationTitle("Devices")
        .navigationSubtitle(subtitle)
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search devices")
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = store.errorMessage {
                RCErrorBanner(errorMessage) { store.send(.dismissError) }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.send(.refreshButtonTapped)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh fleet")
                .disabled(store.isLoading)
            }
        }
        .task { store.send(.task) }
    }

    /// "N of M devices" while a query is active, the plain inflected count
    /// otherwise. N counts *matches across the whole fleet*, not visible rows —
    /// a revealed ancestor is visible without being a match.
    private var subtitle: Text {
        let total = store.devices.count
        guard total > 0 else { return Text("") }
        guard !store.searchText.isEmpty else {
            return Text("^[\(total) device](inflect: true)")
        }
        return Text("\(store.matchCount) of ^[\(total) device](inflect: true)")
    }

    @ViewBuilder
    private var emptyState: some View {
        if !store.searchText.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        } else if store.isLoading {
            ProgressView()
        } else {
            ContentUnavailableView(
                "No Devices",
                systemImage: SidebarSymbol.devices,
                description: Text("Your fleet will appear here once it loads.")
            )
        }
    }
```

`import UI` is already present at the top of the file and covers
`RCReadoutSectionHeader`, `SelectableList`, `SelectableRow`, and `DeviceStatus`.

- [ ] **Step 2: Build the package and the app target**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -30
```

Expected: `Build complete!`. Then re-run the index symlink so LSP queries in
review resolve against this session's code:

```bash
cd app/Modules && ./scripts/link-index-store.sh
```

- [ ] **Step 3: Run the whole DevicesFeature test target**

```bash
cd app/Modules && swift test \
  --test-product DevicesFeatureTests --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events.jsonl
```

```bash
jq -s 'map(select(.kind=="event").payload) as $e
  | { started: ($e|map(select(.kind=="testStarted"))|length),
      failed:  ($e|map(select(.kind=="issueRecorded" and .issue.isFailure != false).testID)|unique),
      crashed: (($e|map(select(.kind=="testStarted").testID)) - ($e|map(select(.kind=="testEnded" or .kind=="testSkipped").testID))),
      completed: ($e|map(select(.kind=="runEnded"))|length) }' .build/events.jsonl
```

Expected: `failed` `[]`, `crashed` `[]`, `completed` `1`, `started` well above zero.

- [ ] **Step 4: Run the whole package**

Other targets do not import `DeviceListLayout`, but `UI` gained a file and
`DevicesFeature`'s public surface changed, so prove nothing else broke. Per the
`swift-test-event-stream` skill, a whole-package run under `swiftbuild` truncates
a shared output file — use one file per product and concatenate, or:

```bash
cd app/Modules && swift test --build-system native --disable-xctest \
  --event-stream-version 0 --event-stream-output-path .build/events-all.jsonl
```

Confirm every expected test module is present before trusting the result:

```bash
jq -r 'select(.kind=="test").payload.id | split(".")[0]' .build/events-all.jsonl | sort -u
```

Expected: the full list of the package's test targets, not one.

- [ ] **Step 5: Verify the interaction in the running app**

Launch the app (see the `run` skill) and check, in order:

1. The list opens at roots only — count the top-level rows; the fleet's 104
   devices should render as ~70.
2. Clicking a row's chevron **expands the host without also selecting the row**.
   Nested `Button`s inside `SelectableRow`'s own `Button` are the one interaction
   this plan cannot prove from a test. If the outer button also fires, replace
   the inner `Button` with `.onTapGesture` plus
   `.simultaneousGesture(TapGesture())`, or move the chevron outside the
   `SelectableRow` and into a sibling `HStack`.
3. The Needs Attention header sticks to the top while scrolling, and collapsing
   it hides its rows while keeping the header. If sticky headers misbehave over
   the collapsing `LazyVStack`, drop `pinnedViews: [.sectionHeaders]` — the spec
   accepts non-sticky headers as a graceful degradation with no model change.
4. Typing in the search field reveals a match nested inside a collapsed host, and
   clearing the field returns to the collapsed state (proving `expandedHosts` was
   not written).
5. Selecting a device, then typing a query that filters it out, leaves the
   inspector showing that device.
6. The subtitle reads "N of M devices" during a query and the plain inflected
   count otherwise.
7. The list reads correctly in light mode as well as dark
   (`.preferredColorScheme(.light)` in a preview, or the system appearance
   toggle).

- [ ] **Step 6: Commit**

```bash
git add app/Modules/DevicesFeature/Sources/DevicesView.swift
git commit -m "feat(devices): sectioned, searchable fleet list with sticky attention header"
```

---

## Stage 1 done-ness

Stage 1 is complete when all of the following hold:

- `swift test --test-product DevicesFeatureTests` reports zero failures, zero
  crashes, and a `runEnded` event.
- A whole-package run shows every test module present and green.
- The seven interaction checks in Task 10 Step 5 pass on the running app.
- The top level of the fleet list is roots only, and the Needs Attention section
  is absent when nothing is flagged.

Stage 2 (`DeviceGrouping`, the toolbar picker, Type / System / Mission / Flat,
readout headers on every section, `@Shared(.devicesListGrouping)`) is a separate
plan. Two shapes here are deliberately built to absorb it without rework:
`RCReadoutSectionHeader` already renders the composition bar every Stage 2
section needs, and `DeviceListLayout.sections(...)` gains a `grouping` parameter
as a single compiler-caught signature change.
