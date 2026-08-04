# `tendMesh` grow + prune — the build record (SHIPPED 2026-08-04)

The automation brain's first acting capability. Design decisions live in
[brain-tendmesh-worthiness](brain-tendmesh-worthiness.md) (ticket 10) and the
robustness bar it answers is [brain-robustness-bar](brain-robustness-bar.md).
**This note is what actually shipped, where it deviated from the plan, and the
evidence map.**

Branch `worktree-tendmesh-grow-prune`, 47 commits (`5096568..d39a1f5`) over a
27-task plan (`docs/superpowers/plans/2026-08-03-tendmesh-grow-prune.md`), plus
the build record itself and a post-review fix wave (the teardown-race guards and
the no-free-carrier sentence; everything else review found was triaged *carry*
and is recorded below rather than changed).
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

## The one thing to know before running this on the live fleet

**It ships INERT on today's fleet, and that is not a defect.** The `directives`
table holds `BCC18F1C…`, a `salvageRun` in `.needsAttention` on
`awaitingRelayRestock`, owning `C7836770` — the only `heaven_vessel` at the
print hub `AINALRAM-BELT-1`. `.needsAttention` is in `Brain.owningStatuses`, so
that carrier is reserved; `freeCarrier` returns nil every tick; the brain reports
idle forever. The deadlock is circular: the stalled mission is waiting for a
relay, and the capability that would grow the mesh to supply one is blocked by
that mission holding the carrier.

Nothing in the brain can break it (`brainManagedStall` admits `relayRun` rows
only, permanently). An operator clears the `salvageRun`, or a second
`heaven_vessel` reaches the hub — see the precondition gate below before doing
the latter. The idle sentence now NAMES the holder and its state
(`Brain.carrierBlocker`), so the condition is visible on the why-view instead of
reading as calm.

## Three findings that are not in the plan text

1. ~~**`returnToOrigin: false` is a capability gap, not a bug.**~~ **CLOSED
   2026-08-04** by the return leg + restock branch (spec:
   `docs/superpowers/specs/2026-08-04-relay-return-and-restock-design.md`).
   Recorded here as it stood, because the e2e's shape only makes sense against it:

   A Relay Run *was* deliberately allowed to chain onward rather than come home,
   so on the single-carrier fleet the brain planted exactly one relay and then
   idled forever until a human flew the carrier home — one-shot mesh growth with
   a manual crank. `theNextGrowGoesToTheNextCandidateNotTheMeshedOne` hand-flew
   the carrier back (`server.place`) to get a second launch, and the e2e headline
   asserted `.idle("no free carrier at SOL-3")` verbatim as the converged state.

   **Both assertions have now been changed, deliberately and not as a
   regression.** `RelayRun.Step.returning` flies the carrier back to the hub
   LOCATION re-derived through `WorldView.hubLocation` — never
   `directive.originDesignation`, which is `SiteAssay.system(of: hub)` and would
   land it at the system's entry-point L4 rather than beside the printer, where
   `Brain.freeCarrier`'s exact-match test would still refuse it. The e2e now runs
   from a standing start to a mesh containing BOTH candidate systems on one
   carrier with no `place` call anywhere in it, and the converged sentence is
   `.idle("no grow or prune work")` — a fleet out of work rather than one that
   cannot act.
2. **The reclaim sequence is safe only because the carrier hosts a replicant.**
   Once the source relay is deactivated, authority survives via FTL rule (1)
   (a replicant physically present), never via the mesh. The executor now gates
   on the carrier's `in_control_range` against the deactivate watermark
   (`carrier.updatedAt >= directive.stepStartedAt`), and the brain refuses to
   source a reclaim for a carrier hosting no replicant. Live fleet has exactly
   one legal carrier: `C7836770` hosts `pennig-salvage`. The other heaven_vessel
   hosts `pennig-1`, the **anchor**, which must never travel.

   **The symmetric precondition is unrecorded anywhere else, and it is the
   dangerous half:** flying that carrier away must leave a STATIONARY replicant
   behind on the mesh, or rule-(2) authority (a mesh subgraph containing a
   stationary replicant) evaporates for the WHOLE mesh while the run is in
   flight — not just for the run. Today it holds by accident:
   `pennig-brain` sits on `matrix_container 831B5E49` at `AINALRAM-BELT-1`,
   stationary. Nothing states it and nothing checks it. It is now expressible —
   `WorldView` carries `replicantSystems` — so the check is cheap whenever
   somebody wants it; until then it is a precondition on the fleet, not a
   property of the code.
3. **`view.meshSystems` is presence-based, not a connectivity closure** — any
   system holding a `relaying` relay. So "the hop retains a meshed neighbour" is
   necessary but not sufficient for authority. Both grow and prune read the same
   set. Pre-existing and brain-wide.

## A SECOND CARRIER IS A GATE, not a convenience

Three separately-deferred items are latent for the *same* reason — the live
fleet has exactly one hub-co-located `heaven_vessel`, so no tick has ever had a
choice to make. **All three go live in the same tick that a second carrier
stands at the hub**, and two of them fail toward *silent* outcomes:

1. **Task 16's adoption closure** (`Brain.reservedDevices`, the adoption edge) —
   directed and crossing containment components, so one directive can
   transitively reserve every carrier sharing a controller. Outcome: a permanent
   phantom reservation. Silent — it looks exactly like "no free carrier".
2. **Task 23's `meshLinks`/`claimed` gap** (`Brain.reclaimSource` →
   `meshNeighbours`) — `meshLinks` is computed off the live mesh while `claimed`
   is applied only to the candidate, so a relay another run is already fetching
   still counts as the hop's way onto the mesh. Outcome: a relay that meshes
   nothing. Silent — the run completes.
3. **The escalated-run-holds-its-carrier item** (clause 6 (ii) below). Outcome:
   growth stops. Loud, now that `Brain.carrierBlocker` names the holder.

Adding a second carrier is therefore a change that **requires all three closed
first**, not a fleet decision. Individually each is a "carry"; together, and
armed simultaneously, they are not.

## Clause 1's write enumeration is narrower than the brain's actual writes

`brain-robustness-bar` clause 1 states the brain's writes as
`{insert directive, cancel directive, drive the sanctioned retry/cancel verbs}`,
and states them as exhaustive. They are not, as built.

`Brain.confirmCarrier` → `DeviceRefreshClient.refresh(_, .high)` →
`PollCoordinator.refresh` → `Reconciler.ingest` **upserts a `Device` row and
inserts/upserts `Operation` rows** as a side effect of the confirm-read. This is
a local-mirror sync of an authoritative read, through the shared path every
feature in the app uses — not a game-state mutation, and not the brain
composing anything — so the SPIRIT of clause 1 is intact. But the list is
written as closed, and a reader auditing "did the brain write anything else?"
against it would conclude wrongly. Read clause 1 as: *the brain's writes to
GAME STATE are those three; reading through the shared refresh path also syncs
the local mirror, exactly as any other caller of it does.*

## The `RefreshKind` exhaustiveness note, correctly framed

The chain bound (`DirectiveEngineCore.reAsk`, `paid: Set<RefreshKind>`) is
recorded as safe over a "closed four-case enum", with the implied risk being
*someone adding a fifth refresh action later*. That framing is wrong in a way
worth fixing: **the family is already mixed.** `MissionAction.refreshSystem`
(`MissionStepMachine.swift`) is a fifth refresh action TODAY. It is deliberately
not in `RefreshKind`: it is executor-handled by design
(`DirectiveExecutor.apply`'s `.refreshSystem` case — best-effort hydrate, then
advance), never engine-resolved, so it is outside the `reAsk` bound rather than
missing from it.

That self-loop was traced: `RelayRun.unresolvedSystem` issues
`.refreshSystem(nextStep: directive.step)` — a same-step re-entry, the shape
`same-step-dispatch-needs-tracked-op` warns about — and it is genuinely bounded,
by `unresolvedSystem`'s own deadline plus `SalvageRun.stepEntryCount`. **No
defect.** The reason to want an exhaustive switch over the refresh family is
therefore not that a fifth kind might arrive; it is that the family is already
split across two handlers on a distinction (engine-resolved vs executor-handled)
that only a comment records.

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
| 6 Safe degradation | `idlesWhenThereIsNoUnmeshedValue`, `idlesWhenValueIsInReachButNoCarrierIsFree`, `idlesWithNoPrintHubOnTheMesh` • `anIdleBrainAndAStuckBrainDoNotLookAlike` • `idleIsSurfacedButNotEscalated` / `stallIsSurfacedAndEscalated` / `aDeferralReadsAsItsOwnGateNotAsAnOrdinaryIdle` • `noPruneStateEverEscalates`, `aUselessRelayLeftInPlaceIsIdleCalmNotAStall` • `autoRetriesAreSpacedByTheRetryInterval` | **YES, twice.** (i) "degrades without burning budget" is proven for the **stall-retry** path only; the transient-deferral path writes and dispatches nothing (proven by exact equality over the whole read log) but spends **one `.high` read per tick, ~12/min, no backoff, no memory**. The test pins that ceiling rather than removing it — a documented trade (`Brain.swift:1310-1321`). (ii) An escalated `printStockShort` run **holds its carrier indefinitely** (`.needsAttention` ∈ `owningStatuses`); with N carriers in a resource-short world all N escalate and growth stops. The 15-min retry floor lengthens the fuse to ~45 min; it does not close it. **Post-review: the HOLD is unchanged, but it is no longer silent** — `Brain.carrierBlocker` names the holding directive and its state, so "a healthy run has the vessel for three minutes" and "a stall the brain may not touch holds it forever" are different sentences (`aStalledHolderReadsDifferentlyFromAHealthyOne`). Legibility, not policy. |
| 7 Bounded blast radius | `allWritesAreAdditive` (60 ticks of superset checks, with a non-vacuity assertion) • `aRacingClaimOnTheSameSpareRelayIsRefusedAtCommitTime` + twin • prune pins `loadBearingRelayIsPinned`, `brandNewHopTowardUnreachedValueIsPinnedByConstruction`, `equalCostAlternativeChainsPinOneCompleteServingChain`, `censusHoleAnywhereInTheMeshPinsEveryRelay`, `anchorWithNoCensusPositionPinsEveryRelay`, `relaysOnTheRoadToAReplicantAwayFromTheHubArePinned`, `systemHoldingOurOwnDeployedDevicesIsPinned`, `meshedSystemNobodyHasSurveyedIsPinned` • rail `theReserveRailIsArmedWithTheCalibratedFloor`, `aggregateSpendFloorIsPinnedToItsDerivedValue` • authority `aCarrierHostingNoReplicantPrintsRatherThanReclaiming`, `aSourceTheNewRelayNeedsToLinkToIsNotReclaimed` | Residuals recorded, not closed: an *interior* census hole is structurally not enumerable before the search runs; `meshSystems` is presence-based (see finding 3); `Brain.swift:549` computes `meshLinks` off the live mesh while applying `claimed` only to the candidate. |
| 8 Live why-view | `aPublishedReportReachesTheDirectivesFeaturesState`, `noReportMeansNoCard` • `candidatesRenderInRankOrderWithTheirGraphFacts`, `dispatchRendersTheTopCandidatesRationaleAsTheGate`, `theFourGateStatesAllReadDifferently` • `aRecent429SurfacesDistinctlyFromSelfThrottling`, `anOld429IsNotReportedAsCurrentPressure` • `theReserveFloorLineReportsAllThreeVetoStatesNotJustTwo`, `theCapNeverHidesTheLaunchedCandidate` | No. "No new table" holds — the feed is `@Shared(.inMemory)` and the branch's only schema change is one nullable column. |

## Sign-off verification (2026-08-04, re-run after the post-review fix wave)

`swift build --build-tests` clean; index store linked. Per-product event-stream
runs (one output path per product — the multi-target truncation trap), all six
targets this branch touched:

| Product | Test functions | Suites | Failed | Skipped | Crashed |
| --- | --- | --- | --- | --- | --- |
| DirectiveEngineTests | 614 | 85 | 0 | 0 | 0 |
| GameServicesTests | 219 | 28 | 0 | 0 | 0 |
| DirectivesFeatureTests | 129 | 12 | 0 | 0 | 0 |
| GameModelsTests | 69 | 12 | 0 | 0 | 0 |
| APITests | 38 | 9 | 0 | 0 | 0 |
| GameDatabaseTests | 20 | 7 | 0 | 0 | 0 |

**1,089 test functions across 153 suites, zero failures, zero crashed targets**
(each stream carries exactly one module and one `runEnded`). The pre-fix-wave
figures were 1,082 / 152, all in `DirectiveEngineTests`: +5 for the carrier
-blocker sentence (one new suite) and +2 for the teardown race.

> Counting note: `testStarted` fires for **suites as well as functions**, so a
> raw `testStarted` count reads 691 for DirectiveEngine where the console says
> 607. The per-task ledger figures in this build (691/247/141/81/47/27) are the
> combined counts. Discriminate on the `test` record's `kind` field.

## Open items carried forward (none block sign-off; all recorded, none papered over)

- `DeviceRefreshClient.testValue` is `{ _, _ in nil }` — a live deviation from
  the "Loud test defaults" rule. An un-stubbed brain test defers *silently*.
  Durable fix: `unimplemented(…)`.
- ~~`DirectiveEngine.stop()` cancels the brain task but does not await it, so a
  logout landing inside `tickBrain()`'s suspension can republish after the
  clear.~~ **FIXED in the post-review fix wave, and it was wider than "one line
  before the publish".** The same suspension window also reaches
  `Brain.respondToStalls`' `resolution.retry` and `Brain.launch`'s
  `Directive.insert`, which were held back only by GRDB throwing
  `CancellationError` out of its async accessors — verified by mutation: with
  `launch`'s new guard removed the insert still does not land, so the dependency
  really was load-bearing, and undocumented. Guards now sit at four points, each
  immediately before an irreversible act with its own suspension in front of it:
  entry to `tickBrain()` (a tick that BEGINS after `stop()`), before the auto-
  `retry`, before the `.high` confirm-read and again before the insert, and
  before the publish. Pinned by `aTickStoppedMidFlightPublishesNothingAndWrites
  Nothing` and `aTickThatBeginsAfterStopNeverRunsAtAll` — neither awaits the tick
  before calling `stop()`, which is what the pre-existing
  `stoppingClearsTheWhyViewsFeed` did and why it could not catch this.
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
- `WorldView.read` decodes the `systemJSON` blob of every surveyed system every
  tick — 141 of 14,122 today, ~1,700 decodes/min, which is nothing. The header
  now names the threshold at which the `belts` index-table escape hatch stops
  being YAGNI: **a few thousand surveyed systems** (~36,000 decodes/min at
  3,000). Another automation is actively growing survey coverage, so this is a
  number to watch, not a hypothetical.
