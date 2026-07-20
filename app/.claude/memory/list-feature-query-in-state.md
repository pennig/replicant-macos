---
name: list-feature-query-in-state
description: "Standard for list features — SQLiteData @FetchAll lives in TCA state, not the view; view is a pure renderer."
metadata: 
  node_type: memory
  type: project
  originSessionId: 04937c21-7918-469f-be3c-af86906f9dee
---

The standard for every list feature (established 2026-07-02, applied to Blueprints, Replicants, Devices, PrintQueue, Messages): the SQLiteData query lives in the reducer's `@ObservableState`, and the view is a pure renderer of `store.*`. No `@FetchAll`/`@FetchOne` in the view.

**Why:** view-local `@FetchAll(X.none)` + `.task(id:)` `.load` re-fetches asynchronously whenever the view is recreated (e.g. a parent re-render), snapping to the empty default first — a visible "flash of no content". Holding the query in state (which survives view lifetimes and tab switches) eliminates that, keeps filter/sort selections persistent across sidebar tabs for free, and makes the query testable/state-driven.

**How to apply:**
- In State: `@ObservationStateIgnored @FetchAll(Table.order { ... }) public var rows: [Row]` (seed with the real ordered query, never `.none`). `@ObservationStateIgnored` because `@FetchAll` drives its own observation — and it means the fetched value doesn't trip exhaustive `TestStore` assertions.
- Static filters/derivations (e.g. grouping, an in-memory predicate): a synchronous computed `var` on State (see `PrintQueueFeature.printers`, `ReplicantsFeature.sections`). Fine for small tables.
- Search/filter/sort as SQL (needed for large tables like Locations ~5,770): keep `searchText`/sort in state, and reload the query from an effect — `return .run { [reader = state.$rows, search = state.searchText] _ in try await reader.load(Table.where { ... }.order { ... }, animation: .default) } catch: { _, _ in }`. `.load` swaps the observation in place (keeps prior rows until new arrive → no flash). Persist durable filter/sort choices with `@Shared(.appStorage(...))`; search text stays plain state.
- Detail panes must ALSO derive the selected item from state — do NOT use a view-local `@FetchOne(.none)` + `.task(id: selection)`. Add a computed `selected…` on State that looks the item up in the observed collection (`directory.first { … }`, `devices.first { … }`, `systemDetails.first { … }?.system()`); the detail renders `store.selected…`. (A static `@FetchAll(X.all)` in the detail — like Blueprints — is also fine since it never resets to empty.)

**Tests:** State now touches `defaultDatabase` at construction, so any test building `State()` must do so within a dependency scope. `TestStore(initialState: X.State()) { } withDependencies: { $0.defaultDatabase = db }` works (initialState is evaluated in-scope). For a State built standalone (`var s = X.State(); s.foo = ...`), wrap in `withDependencies { $0.defaultDatabase = db } operation: { ... return TestStore(...) }`.

**The regression this caused (and the REAL fix):** the symptom was a detail pane briefly showing the item then reverting to its "Nothing Selected" empty state (list still shows the row selected). Cause = the detail's view-local `@FetchOne(X.none)` + `.task(id: selection)`: the detail view gets re-created when the store re-emits after a DB write (details fetch, travel, hydration), which resets the `@FetchOne` to its `.none` (nil) default, and `.task(id: selection)` never reloads because `selection` is unchanged. Fix = derive the selected item from state (above). The `List(selection:)` binding is plain `$store.selected…` — the LIST selection was never the bug. (An earlier `hardenedSelection`/`NSTableView`-clears-selection theory was WRONG and was reverted; don't reintroduce it.)

Grounded in the pfw-sqlite-data skill's "Dynamic queries" + observable-model guidance. Applied to LocationsFeature (disclosure tree) via a state-owned `@Fetch` (`LocationForest`) that builds the tree off-main inside `fetch`. Not applied to the MainFeature sidebar chrome.
