# 26 — `ReturnHome` and the four return legs

Type: task
Status: resolved
Blocked by: 25
Labels: directives-architecture, stage-2

`MineRun.swift:507` and `RelayRun.swift:908` are the same function twice, differing only in a logger string — the cleanest extraction the re-measurement found. `SurveyRun:494` and `EventRun:746` are the same leg with two twists.

**Plan:** `.scratch/directives-architecture/plan-stage-2.md` — Task 7.

Two things stop it being trivial:

- **`EventRun` iterates two hulls**, moving whichever needs moving, one per evaluation — so `deviceCodes` is an array and the pair passes one.
- **`EventRun` must tell "arrived" from "no depot" apart** (`.advanceStep(.depositing)` vs `.done`), which is what `.noSubject` is for. The other three collapse them.

`SurveyRun` is the only site aiming at `originDesignation` — a bare SYSTEM, matched at system level. `RelayRun.swift:902-907` and `EventRun.swift:743-745` both explicitly forbid that for a depot, because a bare designation lands an L4 away from the printer.

---

- [ ] **Step 1:** Write `Tests/Steps/ReturnHomeTests.swift`: arrived, flying, `.noSubject` on no depot, `.wait` on a claimed theatre, system-level matching for `.origin`, and one hull moving per evaluation with two named. Reuse the existing `operationalTheatre` fixture — do not add a second.
- [ ] **Step 2:** Confirm the build fails.
- [ ] **Step 3:** Write `Sources/Steps/ReturnHome.swift`.
- [ ] **Step 4:** Migrate all four sites, each keeping its own logger prose and its own ending.
- [ ] **Step 5:** `grep travelPositionUnconfirmed` — now hits only `Steps/TravelTo.swift`. The 11-site, 4-file borrow is zero.
- [ ] **Step 6:** `swift test --filter DirectiveEngineTests`; `check-comments.sh`; commit.

**Done when:** six tests green, all four legs migrated, and the engine's largest single borrow is retired.
