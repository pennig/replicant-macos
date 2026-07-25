# Salvage resource amounts — absolute units from `salvage.discovered`

**Date:** 2026-07-25
**Status:** Approved, not yet implemented.

## Goal

The Locations catalog can say a salvage site is "40% remaining" but never *how
much* that is. The percentage alone can't answer the only question that matters
— is this site worth sending a drone to?

`salvage.discovered` carries the missing half: the absolute unit counts of what
was found. Hold onto those, combine them with the `resource_sites[]`
percentages the locations endpoint already returns, and every salvage site can
report real amounts.

Scope is **salvage sites only**. Mining sites (`…-SITE-N`) reach the same
treatment later; the storage and UI here are shaped so that's a data change,
not a rework.

## Live payload facts (probed via `replicant raw GET`)

`salvage.discovered` — four seen in one 200-event window, all from an
`ami_survey_controller`:

```json
{ "designation": "TAANSI-6-SAL-1", "location": "TAANSI-6",
  "name": "Derelict Survey Probe", "salvage_type": "derelict_probe",
  "resources": { "conductive": 331, "rares": 99, "silicates": 248 } }
```

`GET locations/TAANSI-6` returns that same site inside `resource_sites[]`:

```json
{ "site_index": 0, "designation": "TAANSI-6-SAL-1",
  "name": "Derelict Survey Probe", "site_type": "salvage",
  "resources_remaining_pct": { "conductive": 100, "rares": 100, "silicates": 100 } }
```

Same resource keys on both sides. Reading 100% immediately after discovery on
two independent bodies (`TAANSI-6`, `TAANSI-6-5`) is the evidence that the
event's `resources` are **original totals**, not current remainder.

Three further findings that shape the design:

1. **The envelope's `location` is the acting device's, not the site's.** The
   event above has envelope `location: "TAANSI-5-L4"` — where the survey
   controller sits — while the payload's `location` is `TAANSI-6`.
   `LocationsIngestion.catalogRoute` currently resolves
   `event.location ?? payload["location"]`, which is backwards for this family.
2. **`scan.completed` already carries absolute salvage numbers and we discard
   them.** Its salvage block keys yield as `resources_remaining:
   {structural: 339, …}`, but `RawSalvage.domain` keeps only `.keys.sorted()`
   into `resourcesAvailable`.
3. **`salvage.depleted` keys its target as `site`** (per the docs catalogue),
   not `location`. So today's `markSalvageDepleted(location:)` is being handed
   the controller's location and almost certainly no-op'ing — and worse,
   `mutateSalvage(atBody:)` would deplete *every* salvage site on a body when
   one spends.

## Design

### Two stores, one job each

The numbers split into two kinds of knowledge, and conflating them is what
makes this awkward:

- **Percentages are catalog state.** They arrive on the location payload, they
  change constantly, they belong with the site. `ResourceSite.remaining`
  already stores them exactly this way; salvage is the odd one out only because
  `RawResourceSite.salvageDomain` drops the values.
- **Totals are historical event knowledge.** The catalog payload never carries
  them. They arrive only on an event, they never change, and they must survive
  every blob rewrite.

So percentages go on `SalvageSite`, and totals get their own table.

### `SiteAssay` table

New `@Table` in `UniverseModels/LocationRecords.swift`, beside `SystemDetail`:

```swift
@Table
public struct SiteAssay: Identifiable, Equatable, Sendable {
    @Column(primaryKey: true) public var id: String   // site designation, TAANSI-6-SAL-1
    public var body: String                            // TAANSI-6 — from the PAYLOAD
    public var system: String                          // TAANSI — for per-system fetches
    public var siteType: String                        // "salvage" | "mining"
    @Column(as: [String: Double].JSONRepresentation.self)
    public var totals: [String: Double]                // resource → original units
    public var assayedAt: Date
}
```

A table rather than a field on `SalvageSite` because discovery events land
*before* the body is hydrated, and `mergingScan` / `applying(detail)` rebuild
the `StarSystem` blob from server payloads that don't carry totals — blob-resident
totals would be clobbered on the next scan. `siteType` is present from day one
so mining assays need no schema change.

Registered in `GameDatabase.migrator()`. Cleared on logout in
`registerSessionCleanup()` — account-scoped knowledge, same fate as `Star` and
`SystemDetail`.

### Invariant: totals only ever rise

A site's original capacity is fixed, and absolute remaining is always ≤ total,
so every write is `max(existing, observed)` — **applied per resource key**, not
per site, so an observation naming only two of three resources leaves the third
untouched. The estimate self-corrects upward, never regresses, and a stale
percentage can't produce an absurd denominator. It's also a one-line property
to test.

This is what makes assumption (2) below safe: if `resources` ever turns out to
be current-remainder rather than original, the error is corrected by the next
observation instead of persisting.

### `SalvageSite` gains percentages

```swift
public var remainingPct: [String: Double]   // resource → 0…100
```

`RawResourceSite.salvageDomain` stops discarding the values and populates both
`resourcesAvailable` (the name list, which existing callers and old blobs rely
on) and `remainingPct`.

**Blob compatibility is required, not optional.** `SalvageSite` is `Codable`
and lives inside the `StarSystem` blob in `systemDetails`. Verified on this
toolchain: synthesized `Decodable` ignores stored-property defaults and throws
`keyNotFound` on a missing key. So `SalvageSite` needs an explicit
`init(from:)` decoding `remainingPct` with `decodeIfPresent ?? [:]`, or every
blob written before this change stops decoding.

(Adding the stored property is otherwise unremarkable — the
`spm-stale-layout-crash` rebuild ritual was retested on 2026-07-25 and retired;
see that memory note.)

### Display is one formula

`units = total × pct/100`. Always. No staleness bookkeeping and no
"which source was fresher" branch, because the percentage always comes from the
catalog row being rendered and the total is a constant.

A pure, SwiftUI-free resolver in `UniverseModels` (per the
`swiftui-view-statics-trap-in-tests` note):

```swift
public struct ResourceAmount: Identifiable, Equatable, Sendable {
    public var resource: String
    public var percentRemaining: Double      // 0…100
    public var total: Double?                // nil when never assayed
    public var remaining: Double? { total.map { $0 * percentRemaining / 100 } }
    public var id: String { resource }
}

public enum SiteAmounts {
    public static func amounts(
        remainingPct: [String: Double], totals: [String: Double]?
    ) -> [ResourceAmount]
}
```

**The live catalog drives the output, not the assay.** `amounts` emits one
entry per key in `remainingPct`, sorted by resource name for deterministic
rendering and tests. A resource present in `totals` but absent from
`remainingPct` is dropped — the site no longer reports it, so we don't either.
`total` is nil for a resource the assay doesn't cover, which renders as a bare
percentage.

Degradation is explicit rather than faked. A salvage site sourced from the
`salvage[]` roster block has names but no percentage; `remainingPct` is empty,
so it shows the original total as a *discovered* figure, not a live one. Once
the body is hydrated via the locations endpoint the percentage arrives and the
row goes live.

### Writers — two, plus the location fix

**1. `salvage.discovered`** — new case in `LocationsIngestion.catalogRoute`
calling `LocationsClient.recordSalvageDiscovery(payload:)`, which:

- writes the `SiteAssay` row (raise-only), and
- folds the site into the cached `StarSystem`. The payload carries
  `designation`, `location`, `name` and `salvage_type` — everything
  `SalvageSite` needs — so a discovery shows up in the catalog immediately
  instead of waiting for the next scan. `resourcesAvailable` comes from the
  `resources` keys; `remainingPct` is left **empty** rather than synthesised as
  100%. The evidence says a freshly discovered site is at 100%, but inventing
  percentages would present an inference as observed data — the site reads as
  discovered totals until the first hydrate supplies real ones.

**2. `scan.completed`** — `ingestScanResult` additionally reads each salvage
entry's absolute `resources_remaining` and raises `totals`: `remaining ÷
(pct/100)` when a percentage is known for that resource, else `remaining` as a
floor. The percentage comes from the cached `StarSystem`'s existing
`SalvageSite.remainingPct` for that designation, read inside the same write
transaction. This is what keeps totals correct when a discovery event is missed.

Hydrate paths need no assay write: a percentage alone can't raise a total.

**3. The location-key fix.** For the salvage family the payload wins over the
envelope, since the envelope names the acting device's position.
`markSalvageDepleted(location:)` becomes `markSalvageDepleted(site:)`, matching
on site designation so one site spending doesn't deplete its siblings.
Extraction is tolerant of `site` / `designation` / payload `location`, because
that key comes from the docs catalogue rather than a live probe.

### Surfaces

- **`LocationDetailView`** — `SiteSalvageSections` (planet and moon inspectors)
  and the system-level "Salvage" roll-up card. The `detail:` string becomes a
  per-resource readout, `conductive  132 / 331  (40%)`, with the collapsed row
  summarising as `~479 units` — the sum of `remaining` across resources, not of
  totals. Resources with no assay are omitted from that sum, so the figure is a
  floor; the `~` carries that. A site with no assay at all keeps today's
  behaviour.
- **Mining `ResourceSite` rows** move to the same readout shape, showing
  percent only. No new data, but it makes the later mining work a data change
  rather than a UI change — and it retires the current average-across-resources
  figure, which is misleading whenever a site's resources deplete unevenly.
- **`DirectiveComposerSheet.salvageBodyLabel`** — `TAANSI-6 · 2 sites · ~680
  units`, so the `gather_salvage` picker ranks targets by worth. Assays reach it
  via `@FetchAll` in `DirectiveComposer.State`, per the
  `list-feature-query-in-state` standard.

Assays reach `LocationsFeature` the same way: `@FetchAll` in the reducer's
state, passed into the inspectors as a `[String: [String: Double]]` lookup
keyed by site designation. The views stay pure renderers.

## Testing

- `SiteAmounts.amounts` — no assay, partial assay, zero percent, an assay
  listing a resource the site no longer does, both empty.
- The raise-only invariant — a second observation never lowers a total.
- Payload-key extraction — the envelope location must *not* win; `site` /
  `designation` / `location` tolerance.
- `recordSalvageDiscovery` — upsert, idempotent on replay, and the
  `StarSystem` fold-in when the system is uncached.
- `ingestScanResult` — raises totals from `resources_remaining`.
- `SalvageSite` decoding a blob written without `remainingPct`.
- Route level: a `salvage.discovered` envelope writes the row.

## Out of scope

- **Mining site assays.** Needs `scan.completed`'s report block (docs describe
  per-resource `availability` / `depletion_pct` / `original` / `remaining`) and
  `search.completed`'s discovered-site totals. Not probed live — scanning is a
  POST against the one real account.
- **Star map body indicators**, which are boolean flags today.

## Assumptions and risks

1. **`salvage.depleted`'s payload key is `site`** — from the docs catalogue,
   not a live probe (no such event appeared in the sampled window). Mitigated
   by tolerant key extraction.
2. **`salvage.discovered.resources` are originals** — inferred from two live
   sites reading exactly 100% across all resources right after discovery.
   Mitigated by the raise-only invariant.
3. **`scan.completed`'s salvage `resources_remaining` shape** is trusted from
   the captured fixture in `UniverseModelsTests.scanResultJSON`, whose comment
   states it's a real event body. Not re-probed.
