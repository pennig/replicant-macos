# Civilisations feature

Catalog › Civilisations = backend **"species"** endpoints. `CivilisationsFeature`
(mirrors `BlueprintsFeature`): `Civilisation` `@Table` in GameModels keyed by
`speciesKey`, blending `GET /v1/species` (full roster, near-static) with
`GET /v1/accounts/reputation` (met species only) into one nullable
`totalReputation` column — nil = not yet encountered.

Non-obvious bits:

- **Refresh split:** `.task` cold-loads both endpoints only when the table is
  empty; otherwise it refreshes reputation alone (standings move with
  gameplay). Reputation apply = one transaction: null all, then per-key
  updates — so species missing from the payload return to unmet and unknown
  keys are no-ops. Refresh-only failures are log-only (no banner) by design.
- **Spec drift patched twice, both still carried:** `star_regions`, an optional
  array upstream omits (2026-07-24), and `environment` (2026-09-06), the v3
  eight-key `[min, max]` block every species carries. `SpeciesSchema` is
  `additionalProperties: false`, so the undeclared `environment` threw on every
  load and **this screen was dead until the v3 sweep found it** — nothing else
  reads `/v1/species`, so no other surface reported the break. Both patches live
  at the tail of the schema in the active `-edits` file; see
  [[openapi-spec-layout]] for how they were typed. Re-apply after a spec re-fetch.
- **`environment` is the terraforming target ranges** — temperature, pressure,
  oxygen, toxicity, hydrosphere, tectonic, biosphere, gravity — and is what makes
  a species a terraforming *destination* rather than a reputation counterparty.
  Nothing maps it into `Civilisation` yet.
- `total_reputation` is spec'd `number` (generated `Double?`) but is whole
  points — mapped with `Int(...)`. Tier thresholds are undocumented; the UI
  shows the raw standing only.
- Logout wipes `civilisations` (handler id "civilisations" in
  `registerSessionCleanup()`) because the merged reputation column is
  account-scoped even though the roster is global.
- Spec doc: `docs/superpowers/specs/2026-07-24-civilisations-design.md`.
