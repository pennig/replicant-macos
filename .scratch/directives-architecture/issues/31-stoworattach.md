# 31 — `StowOrAttach` over families A and B

Type: task
Status: open
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

- [ ] **Step 1:** Write `Tests/Steps/StowOrAttachTests.swift`: attach orders the first loose device; finishes when all aboard; adopt confirms on the controller column; detach sends the whole list at once. Build fixtures locally — `survey-fleet-repair-build.md` records what a shared internal test helper did to four suites when Swift preferred it over a private one.
- [ ] **Step 2:** Write `Sources/Steps/StowOrAttach.swift`.
- [ ] **Step 3:** Migrate the six sites. Each keeps its own round-budget check and its own `ConfirmRow` ladder — `StowOrAttach` replaces the selection-and-dispatch half only. `MineRun.confirmDetach` keeps its extra `location == belt` assertion.
- [ ] **Step 4:** `swift test --filter DirectiveEngineTests`; `check-comments.sh`; commit.

**Done when:** six sites migrated, the twelve excluded sites recorded with their reasons, and the target green unedited.
