# Device List Organisation — Stage 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the grouping picker. The fleet list gains four alternative
organisations — Type, System, Mission, Flat — beside Stage 1's Carrier tree, each
with a collapsible readout header, and the choice persists across launches.

**Architecture:** `DeviceListLayout.sections(...)` gains a `grouping:` parameter
and branches once: `.carrier` keeps Stage 1's containment path untouched; every
other case flattens the tree and re-partitions the fleet by the device's own
attribute. The partition itself is a new pure file, `DeviceListGrouping.swift`,
in the same SwiftUI-free namespace. Needs Attention stays pinned above all
sections in every mode, and `collapsedGroups` — which Stage 1 honoured for the
attention section alone — now applies to every headered section.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), Composable Architecture, SQLiteData
(`@FetchAll`), Sharing (`@Shared(.appStorage)`), Swift Testing + CustomDump.

**Source spec:** `app/docs/superpowers/specs/2026-08-05-device-list-organisation-design.md`.
Stage 1 (`2026-08-05-device-list-organisation-stage1.md`) shipped; this plan is
Stage 2 and completes the design.

---

## Global Constraints

Stage 1's constraints carry over unchanged. Restated because they bind here too:

- **Never hard-code colours, spacing, or font sizes.** Use `DesignSystem.swift`
  tokens. This plan adds one token (`Font.rcSectionLabelMono`) rather than
  inlining `design: .monospaced` at the header.
- **No new colours.** Section status bars colour through `DeviceStatus.tone(for:)`.
- **Any system or location designation renders monospaced.** System-mode section
  titles *are* designations, so the header needs a monospaced title mode — this is
  the one reason `RCReadoutSectionHeader` changes at all.
- **Pure logic must NOT be a static or nested type on a SwiftUI `View`**
  (`.claude/memory/swiftui-view-statics-trap-in-tests.md`). `DeviceListGrouping.swift`
  has **no `import SwiftUI`**, same as the rest of the namespace.
- **Sections of flat entries, not a nested tree.** Flattened modes emit every row
  at `depth: 0`; nothing recurses in the view.
- **Nothing about selection, the inspector, or command dispatch changes.**
- **Running tests:** always scope with `--test-product`, read results from the
  event stream, never console text (`swift-test-event-stream` skill):

  ```bash
  cd app/Modules && swift test \
    --test-product DevicesFeatureTests \
    --disable-xctest \
    --filter '<TestSuiteTypeName>' \
    --event-stream-version 0 \
    --event-stream-output-path .build/events.jsonl
  ```

  `UI` changes are checked with `--test-product UITests` or, since `UI` has no
  behaviour tests for this control, by `swift build --build-tests`.
- **LSP setup, once per worktree, before any code work:**
  `cd app/Modules && swift build --build-tests` then `./scripts/link-index-store.sh`.
- **Commits go to local `main` or a worktree branch merged to `main`.** No PRs.

## Decisions this plan makes that the spec left open

The spec fixes Type-mode ordering ("count descending then display name") and says
Unknown sorts last. It says nothing about System and Mission ordering, or about
how a collapsed-but-non-empty section differs from an empty one. Settled here:

1. **Every grouped mode orders sections by count descending, then title**, with
   the catch-all bucket (`Unknown`, `Untagged`) last regardless of its count.
   One rule for all three modes; count-descending is what answers "where is the
   mass of the fleet".
2. **A section that is empty because it was filtered out is dropped; a section
   that is empty because it is collapsed keeps its header.** Stage 1 already does
   this for Needs Attention; Stage 2 generalises it, which means the collapse
   check must run *after* the search filter, not before.
3. **`expandedHosts` is never cleared by a grouping change.** Switching to Type
   and back to Carrier restores the operator's disclosure state, because
   flattened modes simply don't consult it.
4. **The picker is a toolbar `Menu` wrapping a `Picker`**, matching
   `LocationsListView`'s Sort/Filter control rather than inventing a second
   toolbar idiom.

---

## File Structure

**Created — `DevicesFeature/Sources/`**

| File | Responsibility |
| --- | --- |
| `DeviceGrouping.swift` | The `DeviceGrouping` enum, its picker label and symbol. Pure; `Foundation` only. |
| `DeviceListGrouping.swift` | `DeviceListLayout.buckets(for:grouping:hosts:)`, the system roll-up with host inheritance, and `groupedSections(...)`. **No `import SwiftUI`.** |

**Modified**

| File | Change |
| --- | --- |
| `DevicesFeature/Sources/DeviceListModel.swift` | `DeviceListHeader` gains `titleIsDesignation`. |
| `DevicesFeature/Sources/DeviceListLayout.swift` | `sections(...)` gains `grouping:` and branches; the fleet section honours `collapsedGroups`. |
| `DevicesFeature/Sources/DevicesFeature.swift` | `State` gains `@Shared(.devicesListGrouping) grouping`; the `SharedKey` default; `sections` passes it through. |
| `DevicesFeature/Sources/DevicesView.swift` | Toolbar grouping picker; header passes `titleIsDesignation`. |
| `UI/Sources/DesignSystem.swift` | Adds `Font.rcSectionLabelMono`. |
| `UI/Sources/RCReadoutSectionHeader.swift` | Adds `isTitleDesignation` — renders the title monospaced, unkerned, un-uppercased. |

**Tests — `DevicesFeature/Tests/`**

`DeviceListGroupingTests.swift` (new), plus cases appended to
`DeviceListSectionsTests.swift` and `DevicesFeatureTests.swift`.

`Package.swift` needs **no change**.

---

## Task 1: `DeviceGrouping` and its persisted default

**Files:**
- Create: `app/Modules/DevicesFeature/Sources/DeviceGrouping.swift`
- Modify: `app/Modules/DevicesFeature/Sources/DevicesFeature.swift` (the `SharedKey` extension only)
- Test: `app/Modules/DevicesFeature/Tests/DeviceListGroupingTests.swift`

**Interfaces:**
- Produces `public enum DeviceGrouping: String, CaseIterable, Identifiable, Sendable`
  — `carrier`, `type`, `system`, `mission`, `flat` — with `label`, `symbol`, `id`.
- Produces `extension SharedKey where Self == AppStorageKey<DeviceGrouping>.Default`
  with `devicesListGrouping`, defaulting to `.carrier`.

The unstructured case is `flat`, **not** `none` — a `DeviceGrouping.none` shadows
`Optional.none` at every optional-handling site. The app-storage key contains no
`.` or `@`, which are invalid in app-storage keys.

- [ ] **Step 1: Write the failing enum test** — `allCases` is exactly the five
  cases in picker order (`carrier, type, system, mission, flat`), raw values are
  the lowercase names (they are persisted, so a rename is a silent reset), and
  each case has a non-empty label and symbol.
- [ ] **Step 2: Run it and watch it fail** (`cannot find 'DeviceGrouping'`).
- [ ] **Step 3: Create `DeviceGrouping.swift`.**
- [ ] **Step 4: Add the `SharedKey` extension** to `DevicesFeature.swift`.
- [ ] **Step 5: Run the test green.**
- [ ] **Step 6: Commit** — `feat(devices): the grouping dimension and its persisted default`

---

## Task 2: The partition — buckets per grouping

**Files:**
- Create: `app/Modules/DevicesFeature/Sources/DeviceListGrouping.swift`
- Test: `app/Modules/DevicesFeature/Tests/DeviceListGroupingTests.swift` (append)

**Interfaces:**

```swift
/// One section a grouping mode partitions the fleet into.
struct GroupBucket: Equatable {
    var id: String              // "type:ftl_relay", "system:ATIANFU", "mission:auto:survey"
    var title: String
    var isDesignation: Bool     // title renders monospaced
    var sortsLast: Bool         // the Unknown / Untagged catch-all
}

static func buckets(for: Device, grouping: DeviceGrouping, hosts: [String: Device]) -> [GroupBucket]
static func systemKey(for: Device, hosts: [String: Device]) -> String?
```

`buckets` returns an array because Mission is a **facet**: a device carrying two
tags appears under both, and the headers then sum above the fleet count. Every
other mode returns exactly one bucket.

`systemKey` rolls a location up to its first designation segment through
`GameModels.TravelItinerary.systemDesignation(_:)` — the existing helper, not a
second implementation — and **inherits the host's system when the device has no
location of its own**, walking the host chain with a seen-set so a containment
cycle terminates. A drone stowed in a vessel is wherever that vessel is.

- [ ] **Step 1: Write the failing bucket tests.** Cover:
  - Type buckets on `deviceType`, titled with `DevicePresentation.displayName`.
  - System buckets roll `ATIANFU-1-L4` and `ATIANFU-BELT-1` both to `ATIANFU`.
  - A locationless device inherits its host's system, through two levels
    (drone → controller → vessel).
  - A locationless, hostless device buckets to `system:unknown`, `sortsLast`.
  - A locationless device whose host chain cycles terminates and buckets Unknown.
  - Mission buckets one per tag; a two-tag device returns two buckets; an
    untagged device returns `mission:untagged`, `sortsLast`.
  - Type/Mission buckets are not designations; System buckets are.
  - Flat and Carrier are not routed through `buckets` (the entry point branches
    before it), asserted by the sections tests in Task 3 rather than here.
- [ ] **Step 2: Run and watch it fail.**
- [ ] **Step 3: Implement `DeviceListGrouping.swift`.**
- [ ] **Step 4: Run green.**
- [ ] **Step 5: Commit** — `feat(devices): partition the fleet by type, system, and mission`

---

## Task 3: `sections(grouping:)`

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/DeviceListModel.swift`
- Modify: `app/Modules/DevicesFeature/Sources/DeviceListGrouping.swift`
- Modify: `app/Modules/DevicesFeature/Sources/DeviceListLayout.swift`
- Test: `app/Modules/DevicesFeature/Tests/DeviceListSectionsTests.swift` (append)

**Interfaces:**

```swift
public static func sections(
    fleet: [Device],
    attentionDirectives: [Directive],
    grouping: DeviceGrouping,
    searchText: String,
    expandedHosts: Set<String>,
    collapsedGroups: Set<String>
) -> [DeviceListSection]
```

`DeviceListHeader` gains `public var titleIsDesignation: Bool` (defaulted in the
initialiser, so the attention header's construction is unchanged).

The flattened path, in order: filter by query → split flagged from the rest →
attention section from the flagged, sorted by `attentionPrecedes` → one section
per bucket over the rest, each ordered count-descending then title with the
catch-all last. Every entry is `depth: 0`, `childCount: 0`, `isExpanded: false`,
badged with `badge(for:parentCode: nil)` — its highest-precedence relation, so
containment stays legible without dictating position.

- [ ] **Step 1: Write the failing sections tests.** Cover:
  - `.carrier` output is **byte-identical** to Stage 1's — the existing suite's
    helper gains `grouping: .carrier` and every existing expectation still holds.
  - `.type` gives one section per type, ordered count-descending then display
    name, each headered with the right count and status shares.
  - `.system` titles are designations (`titleIsDesignation == true`) and Unknown
    sorts last even when it outnumbers a named system.
  - `.mission` puts a two-tag device in both sections, and the headers' counts sum
    above the fleet size — asserted explicitly, since it's the documented
    exception to "partitions the fleet exactly once".
  - `.flat` is one unheadered section holding the whole fleet in sort order, with
    no containment structure (every `depth` 0, every `childCount` 0).
  - Needs Attention is pinned above the groups in **every** mode, and a flagged
    device is absent from its own group section.
  - A collapsed group keeps its header and contributes no entries; `orderedIDs`
    skips them.
  - A search that empties a section drops it; a search that empties every section
    yields no sections at all.
  - Switching grouping does not consult `expandedHosts` in flattened modes (same
    output with the set full and empty).
- [ ] **Step 2: Run and watch it fail.**
- [ ] **Step 3: Add `titleIsDesignation` to `DeviceListHeader`.**
- [ ] **Step 4: Implement `groupedSections(...)` and branch `sections(...)`.**
  Update the doc comment that currently says `collapsedGroups` is honoured for
  the attention section alone — Stage 2 is the "if Stage 2 ever adds one" case it
  names, so the fleet section now checks membership too.
- [ ] **Step 5: Run the whole `DevicesFeatureTests` product green**, not just the
  new suite — Task 3 changes a signature every Stage 1 suite calls.
- [ ] **Step 6: Commit** — `feat(devices): sections(grouping:) over the four flattened dimensions`

---

## Task 4: Feature state and the persisted choice

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/DevicesFeature.swift`
- Test: `app/Modules/DevicesFeature/Tests/DevicesFeatureTests.swift` (append)

**Interfaces:** `State.grouping` is `@ObservationStateIgnored @Shared(.devicesListGrouping)`,
following the `@FetchAll` idiom already in this state. It is driven by the
existing `BindingReducer()` — no bespoke action. `State.sections` passes it to
the layout.

- [ ] **Step 1: Write the failing reducer tests** — a `binding(\.grouping)` change
  reshapes `sections`; the grouping survives a state round-trip; the two
  disclosure toggles behave the same in a flattened mode as in Carrier.
- [ ] **Step 2: Run and watch it fail.**
- [ ] **Step 3: Wire `State.grouping` through.** Verify observation still fires on
  a grouping change — the `@ObservationStateIgnored` + `@Shared` pairing is the
  spec's named risk.
- [ ] **Step 4: Run the whole product green.**
- [ ] **Step 5: Commit** — `feat(devices): the grouping choice lives in state and persists`

---

## Task 5: The picker and the monospaced header title

**Files:**
- Modify: `app/Modules/UI/Sources/DesignSystem.swift`
- Modify: `app/Modules/UI/Sources/RCReadoutSectionHeader.swift`
- Modify: `app/Modules/DevicesFeature/Sources/DevicesView.swift`

**Interfaces:** `RCReadoutSectionHeader.init` gains
`isTitleDesignation: Bool = false`. When true the title renders in
`Font.rcSectionLabelMono` at its own case, without the `.uppercased()` and
`kerning(1)` the label style applies — a designation is already uppercase, and
kerning a monospaced code fights the font.

- [ ] **Step 1: Add `Font.rcSectionLabelMono`** to `DesignSystem.swift`, beside
  `rcSectionLabel`.
- [ ] **Step 2: Add `isTitleDesignation` to `RCReadoutSectionHeader`**, defaulted
  so the existing call site is unchanged.
- [ ] **Step 3: Pass `header.titleIsDesignation`** from `DevicesView`.
- [ ] **Step 4: Add the toolbar picker** — a `Menu` in
  `ToolbarItem(placement: .primaryAction)` wrapping
  `Picker("Group by", selection: $store.grouping)` over `DeviceGrouping.allCases`,
  labelled with each case's symbol. Placed before the existing refresh button.
- [ ] **Step 5: Build the app target** to prove the SwiftUI compiles
  (`xcodebuild` of the app scheme; the package alone doesn't cover `DevicesView`'s
  toolbar type-checking beyond `swift build`).
- [ ] **Step 6: Commit** — `feat(devices): the grouping picker and monospaced system headers`

---

## Task 6: Verification pass

- [ ] **Step 1:** `swift test --test-product DevicesFeatureTests` — whole product,
  read from the event stream, 0 failures.
- [ ] **Step 2:** `swift build --build-tests` clean.
- [ ] **Step 3:** `./app/scripts/check-comments.sh` over the touched files.
- [ ] **Step 4:** Confirm against the spec's Testing section that every listed
  Grouping case has a test: each dimension partitions exactly once (Mission's
  multi-tag duplication excepted), system roll-up, host inheritance, the Unknown
  bucket, section ordering, and sort within a section.

## Risks

- **Sticky headers over collapsing sections** was Stage 1's named risk and is
  unchanged, but Stage 2 multiplies the header count from one to as many as
  seventeen (Type mode). If pinning misbehaves at that count, dropping
  `pinnedViews` degrades to non-sticky headers with no model change.
- **A raw-value rename silently resets the persisted choice.** The enum's raw
  values are storage; the Task 1 test pins them for that reason.
- **`@Shared` inside `@ObservableState`** — the spec's own flagged risk. Follow
  the `@ObservationStateIgnored` idiom already used for `@FetchAll` here.
</content>
