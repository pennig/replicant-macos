# Nearest Unexplored Survey Targets

**Date:** 2026-07-29
**Status:** Approved

## Problem

The New Survey Run dialog offers only a prefix search over the star census. With
14,122 stars locally and no notion of which are worth surveying, building a
target queue means knowing designations by heart. The dialog should suggest the
five nearest unexplored systems.

Answering "unexplored" turned out to require fixing a dead column first.
`Star.fullyScannedAt` is declared, documented, read by `LiveStar.scanState` as
the `.full` survey tier — and written by nothing. It is null on all 14,122 rows
of the live database, so the star map can never render a system as fully
scanned, and the picker has no cheap way to ask whether a system is done.

## Decisions

Four decisions were settled before design, and they are the load-bearing ones:

1. **"Unexplored" means not fully scanned**, by the engine's own rule — every
   planet and (where a total is reported) every moon scanned. A partially
   scanned system *is* suggested: it is genuine survey work. Ordering is pure
   distance, with no promotion of partials.
2. **The anchor is always the selected vessel's current system**, and the list
   is stable. Adding a target removes it and pulls in the next-nearest;
   distances never re-base onto the growing queue. Rejected: re-anchoring on
   the last queued target (a better flight path, but the whole list reshuffles
   on each add).
3. **`fullyScannedAt` is stamped from counts, never from a completion claim.**
   Two triggers, one rule. A survey directive completing causes a re-read and
   the refreshed planet/moon counts decide; a `scan.completed` event stamps when
   the merged result shows every planet and moon scanned. Rejected: trusting the
   directive's configuration and stamping on the completion event alone.
4. **The stamp is write-once and never cleared.**

## Part A — Make `fullyScannedAt` real

### A1. Move the predicate down to the data

`SurveyRun.isFullyScanned` asks a question phrased entirely in a `StarSystem`'s
own fields, so it belongs on `StarSystem` in UniverseModels:

```swift
extension StarSystem {
    /// Whether this system's scan counts say it is completely surveyed.
    ///
    /// UNKNOWN counts are never "scanned": surveying an already-done system
    /// costs one wasted trip, but skipping an unscanned one silently loses the
    /// whole point of a survey. Wrong in the cheap direction, deliberately.
    public var isFullyScanned: Bool
}
```

`SurveyRun.isFullyScanned(_ system: StarSystem?)` remains as a thin forwarder,
preserving its `nil` → `false` handling, so its existing call sites in
`preflight`/`confirm` and its tests are untouched.

This move is what makes one shared definition possible at all: UniverseModels
cannot import DirectiveEngine (DirectiveEngine depends on GameServices, which
depends on UniverseModels), so the predicate has to live below the engine for
the persistence layer to use it.

### A2. One choke point for persistence

`LocationsClient` has **eight** `SystemDetail.upsert` sites, all the same three
lines: build a row from a merged `StarSystem`, upsert it. They collapse into one
helper declared beside `SystemDetail` in UniverseModels:

```swift
extension SystemDetail {
    /// Persist a system's blob AND reconcile the census row's scan lifecycle
    /// stamp in the same transaction, so no path can update the catalog without
    /// `stars.fullyScannedAt` following.
    static func persist(system: StarSystem, at now: Date, in db: Database) throws
}
```

It upserts the blob, then stamps `Star.fullyScannedAt = now` when
`system.isFullyScanned` holds **and the column is still null**.

Write-once is deliberate. `Star.swift` documents its three local lifecycle
timestamps as ones "the survey never overwrites", and the column is named for an
event (`fullyScannedAt`), not a state (`isFullyScanned`) — timestamps of events
are not retracted. The consequence to accept: if a later scan discovers
additional moons and raises `moonsTotal`, the stamp stays even though the system
is no longer strictly complete. `StarSystem.moonsTotalEstimated` exists, so moon
totals genuinely do get revised, and a retractable stamp would flip systems
between `.full` and `.partial` on estimate churn.

Routing every site through this helper satisfies decision 3's `scan.completed`
trigger for free: `ingestScanResult` (that path) and `ingestSurveyScans`
(the `ami.survey.digest` channel, the only channel carrying adopted-drone scans
— see the `ami-drones-are-event-silent` and `survey-digest-scans` notes) both
merge and upsert through it, so the stamp lands the moment a merge makes a
system complete.

`hydrateSystem` currently builds its row *outside* its write block; that moves
inside, so the upsert and the stamp are one transaction.

`ingestScanResult` seeds `StarSystem(designation:recon:.visited)` when nothing
is cached — a minimal system with no `planetsTotal`, so `isFullyScanned` is
false and a single body's scan can never stamp a whole system. That is correct
and must stay true.

### A3. The directive trigger

A `"directive.completed"` case is added to `LocationsIngestion.catalogRoute`:
for `survey_system`, hydrate the event's star, letting A2 decide the stamp from
the refreshed counts.

`catalogRoute` is the right home. Its own documentation states that a new event
carrying catalog data is "a new `case` here plus one `LocationsClient` method",
and it already matches `.all`. `DirectiveIngestion` — which owns
`directive.completed` today — explicitly documents that its "ONLY job is writing
one `DirectiveLogEntry`" and that it never does anything else; adding a hydrate
there would break a contract the engine's observe-reconciled-state design rests
on.

This depends on `GET locations/{star}` being readable away from the system. It
is: the endpoint is **exploration**-gated, not presence-gated (the 403's "No
replicant in system" message lies — see the
`location-endpoint-presence-gate` note, corrected 2026-07-27). A system that was
just surveyed is explored, so it rehydrates from anywhere.
`LocationsClient.hydrateSystem`'s doc comment still claims presence-gating and
is stale; it gets corrected as part of this work, since the whole trigger rests
on the distinction.

Cost is one `GET locations/{star}` per survey completion. Survey Run already
performs this read itself via `.refreshSystem`, so for engine-driven runs it is
a duplicate. Accepted rather than adding a "is a running directive driving this
device" query: surveys complete minutes to hours apart.

### A4. Backfill

31 systems are fully scanned today with a null stamp, so without a backfill the
star map stays wrong for all existing data and the picker would suggest finished
systems.

A new append-only `SchemaMigration` appended to `GameDatabase.manifest` stamps
them from `systemDetails.hydratedAt` — the best available evidence of when we
learned the system was complete — applying the same planets-and-moons rule via
`json_extract` over `systemJSON`.

Migrations are append-only: never edit, rename, or reorder a shipped one. This
migration is data-only, so the `GoldenSchemaTests` snapshot is unchanged;
`SchemaManifestTests`' frozen identifier list gains the new entry.

### A5. Consequence

`LiveStar.scanState` begins returning `.full` correctly, closing the star-map
bug with no change to that file.

## Part B — The suggestions

With Part A in place the picker needs **no `SystemDetail` fetch and no JSON
decode**: exclusion is `star.fullyScannedAt != nil`, on rows the dialog's state
already fetches.

### B1. The resolver

`SurveyTargetSuggestions` in DirectiveEngine, beside `SurveyRun` — pure, no
I/O, no clock, no SwiftUI:

```swift
public enum SurveyTargetSuggestions {
    public struct Suggestion: Equatable, Sendable, Identifiable {
        public let designation: String
        public let distanceLY: Double
        public var id: String { designation }
    }

    public static let count = 5

    public static func nearest(
        to anchor: Position,
        anchorDesignation: String,
        stars: [Star],
        excluding queued: Set<String>,
        limit: Int = count
    ) -> [Suggestion]
}
```

Excludes the anchor's own system, anything in `queued`, and anything with a
non-nil `fullyScannedAt`. Ranks by **squared** distance in a single pass keeping
the best `limit` — no sort over 14k elements, and `sqrt` only for the survivors
— tie-broken on designation, because a deterministic order is what makes the
list stable across adds (decision 2).

It must not be a static on a SwiftUI `View`: pure logic in that position traps
with signal 5 under `swift test` (see the
`swiftui-view-statics-trap-in-tests` note). A plain enum namespace in
DirectiveEngine keeps it testable as function calls over fixtures, the way
`SurveyRun`'s own stall matrix is.

### B2. Feature wiring

`NewDirectiveFeature.State` gains a computed anchor and a computed suggestions
list. No new `@FetchAll` and no new action:

```swift
var anchorSystem: String? {
    guard let code = vesselCode,
          let vessel = devices.first(where: { $0.deviceCode == code }),
          let location = vessel.location
    else { return nil }
    return SiteAssay.system(of: location)
}
```

A nil anchor yields no suggestions, covering both "no vessel picked yet" and
"vessel in transit or stowed" (`location == nil`). That is consistent with how
the dialog already treats a locationless vessel: `originDesignation` is nil for
it today. A system with no census row also yields nothing — no position, no
distance.

### B3. UI

A `Nearest Unexplored` block in `targetPicker`, occupying the slot where search
results render and shown when the search field is empty, so typing swaps to
search results and clearing swaps back. Rows follow the existing search-row
shape: mono designation (any system designation renders in a mono token — see
the `monospace-system-names` rule) and a trailing `String(format: "%.1f ly", d)`,
the house format already used in `LocationDetailView`.

Tapping sends the existing `.targetAdded`. No new action is needed: the row
leaves because `queued` excludes it, and the next-nearest slides in. No
"add all five" affordance. When everything nearby is queued or done, the block
does not render.

The `partial · 2/5 scanned` annotation from the design mockup is deliberately
**not** built. Those counts live only inside the `systemJSON` blob, so rendering
them would reintroduce the decode that relying on `fullyScannedAt` eliminates.
It can be added later as a bare `partial` flag from the denormalized `recon`
column, or with counts at the cost of a decode.

### B4. Failure direction

If a stamp is ever missed, the picker suggests a finished system; the engine
skips it at preflight with `.advanceTarget` — one wasted queue slot, no trip
taken. This is the same cheap-direction bias `isFullyScanned` already documents.

## Testing

**`StarSystem.isFullyScanned`** — planets clause; moons clause; unknown counts
never full; zero totals never full.

**The choke point** — stamps on becoming complete; does **not** stamp when moons
fall short (the case a `recon`-column shortcut gets wrong, since `recon` is
computed from planets alone); does not overwrite an existing stamp; does not
stamp a seeded minimal system from a single body's scan.

**The `directive.completed` route** — hydrates for `survey_system`; ignores other
directive names.

**The backfill migration** — over a fixture database with a fully scanned
system, a planets-short system, and a moons-short system.

**`SurveyTargetSuggestions`** — returns exactly 5 when candidates allow and
fewer when they do not; ascending distance; deterministic tie-break; anchor's own
system excluded; queued excluded; stamped excluded.

**`NewDirectiveFeature`** — picking a vessel populates suggestions; adding one
removes it and pulls in the next-nearest; a vessel with no location yields none.

Test results are read from Swift Testing's JSON event stream, never by scraping
console text — see the `swift-test-event-stream` skill, including its
multi-target truncation trap.

## Out of scope

- Re-anchoring suggestions on the queue (decision 2).
- The `partial · n/m scanned` annotation (B3).
- Deduplicating the extra hydrate for engine-driven runs (A3).
- Any change to Relay Run or the rest of Stage 5.
