# 17 — Write the Stage 2 (step library) plan

Type: task
Status: resolved
Blocked by: 07, 14, 15
Labels: directives-architecture, stage-2, planning

The design is in `spec.md` §Stage 2. This ticket produces the plan and its tickets; it writes no production code. It is deliberately a separate step because the exact duplication left after Stages 0–1 is what the plan must be written against, and the operator wants to review it before the build begins.

**Output:**
- `.scratch/directives-architecture/plan-stage-2.md` in the `superpowers:writing-plans` format (header, Global Constraints copied from `plan.md`, File Structure, tasks with failing-test-first steps and real code — no placeholders).
- Tickets `.scratch/directives-architecture/issues/20-…` onward, one per task, `Blocked by:` chains explicit, `Labels: directives-architecture, stage-2`.

---

- [x] **Step 1: Re-measure the duplication**

With Stages 0–1 on `main`, re-run the audit's idiom count over `app/Modules/DirectiveEngine/Sources` (travel frames, hand ladders vs `MissionConfirm.ladder`/`isFresh`, return-homes, bot-phase pair, print sites, log walkers, sibling static references per mission). Record the table in `## Comments`. Anything the earlier stages already collapsed is out of scope for Stage 2.

- [x] **Step 2: Invoke `superpowers:writing-plans`** against spec §Stage 2 with these constraints baked in:

- Sub-machines live in `app/Modules/DirectiveEngine/Sources/Steps/` (one file each: `TravelTo.swift`, `ConfirmRow.swift`, `PrintJob.swift`, `StowOrAttach.swift`, `BotPhase.swift`, `ReturnHome.swift`, plus `StepContext.swift`/`StepResult.swift`). Each is a pure value with `func next(_ ctx: StepContext) -> StepResult`; `StepContext` carries `directive`, `world`, `owner: CommandOwner`, and the mission's own `Step` for `nextStep` payloads.
- Migration order is fixed: (1) `BotPhase` replaces the Survey/Salvage pair (both suites green before and after; the ~200-line bodies deleted); (2) `TravelTo` + `ReturnHome` replace the 12+4 frames; (3) `ConfirmRow` replaces the remaining hand ladders (all `MissionConfirm.ladder` callers included, then delete `MissionConfirm`); (4) `PrintJob` wraps `MineFleetPrint.printer` for now — Stage 3 swaps the chooser; (5) `StowOrAttach` last (RelayRun stow, EventRun loading, MineRun attach).
- After each migration, the sibling-static reference count for the migrated idiom must be zero (`RelayRun→SalvageRun` etc.); the plan states the grep.
- Every sub-machine gets its own test file exercising deadline-first ordering, watermark semantics and the owner-aware guard directly, so the mechanical classes are tested ONCE at the sub-machine, not per mission.
- Delete the Stage-1 legacy fallbacks noted in tickets 15 (`lastDispatch` prose split, `DirectiveStallDetail` prefix parse).

- [x] **Step 3: Self-review per the skill; then stop**

Set `Status: resolved` and leave the plan for operator review. Do not begin the build in the same session unless told to.

---

## Comments

**Resolved by `53b7065`** — `plan-stage-2.md` (2,806 lines) plus tickets 20–32, and a Stage 2 section added to `plan.md`'s index. No production code was written. Measured against `main` at `0115c20`, with `swift build --build-tests` green (150.9 s) and the index store linked (2,320 units).

### Step 1 — the duplication as it stands after Stages 0–1

| Idiom | Audit figure | Measured now | Notes |
|---|---|---|---|
| Travel frames | ~12 | **13 dispatch sites** (9 outbound + 4 return-home) | `RelayRun` 4, `EventRun` 3, `SalvageRun` 2, `SurveyRun` 2, `MineRun` 2. Zero in `HaulRun`, `RestockRun`, `MineFleetPrint`, `EventCourierPrint`. |
| — same-step loops | not measured | **11 of 13** | Only `MineRun:355` and `EventRun:510` have the dispatch/confirm pair the spec assumes. The other 11 have no confirming step and no flight deadline. |
| — sharing one watermark | not measured | **13 of 13** | All call `SalvageRun.travelPositionUnconfirmed` (`SalvageRun.swift:323`). |
| Return-homes | 4 | **4** | `MineRun:507` and `RelayRun:908` are the same function twice, differing only in a logger string. |
| Hand ladders | ~13 | **21 hand-rolled**, plus **10** on `MissionConfirm.ladder` | Seven families by requirement — see below. |
| Bot-phase pair | 2×~200 lines | **194 + 203** (151 + 160 non-comment) | `SurveyRun:598-791`, `SalvageRun:669-873`. `probe` byte-identical (md5 `d630420ab179204a442cae451e3f796c`). |
| Print sites | 4 | **5** | `MineFleetPrint:142`, `RestockRun:133`, `EventCourierPrint:97`, `EventRun:380`, `RelayRun:401`. |
| Log walkers | 4 | **3 functions, 15 sites** | `dispatchRounds` ×10, `dispatchRounds(kind:)` ×3, `lastDispatch` ×2. Both legacy prose fallbacks still live. |
| Sibling statics | `RelayRun→SalvageRun` ×17 | **114 occurrences / 108 lines**; that pair is **16** | `RepairFleet` 34 and `MineRecipe` 28 are intentional namespaces; **52 borrows reach into a live mission struct**, 24 of them into `SalvageRun`. |

Most-borrowed, by borrowing file: `SalvageRun.travelPositionUnconfirmed` (4 files, 11 sites) and `RelayRun.init(reserveFloor:)` + its two rail methods (4 files, 10 calls) tie for first. Then `RelayRun.theatreDepot(in:for:)` (3 files) — a one-line pass-through to `world.theatreDepot(for:)` — and `RestockRun.printDeadline` (3 files), itself an alias of `RelayRun.printDeadline`.

**Already collapsed by Stages 0–1, so out of Stage 2's scope:** the arrival watermark (one implementation, 13 sites), `world.isFresh` (14 sites), the owner-scoped `openOperation(for:owner:)`, the typed `Step` enums and the typed log columns.

### The four places the spec's Stage 2 shape did not survive

1. **`StepResult` needs four cases, not two.** `.more` because every dispatch/confirm loop returns to its own dispatch step, and `.noSubject` because `EventRun:749` returns `.done` with no depot while `:763` advances on arrival.
2. **`ConfirmRow` cannot take a `predicate:`.** The 21 sites disagree on success in six incompatible ways. It owns the *ordering* and answers `.judge`; the mission keeps its own test. Honest coverage is 26 of 31 sites.
3. **`PrintJob` covers three of five.** `RelayRun` anchors on `carrier.location`, `EventRun` computes a blueprint-derived deadline from `lastOrderedAt`. Stage 3 unifies all five when it replaces the chooser anyway.
4. **`StowOrAttach`'s three named sites are in three different families.** `MineRun`'s attach fits; `RelayRun`'s stow is inverse-addressed and is excluded; `EventRun`'s `loading` dispatches two verbs from two families. Delivered over families A and B — six of eighteen containment sites.

### Found while measuring

- **A live defect.** `EventCourierPrint.swift:113` polls `world.openOperation(for: directive.deviceCode, owner: directive.id)` — the launch-pinned host — while the dispatch at `:98` went to `printer.deviceCode`, which `MineFleetPrint.printer` may have substituted. On substitution the poll watches the wrong queue. Ticket 30 fixes it test-first.
- **`RestockRun.pollInterval` (`RestockRun.swift:64`) is dead** — zero readers in `Modules`, production or test. `RelayRun.trackedKinds` (`:89`) has no production reader, only two test assertions. Ticket 32 takes both.
- **No deadline-ordering inversion survives anywhere.** The one that looks inverted, `HaulRun.swift:372`, checks the deadline in both arms. But **four sites have no deadline at all**: two bounded only by the engine's `paid`-set collapse, one by design, one by nothing.
- **There are three legacy prose fallbacks, not two.** The self-review caught the third on the last pass: `DirectivesFeature/Sources/DirectiveStallDetail.swift:26`, carrying the same "Stage 2 deletes this" marker. It is easy to miss because every other Stage 2 ticket stays inside `DirectiveEngine`. Ticket 29 now takes all three, and notes that the prefix MATCH at `:24` must stay — `DirectiveLogEntry` has no typed reason column, so the summary prefix is how an entry is matched to the row's current reason.
- **A tooling note now in the plan's Global Constraints.** `findReferences` on `RestockRun.pollInterval` returned empty while the file emitted `No such module 'GameModels'` — a cold index, not evidence. Both dead-constant claims were settled by exhaustive textual sweep instead.

### Four questions for the operator

Recorded in full in `plan-stage-2.md` § Open questions. The first wants an answer before ticket 22 lands:

1. **`SurveyRun` and `SalvageRun` disagree about an empty hold, and the tests pin both.** Arriving with no bots aboard but bots already standing in the system, `SurveyRun:602` skips arming entirely — repair silently does not happen — while `SalvageRun:676` arms them. `SurveyRunRepairTests.swift:17` and `SalvageRunRepairTests.swift:106` pin the two by name, but **neither fixture distinguishes the case**: both worlds hold zero service bots anywhere, so they pin "botless fleet", not "bots already deployed". The plan preserves both behaviours and does not pick.
2. `RelayRun.trackedKinds` — delete it with its two assertions, or add the production reader they imply?
3. The four no-deadline confirm sites — acceptable, or bound them in Stage 2?
4. `ConfirmRow`'s throttle boundary — `ladder` waits at exactly `readInterval`, `probe` reads. The plan adopts `ladder`'s.
