# `tendMesh` grow + prune — the build record (SHIPPED 2026-08-04)

The automation brain's first acting capability. Design decisions live in
[brain-tendmesh-worthiness](brain-tendmesh-worthiness.md) (ticket 10) and the
robustness bar it answers is [brain-robustness-bar](brain-robustness-bar.md).
**This note is what actually shipped, where it deviated from the plan, and the
evidence map.**

Branch `worktree-tendmesh-grow-prune`, 47 commits (`5096568..d39a1f5`) over a
27-task plan (`docs/superpowers/plans/2026-08-03-tendmesh-grow-prune.md`).
Additive except for **one** schema change: `Directive.addSourceRelayCode` (a
nullable TEXT column; `CREATE TABLE` untouched, golden diff exactly one column).

## What shipped

- **`WorldView`** — one galaxy-wide read per tick (stars, devices, directives,
  site assays, live events, belts, replicants, location footprints). Belt decode
  is bounded by a SQL surveyed filter **and** a pre-decode mesh filter; a
  malformed blob degrades that one system, never the read.
- **`MeshGraph`** — grid-bucketed adjacency at `relayRangeLY` (7.5) plus a
  Dijkstra keyed `(relays, distance, designation)`. Two entry points over one
  `search(sources:free:targets:)`: `reach` (grow, seeded at every mesh system)
  and `pathUnion` (prune, rooted at the anchor with relays as free interior
  nodes). Cross-validated against brute force over 2,000 random seeds.
- **`BeltClass` / `ValueCatalog` / `GrowRanking`** — value tiers
  `Event ▸ Rich belt ▸ Moderate belt ▸ salvage-by-units ▸ Sparse belt` and the
  locked five-field lexicographic key.
- **`PrunePredicate`** — the same pathfinding read inversely. A relay is
  reclaimable iff it lies on the cheapest anchor→live-target path-union for
  nothing. Refuses to judge at all (`PruneAnalysis.declined`) when the census
  cannot place every mesh / relay / target / anchor system.
- **`RelayRun`** (`MissionRegistry.machines`) — print → stow → travel → deploy →
  activate, every `.simple` verb split into dispatch + poll. A reclaim-sourced
  run instead flies to the source, deactivates, stows, and carries the relay on.
- **`Brain`** — a nonisolated plan loop on `DirectiveEngineCore`, ticking beside
  the supervisor. Ranks, gates on a `.high` confirm-read inside the launch
  write transaction, launches one `relayRun` row per tick, answers stalls as a
  bounded operator (`retry` only), and prefers reclaiming a useless relay over
  printing a new one.
- **`BrainCeiling`** — the per-type reserve floor and the aggregate proxy
  `RelayRun` actually arms. See [brain-relay-reserve-floor](brain-relay-reserve-floor.md).
- **The why-view** — `@Shared(.inMemory("brainReport"))` → `DirectivesFeature`
  → `DirectivesListView`. No new table.

## The two verified inputs the plan flagged

Both were live-probed 2026-08-03 rather than guessed, and both found the plan
wrong.

1. **Belt-class vocabulary.** `Belt.density` has exactly three live values
   (`sparse`/`moderate`/`dense`); `Belt.richness` (wire `resources`) has five
   qualifiers (`scarce`/`low`/`moderate`/`high`/`rich`) and **no `abundant`** —
   which the plan's test had guessed. Full mapping in
   [belt-value-vocabulary](belt-value-vocabulary.md).
2. **The `R` rail literal, and `N`'s retirement.** The six resource types are
   `carbon`/`conductive`/`rares`/`silicates`/`structural`/`volatiles` (the
   plan's `metal`/`silicon` guess is wrong). The FTL-relay bill is
   `carbon 20, silicates 100, structural 80, rares 40, conductive 120,
   volatiles 10`. `N` (the idle-relay buffer cap) is **retired** — ticket 10
   replaced it with lazy demand-driven reclaim, and no pool management was
   built. Detail in [brain-relay-reserve-floor](brain-relay-reserve-floor.md).

## Deviations from the plan — the ones worth knowing

- **The plan's prune predicate, written literally, reclaims the entire mesh.**
  Three independent mechanisms, all verified in code: a deployed relay is
  seeded as a zero-**cost source**, so it has `pred == nil` and can never be an
  interior node; `reach` strips mesh systems from the returned path anyway
  (`waypoints = path.filter { !meshSystems.contains($0) }`); and
  `guard state.relays > 0` drops already-meshed targets entirely — so the
  literal path-union is empty for exactly the load-bearing case. Caught by
  writing the tests first. Fixed by rooting the union at the **anchor** with
  relays as **free interior** nodes.
- **Plan arithmetic error.** The relay cost is described throughout as
  "fixed 370×6", implying 370 per type. It is **370 total across six types**,
  per-type costs ranging 10..120. A flat per-type floor of 370 would be 37× the
  volatiles bill.
- **Task order changed three times** by controller ruling: 15 before 14
  (the column before its reader), 3 before 2, 6 before 4/5, and 20 before 16
  (arm the spend rail before anything can spend).
- `MissionAction.refreshFootprint` gained a `thenStall:` payload and an
  engine-side resolver; the shared `reAsk` collapse became **kind-scoped**
  (`paid: Set<RefreshKind>`), bounding refresh chains at ≤4 rounds per
  evaluation over a closed enum.
- `RelayRun`'s reclaim path gained a `fetching` step (fly the carrier to the
  source **before** deactivating). Without it, a remote deactivate de-meshes the
  source with nothing present and the follow-up `stow` is unissuable — the relay
  strands permanently inactive at an unreachable L4.

## Three findings that are not in the plan text

1. **`returnToOrigin: false` is a capability gap, not a bug.** A Relay Run is
   deliberately allowed to chain onward rather than come home
   (`Brain.swift:1457-1463`). The carrier is not stranded and degradation is
   safe and legible (`.idle("no free carrier at …")`, surfaced not escalated).
   But on today's **single-carrier fleet the brain plants exactly one relay and
   then idles forever** until a human flies the carrier home — one-shot mesh
   growth with a manual crank. `theNextGrowGoesToTheNextCandidateNotTheMeshedOne`
   hand-flies the carrier back to get a second launch, and the e2e headline
   asserts the idle reason verbatim. **Whoever teaches the brain to recall its
   carrier must change those assertions — they are not a regression.**
2. **The reclaim sequence is safe only because the carrier hosts a replicant.**
   Once the source relay is deactivated, authority survives via FTL rule (1)
   (a replicant physically present), never via the mesh. The executor now gates
   on the carrier's `in_control_range` against the deactivate watermark
   (`carrier.updatedAt >= directive.stepStartedAt`), and the brain refuses to
   source a reclaim for a carrier hosting no replicant. Live fleet has exactly
   one legal carrier: `C7836770` hosts `pennig-salvage`. The other heaven_vessel
   hosts `pennig-1`, the **anchor**, which must never travel.
3. **`view.meshSystems` is presence-based, not a connectivity closure** — any
   system holding a `relaying` relay. So "the hop retains a meshed neighbour" is
   necessary but not sufficient for authority. Both grow and prune read the same
   set. Pre-existing and brain-wide.

## Robustness — the eight-clause evidence map (verified 2026-08-04)

Every test named was confirmed to exist and to assert its clause. Rows whose
evidence is **narrower than the clause** say so.

| Clause | Proven by | Narrower than the clause? |
| --- | --- | --- |
| 1 Selector, not enactor | `brainNeverDrivesOperatorOnlyVerbs` (`skipTarget`/`pause`/`resume` are `unimplemented` and armed across 8 ticks incl. budget exhaustion; also pins `targetIndex == 0`) • `aLaunchingBrainWritesTheDirectiveRowAndNothingElse` • `aGrowLaunchRunsAllTheWayToAGrownMesh` (5-command exact array through the real `CommandGovernor.liveValue`) | No |
| 2 Stateless between ticks | `aDeferralIsNotRememberedAndTheNextTickReDecides` • `aTransientConfirmFailureDefersEveryTickAndWritesNothingUntilItClears` (20 identical deferrals, then one launch) • `manualTicksWriteNothingAndCountExactly`, `stoppingClearsTheWhyViewsFeed` • `aSourceAnotherRunIsAlreadyFetchingIsNotSelectedTwice` | No |
| 3 Pure selection; API vetoes | `aDeferredConfirmNeverFallsThroughToAnotherCandidateOrCarrier` • `theReserveRailVetoesThePrintAndTheBrainIdlesInsteadOfThrashing` paired with `aWorldAboveTheFloorPrintsWithTheIdenticalStack` • `printVetoedWhenConductiveAloneIsBelowFloor`, `emptyStockReadingVetoes` | No |
| 4 Snapshot fidelity | (b) `depletedSalvageExcluded`, `readDerivesMeshFromRelayingRelays`, `hubLocationSurfacesOnlyWhenMeshed` • (c) `anOperatorLaunchInsideTheWindowIsCaughtByTheConfirm`, `anOperatorLaunchAfterTheConfirmReadIsStillCaught`, `aCarrierThatDriftedToASiblingLocationIsDeferred`, `aStaleSourceRowNeverAuthorisesTearingARelayDown`, and the e2e's `reads.value == [ConfirmRead("V1", isHigh: true)]` | **YES** — leg (a) "no new poller" has **no test**. It is structural: `Brain` resolves `@Dependency(\.deviceRefresher)` and nothing else, and no `Timer`/`PollCoordinator` appears in `Brain.swift`/`WorldView.swift`. Nearest proxies: `aTickWithNothingWorthLaunchingIssuesNoConfirmRead`, `aTickWithNoFreeCarrierIssuesNoConfirmRead`. |
| 5 Determinism / e2e | `aGrowLaunchRunsAllTheWayToAGrownMesh`, `theSupervisorAdoptsTheRowTheBrainLaunched`, `theNextGrowGoesToTheNextCandidateNotTheMeshedOne`, and the in-suite negative twin `aRelayThatNeverComesUpGrowsNoMeshAndTheBrainKeepsRankingTheTarget` | **Evidence changed during the build.** The e2e file alone is blind to two rails it traverses: disarming the reserve rail, or making `commitBlocker` return nil, leaves it green. Covered separately by `BrainReserveRailDegradationTests` and `aRacingClaimOnTheSameSpareRelayIsRefusedAtCommitTime` — this clause is **not** clear on the e2e suite alone. |
| 6 Safe degradation | `idlesWhenThereIsNoUnmeshedValue`, `idlesWhenValueIsInReachButNoCarrierIsFree`, `idlesWithNoPrintHubOnTheMesh` • `anIdleBrainAndAStuckBrainDoNotLookAlike` • `idleIsSurfacedButNotEscalated` / `stallIsSurfacedAndEscalated` / `aDeferralReadsAsItsOwnGateNotAsAnOrdinaryIdle` • `noPruneStateEverEscalates`, `aUselessRelayLeftInPlaceIsIdleCalmNotAStall` • `autoRetriesAreSpacedByTheRetryInterval` | **YES, twice.** (i) "degrades without burning budget" is proven for the **stall-retry** path only; the transient-deferral path writes and dispatches nothing (proven by exact equality over the whole read log) but spends **one `.high` read per tick, ~12/min, no backoff, no memory**. The test pins that ceiling rather than removing it — a documented trade (`Brain.swift:1310-1321`). (ii) An escalated `printStockShort` run **holds its carrier indefinitely** (`.needsAttention` ∈ `owningStatuses`); with N carriers in a resource-short world all N escalate and growth stops. The 15-min retry floor lengthens the fuse to ~45 min; it does not close it. |
| 7 Bounded blast radius | `allWritesAreAdditive` (60 ticks of superset checks, with a non-vacuity assertion) • `aRacingClaimOnTheSameSpareRelayIsRefusedAtCommitTime` + twin • prune pins `loadBearingRelayIsPinned`, `brandNewHopTowardUnreachedValueIsPinnedByConstruction`, `equalCostAlternativeChainsPinOneCompleteServingChain`, `censusHoleAnywhereInTheMeshPinsEveryRelay`, `anchorWithNoCensusPositionPinsEveryRelay`, `relaysOnTheRoadToAReplicantAwayFromTheHubArePinned`, `systemHoldingOurOwnDeployedDevicesIsPinned`, `meshedSystemNobodyHasSurveyedIsPinned` • rail `theReserveRailIsArmedWithTheCalibratedFloor`, `aggregateSpendFloorIsPinnedToItsDerivedValue` • authority `aCarrierHostingNoReplicantPrintsRatherThanReclaiming`, `aSourceTheNewRelayNeedsToLinkToIsNotReclaimed` | Residuals recorded, not closed: an *interior* census hole is structurally not enumerable before the search runs; `meshSystems` is presence-based (see finding 3); `Brain.swift:549` computes `meshLinks` off the live mesh while applying `claimed` only to the candidate. |
| 8 Live why-view | `aPublishedReportReachesTheDirectivesFeaturesState`, `noReportMeansNoCard` • `candidatesRenderInRankOrderWithTheirGraphFacts`, `dispatchRendersTheTopCandidatesRationaleAsTheGate`, `theFourGateStatesAllReadDifferently` • `aRecent429SurfacesDistinctlyFromSelfThrottling`, `anOld429IsNotReportedAsCurrentPressure` • `theReserveFloorLineReportsAllThreeVetoStatesNotJustTwo`, `theCapNeverHidesTheLaunchedCandidate` | No. "No new table" holds — the feed is `@Shared(.inMemory)` and the branch's only schema change is one nullable column. |

## Sign-off verification (2026-08-04)

`swift build --build-tests` clean; index store linked. Per-product event-stream
runs (one output path per product — the multi-target truncation trap), all six
targets this branch touched:

| Product | Test functions | Suites | Failed | Skipped | Crashed |
| --- | --- | --- | --- | --- | --- |
| DirectiveEngineTests | 607 | 84 | 0 | 0 | 0 |
| GameServicesTests | 219 | 28 | 0 | 0 | 0 |
| DirectivesFeatureTests | 129 | 12 | 0 | 0 | 0 |
| GameModelsTests | 69 | 12 | 0 | 0 | 0 |
| APITests | 38 | 9 | 0 | 0 | 0 |
| GameDatabaseTests | 20 | 7 | 0 | 0 | 0 |

**1,082 test functions across 152 suites, zero failures, zero crashed targets**
(each stream carries exactly one module and one `runEnded`).

> Counting note: `testStarted` fires for **suites as well as functions**, so a
> raw `testStarted` count reads 691 for DirectiveEngine where the console says
> 607. The per-task ledger figures in this build (691/247/141/81/47/27) are the
> combined counts. Discriminate on the `test` record's `kind` field.

## Open items carried forward (none block sign-off; all recorded, none papered over)

- `DeviceRefreshClient.testValue` is `{ _, _ in nil }` — a live deviation from
  the "Loud test defaults" rule. An un-stubbed brain test defers *silently*.
  Durable fix: `unimplemented(…)`.
- `DirectiveEngine.stop()` cancels the brain task but does not await it, so a
  logout landing inside `tickBrain()`'s suspension can republish after the
  clear. One-line fix: `guard !Task.isCancelled` before the publish.
- `DirectiveLogEntry` has **no retention policy** while `WorldSnapshot.read`
  re-fetches a directive's entire log every tick — the amplifier behind a whole
  defect class found during this build.
- `Brain.reservedDevices`' adoption edge is directed and crosses containment
  components, so one directive can transitively reserve every carrier sharing a
  controller. Error direction is safe (idle), but the hold can persist. Cheap
  fix: make the adoption edge terminal.
- `RelayRun.swift:966` should name the carrier in its `.refreshDevices` so the
  carrier gate's refresh cannot collapse to `.unreachableDevice` unread.
- `UniverseModels/Sources/LocationModels.swift:523` — `Belt`'s doc comment lists
  a richness qualifier `abundant` that does not exist and omits `scarce`/`rich`.
- Prune availability depends on **survey coverage** of the mesh: a waypoint
  relay in an unscanned system is pinned indefinitely, and waypoint systems are
  exactly the ones a survey run least likely scanned. Prune may fire far less
  often than ticket 10 assumes.
