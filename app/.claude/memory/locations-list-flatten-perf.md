---
name: locations-list-flatten-perf
description: "Locations catalog list perf — flatten-to-visible-rows over a flat List beats children:/DisclosureGroup at ~5,770 systems."
metadata: 
  node_type: memory
  type: project
  originSessionId: c6696e79-9e3c-468a-b6d8-9b2a9ddb51ea
---

The Locations catalog list (`LocationsListView`, ~5,770-system census) had a ~1s stall on load, filter toggle, AND single-system expand/collapse.

**Diagnosis (profiled):** empty SwiftUI Instruments lanes but a full Time Profiler whose self-time was diffuse Swift-runtime plumbing — `getCache` / `getGenericContext` (generic type-metadata instantiation), `swift_retain`/`swift_release` (ARC churn), `___chkstk_darwin` (large/deep stack frames). That signature = SwiftUI reconstructing a large graph of nested generic view values, NOT SQLite/data (the forest is already built off-main by `@Fetch`), NOT AppKit layout. Cost scaled with the top-level row count, not the expand.

**What did NOT work:** swapping the flat `ForEach`-of-`DisclosureGroup`s for the native `List(_:children:selection:)` — identical cost. Both feed 5,770 heavy recursive `LocationNode`s into the List's outline machinery.

**Fix:** flatten the tree to a linear array of only currently-visible rows (lightweight `LocationFlatRow`: id/depth/hasChildren/isExpanded) and render it in a `LazyVStack`-based list. Own disclosure: a chevron `Button` toggles `expanded: Set<String>` in `LocationsFeature.State`; `LocationTree.flatten(_:expanded:)` (pure, SwiftUI-free, testable) walks in render order skipping collapsed subtrees. Expand splices a few rows instead of rebuilding a nested generic graph. Same idea as `RawAPIFeature`'s `JSONTreeView`.

**Container = AppKit `NSTableView` wrapped in an `NSViewRepresentable` (`LocationsOutlineView`).** macOS forces a choice in pure SwiftUI: cell recycling (`List`/`Table`) XOR row insert/remove animation (`LazyVStack`). The census is 10,000+ systems so recycling is required, but `List` will NOT animate row diffs (tried every combo: `List(rows,selection:)` and `List(selection:){ForEach}` × `send(_:animation:)`/`.animation(value:)`/explicit row `.transition` — none animated). `NSTableView` does BOTH natively (`insertRows/removeRows(withAnimation:.slideDown/.slideUp)` + cell reuse), so the list drops to AppKit (CLAUDE.md sanctions this for UX-critical cases). Rejected along the way: `List(_:children:)`/`DisclosureGroup` (the perf storm), `SelectableList`/`LazyVStack` (animates but no recycling).

**How the wrapper works** (store stays source of truth — it just consumes `rows`/`selection`/`onToggle`, no reducer change):
- Rows are the flattened `[LocationFlatRow]`; each cell hosts SwiftUI `LocationRow` via `NSHostingView`, styled `rcSidebarRow(isSelected:style:.inline)` (added a style-explicit overload in UI/ListStyles because the `\.selectableListStyle` env key is internal).
- Hosting view overrides `hitTest`→nil (click-through) so the table owns selection + keyboard nav; the table's `mouseDown` toggles expansion when the click is in the chevron's x-region (from row depth via `LocationRowMetrics`), else selects.
- `updateNSView` diffs old vs new rows by id: contiguous expand/collapse → animated insert/remove; wholesale (filter/sort, delta > animationLimit 400 or common rows reordered) → `reloadData`.
- `selectionHighlightStyle = .none` (row draws its own `.inline` selection); a guard flag breaks the store↔table selection round-trip. Fixed `rowHeight = 44` (tunable in `LocationRowMetrics`).

**Why:** at scale, SwiftUI's outline builders (`children:`, nested `DisclosureGroup`) pay O(total nodes) in generic-metadata/ARC per content mutation; a flat List over cheap flattened rows is lazy and only touches visible cells.

**How to apply:** for a large hierarchical macOS list, flatten to visible rows and keep expansion in the store (`LocationTree.flatten` + `expanded: Set`). Rendering choice by requirement: small list → `SelectableList`/`LazyVStack` (animates, no recycling). Large list, no animation needed → `List(selection:){ForEach(rows)}` (recycling). Large list AND expand/collapse animation → wrap `NSTableView` (recycling + native row animation; pure SwiftUI can't do both on macOS). Don't reach for `List(_:children:)`/`DisclosureGroup` at scale (the perf storm). See [[locations-catalog-feature]], [[list-feature-query-in-state]], [[sidebar-feature]].
