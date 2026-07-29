---
name: system-detail-persist-choke-point
description: "Never SystemDetail.upsert directly — go through SystemDetail.persist, which also stamps stars.fullyScannedAt; and StarSystem.isFullyScanned is the one scan-completeness definition"
metadata:
  node_type: memory
  type: project
---

**Never write `SystemDetail.upsert` in production code.** Use
`SystemDetail.persist(system:at:in:)` (UniverseModels, `SystemScanState.swift`),
which upserts the blob *and* stamps `stars.fullyScannedAt` in the same
transaction. As of 2026-07-29 there is exactly one `SystemDetail.upsert` in
non-test code — the one inside `persist`. A second one is a bug.

`StarSystem.isFullyScanned` (also `SystemScanState.swift`) is the single
definition of "completely surveyed": every planet scanned against a positive
total, plus every moon whenever a positive moon total is reported. Unknown counts
are never full. `SurveyRun.isFullyScanned(_:)` is now a thin forwarder that only
adds `nil` → `false`.

**Why:** `stars.fullyScannedAt` was declared, documented, and read by
`LiveStar.scanState` as the `.full` survey tier — and written by *nothing*. It was
null on all 14,122 rows of the live database, so the star map could never render a
system as fully scanned, and the survey-target picker had no cheap way to ask
whether a system was done. Nine separate production paths persisted a
`SystemDetail`; a stamp bolted onto one of them would just have grown new holes.

**How to apply:**
- Two triggers keep the column current, both counts-based: any catalog write that
  completes a system (`scan.completed` via `ingestScanResult`, the
  `ami.survey.digest` channel via `ingestSurveyScans`, any hydrate), and
  `directive.completed` for `survey_system`, which `LocationsIngestion.catalogRoute`
  answers by re-reading the system so the counts decide. A completion is
  deliberately NOT taken as evidence on its own — `SurveyRun.confirm` already
  refuses to trust one over the counts.
- The stamp is **write-once, never cleared**. The column names an event, not a
  state, and `moonsTotalEstimated` means moon totals get revised upward — a
  retractable stamp would flip systems between `.full` and `.partial` on estimate
  churn.
- `recon == "scanned"` is NOT a substitute: it is computed from planets alone, so
  a system with every planet but not every moon scanned reads as scanned there
  while still being real survey work. Don't shortcut through the column.
- Two feature modules call `persist` directly (`LocationsFeature`'s
  hydrate-on-select and, indirectly, the star map — whose own duplicate hydrate
  now just calls `LocationsClient.hydrateSystem`), so it must stay `public`.

See [[sqlite-db-location]] (which used to say this column was unreliable),
[[directives-feature]], and [[ami-drones-are-event-silent]].
