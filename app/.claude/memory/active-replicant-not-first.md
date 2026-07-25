---
name: active-replicant-not-first
description: Multi-replicant invariant — never use roster.first (or Replicant.fetchAll.first) as a stand-in for the "active"/"current" replicant; resolve via activeReplicantCode, and event ingestion fans out over the whole roster.
metadata:
  type: project
---

The account has MULTIPLE replicants. The active one is `@Shared(.appStorage(Account.activeReplicantCodeKey)) var activeReplicantCode: String?`. Picking the first roster row as a proxy for "current" is a recurring bug class.

**Invariants:**
- **Feature state / views:** resolve the active replicant as
  `roster.first { $0.replicantCode == activeReplicantCode } ?? (roster.count == 1 ? roster.first : nil)`.
  Never bare `roster.first` / `replicants.first` / `Replicant.fetchAll(db).first` as "current". (Bare `.first` is fine for the sidebar switcher's display default and for AccountManager's login/refresh default that *writes* activeReplicantCode.)
- **Distance sort (LocationsFeature):** `LocationForest` carries `activeReplicantCode`; `fetch` resolves the origin star via the pattern above. Switching the active replicant fires no binding action (external `@Shared` write) and touches no observed table, so the view reloads the forest via `.onChange(of: store.activeReplicantCode) { .activeReplicantChanged }`. See [[locations-catalog-feature]].
- **Event ingestion (`LocationsIngestion.scanRoute`):** an event with an explicit `replicant_code` names exactly one replicant; **without one it is roster-wide** — evaluate `LocationEventPolicy.decide` against EVERY replicant and let its gates (arrival host-device match, location-scoped current-system match) select. Do NOT fall back to `.first`, which silently drops events for every non-first replicant. The passive-scan debounce is a **per-replicant-code** `[String: Task]` map (each replicant scans its own current location), not a single slot — a single slot let one replicant's scan clobber another's.

Fixed 2026-07-25 (distance sort + ingestion + removed the dead `LocationsFeature.State.currentStar` that used `roster.first`).
