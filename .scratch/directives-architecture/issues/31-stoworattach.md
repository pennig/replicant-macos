# 31 — `StowOrAttach` over families A and B

Type: task
Status: resolved
Blocked by: 27
Labels: directives-architecture, stage-2

Carrier-addressed containment: one command per round for the loading verbs, one command for the whole list on the way out. Six sites — `EventRun:431`, `:564`, `:719`; `MineRun:321`, `:385`, `:422`.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 12.

**Scope is six of the eighteen containment sites, and the spec's three named sites land in three different families.** Measured:

- **A** — carrier-addressed, one per round, confirmed on a containment column: `EventRun:431`, `:719`, `MineRun:321`, `:422`. `adopt` confirms on `controllerDeviceCode`, not `attachedToDeviceCode`, so the verb alone does not say which column proves it — hence `ConfirmField`.
- **B** — carrier-addressed, whole list in one command: `EventRun:564`, `MineRun:385`. A singular `device:` parameter structurally cannot express this.
- **C** — `RelayRun:695` (stow), **excluded**. It is issued ON the device with the carrier as `target:`, and `RelayRun.swift:692-693` records why: "the inverse would stow the vessel into the relay". A `verb` parameter cannot switch which end a command is issued at.
- **D** — resource moves (`EventRun:441`, `:576`, `:697`, `:784`), **excluded**. The payload is `[String: Int]`, the confirm is a scalar `cargoUsed`, and two of the four have no confirmation by design.
- **E** — parameterless lifecycle, **excluded**. Four of these belong to `BotPhase`.

`EventRun`'s `loading` is one step dispatching two verbs from two families (attach at `:431`, `collect_resources` at `:441`, both handing to `confirmingLoad`). Only the attach leg moves. **Do not attempt to fold the resource leg in.**

---

- [x] **Step 1:** Write `Tests/Steps/StowOrAttachTests.swift`: attach orders the first loose device; finishes when all aboard; adopt confirms on the controller column; detach sends the whole list at once. Build fixtures locally — `survey-fleet-repair-build.md` records what a shared internal test helper did to four suites when Swift preferred it over a private one.
- [x] **Step 2:** Write `Sources/Steps/StowOrAttach.swift`.
- [x] **Step 3:** Migrate the six sites. Each keeps its own round-budget check and its own `ConfirmRow` ladder — `StowOrAttach` replaces the selection-and-dispatch half only. `MineRun.confirmDetach` keeps its extra `location == belt` assertion.
- [x] **Step 4:** `swift test --filter DirectiveEngineTests`; `check-comments.sh`; commit.

**Done when:** six sites migrated, the twelve excluded sites recorded with their reasons, and the target green unedited.

## Comments

Resolved by `7abce1f` on `worktree-directives-stage-2-tail`. Six sites migrated:
`EventRun.swift:430`, `:573`, `:731`; `MineRun.swift:314`, `:396`, `:440`. Twelve excluded sites
re-pinned with reasons in `.superpowers/sdd/plan-stage-2/task-12-report.md` §5 — family C is
`RelayRun.swift:691`, family D is `EventRun.swift:444`, `:589`, `:712`, `:803`, and family E's seven
occupy five shipped dispatch sites (`RelayRun.swift:814`, `Steps/BotPhase.swift:116` and `:214`,
`SurveyRun.swift:552`, `SalvageRun.swift:537`) because `BotPhase` already merged the two mission pairs.

Two departures from the plan's code block, both ruled by the controller before the work started:
batch-ness is the constructor parameter `sendsWholeList` rather than `Verb.isBatch` (the plan's rule
sends one device where `MineRun.adopt` sends the whole pending list), and `MineRun.adopt` builds one
`StowOrAttach` per `Adoption` because its carrier is not fixed. `placed(_:)` was not shipped — no
in-scope call site can use it, since the confirm halves do not migrate.

`DirectiveEngineTests` 1768/1768/0 (from a 1756 baseline: 9 new cases, 1 new suite, 2 added
regression tests for guards that were provably uncovered). `GameServicesTests`, `GameSyncTests`,
`GameModelsTests`, `DirectivesFeatureTests` all exit 0. No existing assertion edited.

Review fixes landed in `657d8ce` — six added tests, one doc line, no behaviour change.
`DirectiveEngineTests` 1774/1774/0. Each test proved by the mutation it defends producing exactly its
own failure across the full target: the three conjuncts of `MineRun.confirmDetach`'s landing
predicate (`MineRun.swift:418-421`), `MineRun.detach`'s folded empty-grid advance (`:403`),
`EventRun.recovering`'s busy-guard placement (`EventRun.swift:738`), and `ConfirmField.loose`'s
non-carrier-scoping (`Steps/StowOrAttach.swift:77`).
