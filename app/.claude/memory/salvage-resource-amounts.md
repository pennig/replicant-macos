# Salvage resource amounts (units, not just percent)

Shipped 2026-07-25 across 8 tasks (plan: `docs/superpowers/plans/2026-07-25-salvage-resource-amounts.md`).
The catalog only ever carried `resources_remaining_pct` (0–100) for a salvage
site — enough to say "half gone" but not "half of *what*". This feature adds
the missing absolute scale end-to-end: assay store → per-resource rows in the
Locations catalog → ranked bodies in the `gather_salvage` picker.

## The assay store (`SiteAssay`, `UniverseModels/Sources/LocationRecords.swift`)

A `@Table` keyed by **site designation** (`TAANSI-6-SAL-1`), not folded into
`SalvageSite`/the `StarSystem` blob. Reason: `resources_remaining_pct` is
catalog state that gets clobbered by every re-scan's blob rewrite
(`mergingScan`/`applying(_:)`), but the *original total unit count* is
historical event knowledge the catalog payload never carries — it only ever
arrives once, on `salvage.discovered` or a `scan.completed` salvage block. A
separate table survives blob churn; a field on `SalvageSite` would not.

- `totals: [String: Double]` — resource name → original unit count.
- `SiteAssay.raising(_:with:)` — **merge, never overwrite**: a site's capacity
  is fixed and remaining ≤ total, so an observation may only raise a stored
  value, applied per-resource-key (a subset observation leaves the rest
  alone), and non-positive observations are ignored outright.
- `siteType` ("salvage"/"mining") is stored now so mining assays need no
  schema change when that ingestion lands — **out of scope** for this feature
  (mining sites already route through `SiteAmounts` for display, but nothing
  populates `SiteAssay` rows for them yet: `scan.completed`'s report block and
  `search.completed`'s totals, neither probed live).

## The payload-vs-envelope rule for salvage events

Every event handler here (`GameServices/Sources/SalvageEventPayload.swift`)
targets a site/body from the event **payload**, never the envelope. A real
`salvage.discovered` envelope's `location` is the *acting device's* position
(e.g. `TAANSI-5-L4`, a survey controller sitting at a Lagrange point) — not
where the salvage is. The site's actual body only appears inside the payload
(`location: "TAANSI-6"` there). Task 4 fixed a live bug where `catalogRoute`
preferred the envelope and `salvage.depleted` keyed off `site`, so a depletion
event was mis-targeted and `mutateSalvage(atBody:)` would have spent every
sibling site on the acting device's body instead of the one that actually
depleted. `SalvageEventPayload.discovery(from:)` / `.depletedSite(from:)` are
the two parsers; both are payload-only by construction, so this can't
regress silently.

## The universal "unknown, never zero" invariant

Every optional in this feature means **not yet assayed**, not zero:
- `ResourceAmount.total: Double?`, `.percentRemaining: Double?` (the latter
  flipped from non-optional `Double` in Task 7 — a roster-block salvage
  entry with no percentage at all was rendering as a fabricated 0%, making
  an untouched site look depleted).
- `ResourceAmount.remaining` is nil unless *both* are known.
- `SiteAmounts.totalRemaining(_:)` is nil when nothing is assayed at all,
  and — when some resources are known and others aren't — sums only the
  known ones, making the result a **floor** (UI marks it `~`).
- `SalvageBody.unitsRemaining: Double?` (Task 8) follows the same rule: nil
  when no site on the body has a stored total. The `gather_salvage` picker
  omits the units clause entirely rather than showing "0 units", which would
  read as "not worth the trip" for a body that's simply unassayed.

## Where it surfaces

- **Locations catalog** (`LocationsFeature`): per-resource amount rows on
  site/salvage detail (`ResourceAmountRows.swift`), fed by
  `SiteAmounts.amounts(remainingPct:totals:)`.
- **`gather_salvage` composer** (`DirectiveComposerFeature`): `State` now
  also `@FetchAll(SiteAssay.all)`s `siteAssays` alongside `systemDetails`;
  `StarSystem.salvageBodies(totals:)` (an overload of the old no-arg
  `salvageBodies`, which still exists as a `[:]`-defaulted delegate for other
  callers) sums each body's live sites' `SiteAmounts.totalRemaining` into
  `SalvageBody.unitsRemaining`. `DirectiveComposerSheet.salvageBodyLabel`
  appends `~N units` when present.

## Full-suite health at ship (2026-07-25)

All 24 test products in `app/Modules` (`swift package describe --type json`)
ran clean, 0 failing, at Task 8 (final task) completion.
