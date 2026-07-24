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
- **Spec drift patched (2026-07-24):** live species payloads carry an optional
  `star_regions` array the spec omitted; added as a typed key to
  `openapi-2.3.0-edits.json` (spec stays strict per policy). Re-apply after a
  spec re-fetch.
- `total_reputation` is spec'd `number` (generated `Double?`) but is whole
  points — mapped with `Int(...)`. Tier thresholds are undocumented; the UI
  shows the raw standing only.
- Logout wipes `civilisations` (handler id "civilisations" in
  `registerSessionCleanup()`) because the merged reputation column is
  account-scoped even though the roster is global.
- Spec doc: `docs/superpowers/specs/2026-07-24-civilisations-design.md`.
