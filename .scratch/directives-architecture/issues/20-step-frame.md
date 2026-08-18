# 20 — The step frame: `StepContext` and `StepResult`

Type: task
Status: resolved
Blocked by: —
Labels: directives-architecture, stage-2

The frame every sub-machine reads and answers with. No mission changes: this exists so tickets 21–32 have something to compile against.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 1 carries the code.

`StepResult` has four cases, not the spec's two. `.more` exists because every dispatch/confirm loop handles one item and returns to its own dispatch step, and expressing that as `.action(.advanceStep(...))` would put mission step names back inside the sub-machine. `.noSubject` exists because `EventRun.swift:749` returns `.done` with no depot while `:763` returns `.advanceStep(.depositing)` on arrival — a sub-machine that collapses both into `.finished` cannot serve it.

`StepContext` exposes **two** op guards. `openOperation(for:)` is unowned and is what all 13 travel sites use today; `ownedOperation(for:)` is owner-scoped and is what the print sites use. Conflating them silently changes 13 sites.

---

- [ ] **Step 1:** Write `Tests/Steps/StepContextTests.swift` — owner derivation matches what `DirectiveExecutor.swift:58` builds, `elapsed` measures the step, and the two guards give different answers for a co-tenant's op.
- [ ] **Step 2:** `swift build --build-tests` and confirm it fails on `cannot find 'StepContext' in scope`.
- [ ] **Step 3:** Write `Sources/Steps/StepResult.swift` and `Sources/Steps/StepContext.swift`.
- [ ] **Step 4:** `swift test --filter StepContextTests`, read the result from the event stream.
- [ ] **Step 5:** `check-comments.sh`, commit.

**Done when:** three tests green, `check-comments.sh` exit 0, and `Package.swift` is untouched (`DirectiveEngine` is a path-based target, so `Sources/Steps/` needs no edit).

---

## Comments

**Resolved by `8d3beaf`.** `StepContext`/`StepResult` written `internal` per the plan Global Constraint, not `public` as the code blocks show. Two plan defects corrected on the controller's pre-flight ruling: `Operation.kind` is a `String`, so the fixture writes `OperationKind.travel.rawValue`, not `.travel`.

`StepContextTests` 3/3 green via the JSON event stream; the whole `DirectiveEngineTests` product 1502/1502 with no regressions. `check-comments.sh` exit 0, `Package.swift` untouched. Task review: spec ✅, quality Approved — the reviewer traced `theTwoGuardsDiffer` against `WorldSnapshot.openOperation(for:owner:)` (`:186-191`) and confirmed it fails under both plausible conflations of the two guards.

One deferred minor: `StepResult.swift` imports `Foundation` without using it.
