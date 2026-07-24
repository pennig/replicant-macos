# Civilisations — Catalog feature design (species + account reputation)

**Date:** 2026-07-24
**Status:** Implemented same day (this spec records the approved design).

## Goal

A read-only **Civilisations** item in the Catalog sidebar group blending two
backend surfaces keyed by `species_key`:

- `GET /v1/species` — the full roster of the galaxy's civilisations (backend
  term: "species"). 27 entries; near-static.
- `GET /v1/accounts/reputation` — the account's standing with the species it
  has met (`total_reputation`, whole points). Moves with gameplay.

Scope is account-level reputation only — no per-replicant reputation, no
leaderboards. UI and code use the British spelling (user decision, matching the
game docs and existing strings like `civilisationPoints`).

## Live payload facts (probed via `replicant raw GET`)

- Species fields: `species_key`, `name`, `description`, `government`,
  `greeting`, `homeworld_type`, `tech_affinity`, `trait`, and **optional**
  `star_regions: [String]` (present on ~6 species).
- Reputation entries: `species_key`, `name`, `trait`, `description`,
  `total_reputation` (spec types it `number` → generated `Double?`; whole
  points on the wire).
- **Spec drift fixed here:** `app_schemas_species_SpeciesSchema` lacked
  `star_regions` while declaring `additionalProperties: false`, so the strict
  generated decoder threw on the live payload. Per the drift policy the spec
  stays strict and gains the typed key (in `openapi-2.3.0-edits.json`).

## Design

**Model.** One `Civilisation` `@Table` in `GameModels` (mirrors `Blueprint`):
`speciesKey` (PK), the seven species strings (coalesced non-null),
`starRegions` as a JSON-blob column, and a nullable `totalReputation` merged
from the reputation endpoint — nil means "not yet encountered". A slim
`SpeciesReputation` value type carries the join-relevant slice of a reputation
entry. Migration registered in `GameDatabase.migrator()`.

**Refresh semantics.** `.task` (view appear): empty table → full cold-load
(species + reputation); non-empty → reputation-only refresh. The refresh
button re-runs the full load. Reputation apply is one write transaction:
null every `totalReputation`, then targeted per-key updates — idempotent,
species absent from the payload return to unmet, unknown keys are no-ops.
Cold-load failure raises the standard error banner; reputation-refresh failure
is log-only (it runs on every visit over a still-valid cached catalog).

**Module.** `CivilisationsFeature` (TCA), mirroring `BlueprintsFeature`:
`CivilisationsClient` (`fetchSpecies` / `fetchReputation`, loud
`unimplemented` test values), reducer with `@FetchAll` list query in state
(search filters in SQL over name/trait/government/techAffinity, ordered by
name), `SelectableList` list view + row (own file, per the preview-crash
rule) + dossier detail view (greeting as quoted flavor block, profile
attribute rows humanized from snake_case, star-region readout, reputation
section).

**Wiring.** Sidebar case `civilisations` ("Civilisations", `person.2.wave.2`),
appended to the Catalog group. `MainFeature` gains the scoped sub-feature and
content/detail arms. Logout wipes the `civilisations` table (account-scoped
reputation; a second account must re-cold-load) via a
`SessionLifecycleHandler` in `registerSessionCleanup()`.

## Testing

Six swift-testing cases in `CivilisationsFeatureTests` (TDD, red first):
schema mapping (coalescing + `star_regions` + `Double`→`Int`), cold-load on
empty table with reputation merge, reputation-only refresh on non-empty
table, stale-clear + unknown-key handling, load-failure banner, and the SQL
search filter. Full package suite green (623 tests, 23 products).

## Follow-ups

- **User step:** link the `CivilisationsFeature` product into the app target
  in Xcode (pbxproj edits are blocked for agents).
- `total_reputation` semantics (bounds, tiers) are undocumented; the docs
  mention four reputation tiers but no thresholds — revisit if the API ever
  exposes them.
