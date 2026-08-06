# Device list organisation — design

**Date:** 2026-08-05
**Status:** Approved, ready for planning
**Module:** `DevicesFeature` (plus one shared control change in `UI`)

## Problem

The fleet master list is a flat `SelectableList` sorted by `deviceType`, with no
search and no filter. At 104 devices it no longer answers the three questions it
is asked:

1. **Find one specific device** — locate a known row by code, type, or place.
2. **Triage** — which handful of devices need me right now.
3. **Work a cohort** — "all my survey drones", "everything at ATIANFU", "the
   tendMesh fleet", "what's aboard the Heaven Vessel".

## The fleet as it stands (2026-08-05, live DB)

Design decisions below are argued from this, not from a hypothetical fleet.

| Dimension | Reality |
| --- | --- |
| Total | 104 devices |
| Type | `ftl_relay` 53, `survey_drone` 8, `surge_plate` 7, `ftl_beacon` 6, `transport_hauler` 5, then 12 types in ones and twos (17 distinct) |
| Status | `relaying` 42, `stowed` 20, `idle` 18, `inactive` 10, `monitoring` 6, `coordinating` 4, `tracking` 2, `travelling` 1, `surging` 1 |
| Location | 51 distinct sites, most holding exactly one device; AINALRAM-BELT-1 (19), ATIANFU-BELT-1 (7), ATIANFU-1-L4 (7); 22 devices have no location |
| Containment | 20 stowed, 13 controlled, 1 attached — 34 devices, under 9 distinct hosts |
| Tags | 24 devices tagged, every one carrying **exactly one** tag: `auto:survey` 8, `auto:salvage` 8, `taxi` 5, `auto:haul` 2, `auto:tendmesh` 1 |
| Attention | 3 devices below 50% operational capacity, 1 out of control range, 1 directive in `needsAttention` (`commandRejected`) |

Two facts drive the design:

- **Half the list is deployed FTL relays** sitting in `relaying`, one per system,
  that are rarely touched individually. They must stay reachable, but they should
  be collapsible into one line.
- **The containment tree is genuinely two levels deep, and controller-first is the
  correct reading.** In all 10 stowed-and-controlled cases the AMI controller is
  stowed in the very carrier its drones are stowed in. Under stowed-first
  precedence, Heaven Vessel `F2908E6E` renders its AMI Survey Controller and six
  survey drones as seven flat siblings. Under controller-first it renders
  Vessel → AMI Survey Controller → 6 drones, which is the structure the operator
  actually thinks in.

## Goals

- Locate any device in a few keystrokes.
- Surface the devices that need attention without hunting.
- Reorganise the fleet along any of four axes on demand, and read a collapsed
  group well enough to know whether to open it.
- Change nothing about selection, the inspector, or command dispatch.

## Non-goals

Deliberately excluded; each is defensible later, none is needed to fix the stated
problem.

- Bulk/multi-selection actions. Group headers are **readouts**, not command
  targets. Selection stays single, and the inspector is untouched.
- Saved or named views.
- A separate sort picker (sort within a group is fixed, see below).
- A compact row density, or a ⌘K jump palette.

## Architecture

### `DeviceListLayout` — a pure, SwiftUI-free namespace

All organisation logic lives in a new `DeviceListLayout` enum namespace in
`DevicesFeature`, with no SwiftUI import. Pure logic hung off a `View` as a
static traps with signal 5 under `swift test` (see the
`swiftui-view-statics-trap-in-tests` note), and this logic must be heavily
unit-tested.

One entry point:

```swift
DeviceListLayout.sections(
    fleet: [Device],
    attentionDirectives: [Directive],
    grouping: DeviceGrouping,
    searchText: String,
    expandedHosts: Set<String>,
    collapsedGroups: Set<String>
) -> [DeviceListSection]
```

### Output model

```swift
public struct DeviceListSection: Identifiable, Equatable {
    public var id: String            // "attention", "all", "type:ftl_relay", "system:ATIANFU", …
    public var header: DeviceListHeader?   // nil ⇒ unheadered (Carrier / Flat modes)
    public var entries: [DeviceEntry]      // already flattened; empty when collapsed
}

public struct DeviceEntry: Identifiable, Equatable {
    public var device: Device
    public var depth: Int                  // Carrier mode only; 0 elsewhere
    public var childCount: Int             // 0 ⇒ not a host
    public var isExpanded: Bool
    public var host: HostRelation?         // the relationship badge
    public var attention: [AttentionFlag]
    public var id: String { device.deviceCode }
}

public enum HostRelation: Equatable {
    case controlled(by: String)   // controllerDeviceCode
    case stowed(in: String)       // stowedInDeviceCode
    case attached(to: String)     // attachedToDeviceCode
}

public enum AttentionFlag: Equatable {
    case damaged(capacity: Double)
    case outOfControlRange
    case directive(DirectiveAttentionReason)
}
```

**Sections of flat entries, not a nested tree.** Depth is a rendering hint on an
already-flattened array; nothing recurses in the view. This is the shape the
Locations catalog had to adopt — `DisclosureGroup`/`children:` produced a generic
metadata and ARC storm at scale (see `locations-list-flatten-perf`). Keeping real
`Section`s (rather than one wholly flat array) is what lets the list keep
`pinnedViews: [.sectionHeaders]` and its sticky Liquid Glass headers.

`orderedIDs` for the list is `sections.flatMap(\.entries).map(\.id)`. Because a
collapsed host contributes no entries and a collapsed group contributes none,
arrow-key navigation skips hidden rows by construction rather than by a second
rule that could drift.

### No new list primitive

`SelectableList` already provides everything needed: the custom-content
initialiser taking `selection`, `orderedIDs`, `style`, and `pinnedViews`, plus
`SelectableRow` for participation in selection and scroll-to-selection. The
built-in `SelectableSection` convenience renders a title-only header, so the
readout header is supplied through the custom-content path instead. `UI` gains
only the new header view.

## Grouping

The picker reads **Carrier · Type · System · Mission · Flat**, defaulting to
Carrier.

```swift
public enum DeviceGrouping: String, CaseIterable, Sendable {
    case carrier, type, system, mission, flat
}
```

The unstructured case is named `flat`, not `none` — a `DeviceGrouping.none` would
shadow `Optional.none` at every site that handles an optional grouping and is a
standing source of inference errors.

**Carrier mode nests; every other dimension flattens the tree and re-partitions
by the device's own attribute.** These are alternative organisations of the same
fleet, not composable layers. If nesting persisted underneath grouping, "group by
Type" would show two of the eight survey drones with the other six buried inside
a carrier in a different section — which defeats the purpose of grouping by type.
In flattened modes each row carries its host as a badge, so containment stays
legible without dictating position.

### Carrier (default)

- One unheadered section containing the containment forest, flattened with depth.
- Host precedence: **`controllerDeviceCode` → `stowedInDeviceCode` →
  `attachedToDeviceCode`**. The non-winning relationship renders as the row's host
  badge, so nothing is lost.
- A host reference that does not resolve to a device in the fleet promotes the
  child to top level. (Zero orphans today, but the guard is cheap and the fleet
  syncs incrementally.)
- A visited-set guards cycles; a device already placed is never placed twice.
- Depth beyond 2 clamps its indent.
- **Hosts default collapsed.** `expandedHosts` is a `Set<String>` of host codes,
  so the empty default gives the collapsed-everywhere state. Top level opens at
  70 rows instead of 104.

### Type

One section per `deviceType`, ordered by count descending then display name. The
53 relays become one collapsible line; the twelve types with one or two members
stop competing with them.

### System

Location rolled up to the first designation segment, so `ATIANFU-1-L4` and
`ATIANFU-BELT-1` both file under `ATIANFU` and 51 sites collapse to far fewer
systems. A device with no location **inherits its host's** — a drone in a vessel
is wherever that vessel is, which is the right answer for all 22 locationless
devices. Genuinely locationless and hostless falls to an "Unknown" section, sorted
last. Section titles render in a mono token, per the project rule that a
designation is always monospaced.

### Mission

One section per distinct tag, plus "Untagged". Every tagged device carries
exactly one tag today, so this is a clean partition. A device carrying two tags
appears under both; the headers then sum above the fleet count, which is accepted
as the honest rendering of a facet.

### Flat

Sorted, unheadered, no containment structure. The escape hatch.

### Sort within a section

Fixed: type display name, then device code. No sort picker. (Attention is *not* a
sort key here — attention devices are promoted out of these sections entirely, so
sorting on it would be dead logic.) The Needs Attention section has its own order:
out-of-control-range first, then damaged ascending by capacity, then
directive-flagged, then device code.

## Search

- A `.searchable` field on the content column, alongside the existing refresh
  button.
- Per-device haystack: `deviceCode`, `DevicePresentation.displayName(deviceType)`,
  the raw `deviceType`, `location`, `locationName`, `tags`, and `statusBase`.
- The query splits on whitespace; **every term must match some field** (AND across
  terms, OR across fields), case- and diacritic-insensitive. So `survey ATIANFU`
  narrows as expected.
- **In Carrier mode, a device is retained if it matches or any descendant
  matches**, and ancestors of a match are forced expanded for the duration of the
  query without mutating `expandedHosts`. A match is never unreachable behind a
  collapsed host.
- Filtering runs before grouping; sections left empty are dropped.
- Search never disturbs the inspector: `State.selectedDevice` already resolves
  against the full `devices` array rather than the visible list, so a selected
  device that filters out keeps its detail pane.
- No results ⇒ `ContentUnavailableView.search(text:)`. While a query is active the
  navigation subtitle reads "N of M devices" (M being the whole fleet), reverting
  to the existing inflected device count when the query is cleared.

## Needs Attention

A pinned section above all others in every grouping mode, hidden when empty,
collapsible (defaults expanded).

A device qualifies if **any** of:

- `operationalCapacity < 50` — damaged. (3 devices today. The threshold is a named
  constant; 100 would flag 17 and be noise.)
- `isOutOfControlRange` — i.e. `detail.in_control_range == false`. (1 today.)
- A directive in `needsAttention` covers it, joined by
  `directive.deviceCode == device.deviceCode`, or
  `directive.controllerCode == device.deviceCode`, or
  `directive.fleetTag` being one of `device.tags`.

The directives come from a new query in `State`, following the `BobnetFeature`
idiom — `DirectiveStatus` is already `QueryBindable`:

```swift
@ObservationStateIgnored
@FetchAll(Directive.where { $0.status.eq(DirectiveStatus.needsAttention) })
public var attentionDirectives: [Directive]
```

**Devices are promoted into the section, not duplicated** — they leave their
normal position and bring their containment children with them. The set is small
by construction (4 devices plus the `commandRejected` directive's coverage today),
so promotion reads as triage rather than as rows going missing.

Promotion in Carrier mode needs one explicit rule, since a flagged device may sit
anywhere in the tree: **a flagged device is lifted out at whatever depth it sat,
taking its own subtree with it, and re-rooted at depth 0 of the attention
section.** Its former host stays where it is with its `childCount` reduced
accordingly. A flagged device that is itself a host therefore appears once, at the
top, with its children under it — never in both places.

Each row shows its reason as a short label; the directive reason uses the existing
`DirectiveAttentionReason` display text rather than new copy.

## Presentation

### Row

The existing `DeviceRow` keeps its shape — glyph tile, capacity bar, display name,
mono device code, status badge, location — and gains:

- a leading indent proportional to `depth` (Carrier mode),
- a disclosure chevron and child count when `childCount > 0`,
- an attention dot when `attention` is non-empty,
- a host badge naming the non-winning relationship or, in flattened modes, the
  host,
- a small tag chip when tagged.

### Group header

Title, member count, and a thin stacked bar of the section's status distribution
coloured through the existing `DeviceStatus.tone(for:)` taxonomy — no new colours,
per the design-system rule, and data-viz forward per the house style. A damaged
marker appears when any member is below the capacity threshold. This is what makes
a collapsed 53-relay section still worth reading.

## Feature state, actions, persistence

Following the TCA and Sharing guidance:

```swift
@ObservationStateIgnored
@Shared(.devicesListGrouping) public var grouping: DeviceGrouping

public var searchText = ""
public var expandedHosts: Set<String> = []      // empty ⇒ all hosts collapsed
public var collapsedGroups: Set<String> = []    // empty ⇒ all groups expanded
```

The two disclosure sets are asymmetric on purpose: each defaults to the desired
state at an empty set, so neither needs seeding.

The persisted default is declared type-safely rather than as a raw string at the
call site, and the key contains **no `.` or `@`** (invalid in app-storage keys):

```swift
extension SharedKey where Self == AppStorageKey<DeviceGrouping>.Default {
    static var devicesListGrouping: Self {
        Self[.appStorage("devicesListGrouping"), default: .carrier]
    }
}
```

`searchText` and `grouping` are driven by the existing `BindableAction` /
`BindingReducer()` already on the feature — no bespoke actions. Only the
disclosure gestures need real cases, named for the gesture rather than the logic:

```swift
case groupDisclosureToggled(String)
case hostDisclosureToggled(String)
```

Collapse state is in-memory only; the grouping choice persists across launches.

The view stays a pure renderer: `State` exposes a derived
`sections: [DeviceListSection]` computed from the observed fleet, matching the
established "list query in state, view is a pure renderer" standard.

## Staging

**Stage 1 — Carrier mode, search, attention.** `DeviceListLayout` with Carrier
grouping hardwired, hosts collapsed by default, the search field, the Needs
Attention pin, and the row changes. Independently shippable and, on its own, drops
the top level from 104 rows to 70 and answers "find one specific device"
outright.

**Stage 2 — the grouping picker.** Type, System, Mission, and Flat dimensions, the
toolbar picker, the readout headers, and persistence. Lands on a list that is
already 30% shorter.

## Testing

`DeviceListLayout` is pure functions, so the substance is unit-tested directly,
using `expectNoDifference` from CustomDump. The test target must not re-link
anything `DevicesFeature` already links.

- **Search** — single term, multiple terms AND-ing, each haystack field, case and
  diacritic insensitivity, no-match.
- **Containment** — controller-first precedence on the real stowed-and-controlled
  shape; the two-level Vessel → Controller → drones tree; unresolved host promotes
  to top level; a cycle terminates and places each device once; depth clamping.
- **Collapse** — a collapsed host contributes no entries; `orderedIDs` equals the
  visible order exactly; hidden rows are absent from it.
- **Search × collapse** — a match on a child of a collapsed host is revealed, and
  `expandedHosts` is not mutated by the reveal.
- **Attention** — each of the three predicates independently; the three directive
  join paths; promotion removes the device from its normal section; the section is
  absent when empty.
- **Grouping** — each dimension partitions the fleet exactly once (Mission's
  multi-tag duplication being the documented exception); system roll-up from site
  designations; a locationless device inheriting its host's system; the Unknown
  bucket; section ordering; sort within a section.

Reducer tests cover the binding-driven search and grouping, the disclosure
toggles, and that the persisted grouping survives a state round-trip.

## Risks

- **Sticky headers + collapse.** Pinned section headers over a `LazyVStack` whose
  content changes size on collapse is the least-proven interaction here. If it
  misbehaves, dropping `pinnedViews` degrades gracefully to non-sticky headers
  with no model change.
- **Promotion surprise.** An attention device leaving its group is intentional but
  is the one behaviour most likely to want reversing after living with it. The
  layout function takes it as a branch, so switching to duplication is a local
  change.
- **`@Shared` inside `@ObservableState`.** Follow the `@ObservationStateIgnored`
  idiom already used for `@FetchAll` in this feature, and verify observation still
  fires on a grouping change.
