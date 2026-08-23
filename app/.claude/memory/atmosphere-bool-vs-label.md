---
name: atmosphere-bool-vs-label
description: "`atmosphere` is a Bool in GET locations/{designation} and a density label in a scan block; typing it String? threw typeMismatch on EVERY planet body hydrate, silently, for five surfaces."
metadata:
  node_type: memory
  type: reference
---

`GET /v1/locations/{designation}` reports a planet's atmosphere as a **Bool**
(`"atmosphere": false`), the same fact a moon block spells `has_atmosphere`.
A **scan**'s physical block reports a **density label** — one of `none`, `thin`,
`standard`, `dense`, `crushing`. Same key, two types, two meanings.

`RawBodyPhysical.atmosphere` was typed `String?`, so decoding any planet-level
location response raised `DecodingError.typeMismatch` at `planet.atmosphere`.
**Every caller wraps the fetch in `try?`**, so nothing surfaced — the five
surfaces that hydrate a body all did nothing at all for a planet:

- `LocationsFeature` hydrate-on-select (the catalog)
- `NewStarMapFeature.hydrateBody` (the orrery body drill)
- `DirectiveExecutor` / `MissionStepMachine`'s body re-read
- `DirectiveComposerFeature`'s body hydrate
- `LocationsClient.inventory(at:)`, which routes through `body(_:)`

Fixed by `RawAtmosphere` (label-or-flag), the flag folding into `hasAtmosphere`.
`RawAtmosphere` lives in `LocationDTOs.swift` beside `RawBodyPhysical`.

**The moon connection.** A planet's moon roster arrives as `moons[]`, a SIBLING of
`planet{}` in the same response — the star-level response carries only `moon_count`
(see [[locations-catalog-feature]]). So the throw was also why a planet could show
"1 moon" and list none: the one endpoint carrying the roster never got read. Do NOT
conclude from a missing roster that the endpoint omits it; probe it.

**Measured before the fix** (live SQLite, 818 hydrated systems): 99 systems held
`moonCount > 0` with zero moon rows, and **all 572 planets in them had null
`physical`** — the tell that no planet hydrate has ever landed. The 658 complete
systems got their moons from `ami.survey.digest` (`ingestSurveyScans` → `observing`),
not from the catalog. That split is the diagnostic: a body attribute that only ever
appears on survey-scanned systems means the GET path is broken, not empty.

Same family as [[location-response-schema-drift]] and
[[openapi-spec-drift-leniency]] — but note this one is NOT spec drift. The openapi
schema types the whole `planet` block as freeform, so the generated decode passed
and only our own DTO threw. A green `additionalProperties` check proves nothing
about leaf types.

`UniverseModelsTests.scannedPlanetDecodesThroughTheGeneratedPath` pins it through
the real path (generated decode → `reinterpret` → `bodyDetail`), on a payload
captured live at `locations/ATHEEMIN-2`.
