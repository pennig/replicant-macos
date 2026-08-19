# 32 — The constants come home; the borrow count is measured

Type: task
Status: resolved
Blocked by: 26, 28, 29, 30, 31
Labels: directives-architecture, stage-2

The last Stage 2 ticket. Constants move onto the sub-machine that uses them, the print rail leaves `RelayRun`, dead declarations go, and the borrow count is measured against its target and recorded.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 13.

Two constants are dead or near-dead, both confirmed by exhaustive textual sweep during ticket 17 **after an LSP `findReferences` returned empty on a cold index and could not be trusted**:

- `RestockRun.pollInterval` (`RestockRun.swift:64`) — **zero readers in `Modules`, production or test**. Delete.
- `RelayRun.trackedKinds` (`RelayRun.swift:89`) — no production reader; read only by `RelayRunTests.swift:1535` and `:1559`. **Decide deliberately**: delete it with the two assertions, or add the production reader the tests imply exists. A constant only tests read is a claim nothing enforces.

Four missions construct a whole `RelayRun(reserveFloor:)` to reach two instance methods that have nothing to do with relays (`EventRun:171,345`, `RestockRun:120`, `MineFleetPrint:118`, `EventCourierPrint:83`) — 5 constructions, 10 calls. Extract `PrintRail` and leave `RelayRun` a caller like the rest.

Six constants have **only cross-file readers**. `stagingFreshness = 5 * 60` is declared three times with no alias linking them; leave those and add a punch-list line rather than inventing a sub-machine to hold one number.

---

- [x] **Step 1:** Delete `RestockRun.pollInterval`; decide and act on `RelayRun.trackedKinds`.
- [x] **Step 2:** Create `Sources/Steps/PrintRail.swift`; repoint all five construction sites.
- [x] **Step 3:** Move `SalvageRun.activationDeadline` and `relayPollInterval` to `RelayRun` (their only reader). Retire the `printDeadline` alias chain onto `PrintJob.deadline`.
- [x] **Step 4:** **Measure the borrow count.** Recorded below.
- [x] **Step 5:** Append the six deferred items to `punch-list.md`, each with `file:line`.
- [x] **Step 6:** Run **all five targets**; `check-comments.sh` over every touched path; commit.

**Done when:** the borrow count is recorded, the punch list carries the six deferrals, all five targets are green, and Stage 2 is ready for operator review.

---

## The borrow count, measured

Two metrics, because the plan's printed script and the plan's target measure different populations.

### 1. The reconstructed metric — the one the 52 came from

> Count bare mentions of **another** mission type's name — qualified `X.` **or** construction `X(` —
> on **code lines only** (`//` and `///` stripped), in **mission source files only** (excluding
> `Brain`, `BrainReport`, `BrainCeiling`, `MissionRegistry`, `DirectiveEngine`, `DirectiveExecutor`,
> `WorldSnapshot`), self-references excluded.

Validated: it reproduces the plan's published `52` **exactly** at `0115c20`, along with its
sub-figures (`RelayRun→SalvageRun` 16, `RestockRun→RelayRun` 6, `EventCourierPrint→EventRun` 5).

| commit | count |
|---|---|
| `0115c20` (plan baseline) | **52** |
| `323ae56` (before this ticket) | **31** |
| `eed6d95` (after this ticket) | **20** |

**The target of `<15` was not reached, and was not forced.** All 20 that remain are in four
families the plan itself rules out of scope:

| borrow | n | sites | why it stays |
|---|---|---|---|
| `RelayRun → SalvageRun` | 9 | `RelayRun.swift:83` (`relayDeviceType`), `:217`, `:287`, `:311` (`relay(aboard:)`), `:295` (`deployedRelay`), `:709` (`systemResolutionDeadline`), `:713` (`unresolvedReadBand`), `:716` (`systemUnresolvedRetryWindow`), `:734` (`lagrangePoint`) | genuine relay vocabulary, not a copied idiom — the plan's own words |
| `EventCourierPrint → EventRun` | 5 | `EventCourierPrint.swift:36` (`isCourier`), `:37` (`standingLocation`), `:69` (`isCourierHull`), `:101` ×2 (`courierDeviceType`, `rootTag`) | `EventCourierPrint` prints `EventRun`'s courier, so the ownership is right even though the reader is elsewhere |
| `RestockRun → RelayRun` | 3 | `RestockRun.swift:89`, `:152` (`idleRelays`), `:127` (`relayDeviceType`) | Restock exists to top up the relay pool; domain vocabulary, not a copied idiom |
| `MineRun → HaulRun` | 3 | `MineRun.swift:153`, `:248` (`deliverySink`), `:266` (`deliveryLocation`) | blocked behind the punch-list item "`HaulRun.deliveryLocation` still exists in the engine", itself blocked on backfilling `theatreDepot` for legacy rows |

Reaching `<15` would mean taking the courier five or the relay nine, both of which the plan rules
out on ownership grounds. Nothing was invented to move the number.

### 2. The plan's printed script — for checkpoint continuity only

Run verbatim over `DirectiveEngine/Sources/*.swift`:

| commit | occurrences | distinct lines |
|---|---|---|
| `0115c20` | 105 | — |
| `323ae56` | 83 | 82 |
| `eed6d95` | **74** | **73** |

This metric scores the `PrintRail` extraction at close to zero on its own terms: `PrintRail(reserveFloor:)`
is a construction, not a `RelayRun.` reference, and the ten calls are `rail.footprintCensusIsStale(...)`
on a local. It is recorded so the ticket's checkpoint history stays comparable, not as a judgement.

The plan's "114 occurrences / 108 distinct lines" at `0115c20` does not reproduce under either rule
(the printed script gives 105 there) and is treated as a stale intermediate. Nothing depends on it.

---

## Comments

Resolved by `fc2f21f`, `7186bf2` and `eed6d95` on `worktree-directives-stage-2-tail`. Full record in
`.superpowers/sdd/plan-stage-2/task-13-report.md`.

**Step 1.** `RestockRun.pollInterval` deleted (zero readers, re-swept). `RelayRun.trackedKinds`
deleted — no production reader exists and no honest one could be added, because the two sites that
depend on what it encoded (`RelayRun.swift:600`, `:806`) depend on it as the ABSENCE of a guard. The
set lives on `RelayRunSimpleVerbTests` as its oracle; both tests' load-bearing assertions unchanged.

**Step 2.** `Sources/Steps/PrintRail.swift` takes `footprintCensusIsStale`, `printStockIsShort` and
`printStockShortDiagnosis` (the third travels with the pair — its doc locks it to the second's
branch order). `PrintRail` declares `pollInterval` and `hubFreshness` as roots; `RelayRun` aliases
both, which keeps `BrainReport.swift:113`'s cross-module read and sixteen test readers unchanged.
Six construction sites: `EventRun.swift:171`, `:345`, `RestockRun.swift:116`, `MineFleetPrint.swift:90`,
`EventCourierPrint.swift:84`, and `RelayRun.swift:334` itself. `RelayRun.swift:335`'s extra
`reserveFloor != nil` conjunct preserved exactly, and proved load-bearing by mutation
(`unarmedRailNeverVetoesEvenOnUnknownStock` goes red without it).

**Step 3.** `SalvageRun.activationDeadline` → `RelayRun.swift:90`. `SalvageRun.relayPollInterval`
deleted rather than moved — Ruling 4 left it with zero readers, so its value and doc landed on
`PrintRail.pollInterval`. `SalvageRun.arrivalConfirmDeadline` (zero production readers) and
`arrivalReadInterval` (two) deleted, readers pointed at `TravelTo`. The whole `printDeadline` alias
chain retired onto `PrintJob.deadline`, including `EventRun.printSlack`'s hop; five of the eight
repointed test readers were themselves cross-mission borrows. `RelayRun.theatreDepot(in:for:)` was a
pure pass-through and is deleted; two production and **seven** test callers now call `world`
directly. `EventRun.courierDeviceType` and `MineRecipe.carried` left as ruled — but the plan's
"only cross-file readers" rationale is false for both (`EventRun.swift:84`, `MineRecipe.swift:43`).

**Step 4.** Recorded above: **52 → 31 → 20** under the metric that reproduces the plan's own
baseline. The `<15` target was not reached and was not forced; all 20 are in four families the plan
rules out of scope, itemised with `file:line`.

**Step 5.** `punch-list.md` gained a `## Stage 2 — ticket 32` section: the plan's six deferrals,
Task 11's item 8 carried forward (item 9 closed by this ticket), and six new findings including
`RelayRun.activationDeadline`'s value having no defender (measured: `10 * 60` → `11 * 60` leaves
1774/1774/0). Six stale entries corrected in place.

**Step 6.** All five targets green, each on its own event-stream path, every count unchanged from
the `323ae56` baseline: `DirectiveEngineTests` 1774/1774/0, `GameServicesTests` 324/324/0,
`GameSyncTests` 81/81/0, `GameModelsTests` 153/153/0, `DirectivesFeatureTests` 297/297/0.
`check-comments.sh` exit 1 on three files, every hit pre-existing and verified identical against
`HEAD`'s version of each file. No behaviour changed; no existing assertion edited. Two `#expect`
lines pinning the now-deleted `printDeadline` aliases were removed with them.

### Review round

Review verdict on `fc2f21f`/`7186bf2`/`eed6d95`/`4e4de67`: **Spec pass, Quality needs fixes**. Six
fixes landed; full record in `.superpowers/sdd/plan-stage-2/task-13-fixround.md`.

The two that mattered were coverage holes this ticket's own moves created or concentrated. Four
constants it moved or re-rooted could be changed with the whole 1774-case target green — every
reader writes its fixture RELATIVE to the constant — and `PrintRail.pollInterval` was the worst of
them: the census bound six print sites gate an irreversible spend behind had zero value defenders,
so a retune reddened only three tests about relays polling relay rows and the obvious repair would
have hidden it. Both closed, and each pin proved by re-running the review's own mutation set and
watching exactly the new pins go red at their own `file:line`.

Also: `Tests/Steps/PrintRailTests.swift` created (`PrintRail` was the only `Steps/` type without a
test file); sixteen doc pointers renamed off `RelayRun.printStockIsShort` /
`footprintCensusIsStale` / `relayPollInterval` across ten `.swift` sites and six memory notes;
`PrintRail.swift`'s four over-budget doc blocks trimmed to three lines each, now that
`brain-relay-reserve-floor` names the right type to point at.

All five targets green: `DirectiveEngineTests` 1782/1782/0 (226 suites + 1556 cases — 7 new pins,
1 new suite), `GameServicesTests` 324/324/0, `GameSyncTests` 81/81/0, `GameModelsTests` 153/153/0,
`DirectivesFeatureTests` 297/297/0.

The reconstructed borrow count is **unchanged at 20** — this round added tests and renamed comments
and touched no cross-mission code reference. The printed script moved **74 → 70**, because it counts
comment lines and four of the renamed pointers (`BrainReport.swift` ×2, `BrainCeiling.swift`,
`Brain.swift`) spelled `RelayRun.` inside a `///`. A four-point move for zero code change is a fair
illustration of why that script is recorded for continuity rather than judged by.
