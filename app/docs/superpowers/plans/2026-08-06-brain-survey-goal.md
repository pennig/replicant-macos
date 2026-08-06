# Brain Survey Goal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The brain keeps exactly one roaming Survey Run alive, so charting runs unattended.

**Architecture:** A new `Brain.ensureSurvey` mirroring the shipped `Brain.ensureRestock`: derive the roam centre from the anchor, gate on the `auto:survey` carrier tag and on the fleet actually being staged, then insert one `surveyRun` row if no live one exists — re-checking inside the write transaction. Nothing in the shipped roam planner or the Survey Run step machine changes.

**Tech Stack:** Swift 6, SwiftPM (`app/Modules`), Swift Testing, GRDB/SQLiteData.

**Design source:** `app/docs/superpowers/specs/2026-08-06-brain-survey-goal-design.md`

## Global Constraints

- **The brain is a pure selector.** It inserts a directive row and drives nothing else. Every command still flows executor → `CommandGovernor` → engine.
- **Stateless between ticks.** Liveness is re-derived from directive rows each tick; nothing is remembered.
- **Degradation is an IDLE reason, never a stall.** Untagged carrier, unstaged fleet, or a roam centre the census does not know each produce a named idle reason and no row. A survey that cannot start is not an incident and must never escalate.
- **No schema change, no new table, no new poller.**
- Comment budget is HARD: file header ≤ 6 lines, `///` ≤ 3 lines, inline `//` ≤ 2 lines, blank `///` lines counting. `check-comments.sh` cannot see line counts — count by hand. No dates, live device codes or designations in comments.
- **Never compare `device.tags.contains(...)`** — always `Device.hasTag(_:)`, which normalises both sides. The server lowercases every tag.
- Read test results from Swift Testing's JSON event stream with `--test-product` scoping; a run without it silently truncates to zero here. `testStarted` fires for suites AND functions — report the two separately.
- New shared test helpers in `DirectiveEngine/Tests/` must carry a distinguishing prefix. A bare `device`/`world` free function at internal scope silently captured other suites' call sites and broke four tests.

---

### Task 1: `Brain.surveyReadiness` — the gates, as a pure decision

Answer "should the brain launch a survey, and if not, why not" as one pure function over the world, so the launch path and the why-view read the same verdict and cannot disagree.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift`
- Test: `app/Modules/DirectiveEngine/Tests/BrainSurveyTests.swift` (create)

**Interfaces:**
- Consumes: `SurveyRun.controller(aboard:in:)` and `SurveyRun.adoptedDrones(of:aboard:in:)` — the mission's own staging queries, so brain and mission agree on "staged"; `Device.hasTag(_:)`; `SiteAssay.system(of:)`.
- Produces: `Brain.surveyCarrierTag = "auto:survey"`, and a `Brain.SurveyReadiness` verdict that is either "launch, with this carrier and this roam centre" or "idle, for this named reason".

- [ ] **Step 1: Write the failing tests**

Cover each gate, asserting the REASON and not merely that it declined:

- A tagged, staged fleet with a census-known anchor system → ready, naming that carrier and centre.
- No vessel carries `auto:survey` → idle, and the reason names the tag so an operator knows what to do.
- A tagged vessel with no survey controller aboard → idle naming the missing controller. Must NOT be a stall.
- A tagged vessel whose controller has adopted no drones aboard → idle naming that.
- A roam centre the census does not know → idle naming it, because `SurveyRun.plan` would return `.exhausted` on the first evaluation and finish a run that did nothing.
- The anchor has no resolvable location → idle, not a crash.

Build fixtures with the `repair`-prefixed helpers already in `RepairTestSupport.swift` where they fit, or add `survey`-prefixed ones. Do not add bare `device`/`world` names.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --test-product DirectiveEngineTests --filter BrainSurveyTests --event-stream-output-path /tmp/rc-s1.jsonl`
Expected: FAIL to compile — no `surveyReadiness`.

- [ ] **Step 3: Implement the verdict**

Pure, no I/O, no clock beyond what the world carries. Read `Brain.carrierBlocker` first and mirror its register: it names the holder and the tag rather than reporting a bare "not available", precisely so an operator is not sent hunting a problem that isn't one.

- [ ] **Step 4: Run tests to verify they pass**

Run the same filter. Expected: PASS, six tests.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/Brain.swift app/Modules/DirectiveEngine/Tests/BrainSurveyTests.swift
git commit -m "feat(brain): the survey readiness verdict and its named idle reasons"
```

---

### Task 2: `Brain.ensureSurvey` — keep exactly one roam alive

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift`
- Test: `app/Modules/DirectiveEngine/Tests/BrainSurveyTests.swift`

**Interfaces:**
- Consumes: `Brain.surveyReadiness` (Task 1); `Brain.owningStatuses`; `SurveyRun().firstStep`.
- Produces: `Brain.ensureSurvey`, called from the brain's tick beside the existing restock keeper.

**Read `Brain.ensureRestock` in full before writing anything.** This task is its sibling and should be recognisably the same shape, including its transaction discipline.

- [ ] **Step 1: Write the failing tests**

- A ready fleet with no live `surveyRun` inserts exactly one row: kind `.surveyRun`, `deviceCode` the carrier, `roamCentre` the anchor's system, `step` = `SurveyRun().firstStep`, status `.running`.
- A second tick with that row live inserts nothing — assert over the whole directive table, not just a count of survey rows.
- A row in each of `Brain.owningStatuses` counts as live, including `.needsAttention` and `.paused`. A paused survey is the operator's choice and the brain must not relaunch around it.
- A `.completed` or `.cancelled` row does NOT count as live, so a finished roam is replaced.
- An idle verdict from Task 1 inserts nothing and writes nothing at all.
- The brain writes NO other row while doing this — assert the directive table is otherwise untouched, the way `allWritesAreAdditive` does for grow.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/Modules && swift test --test-product DirectiveEngineTests --filter BrainSurveyTests --event-stream-output-path /tmp/rc-s2.jsonl`
Expected: FAIL — no `ensureSurvey`.

- [ ] **Step 3: Implement it**

Mirror `ensureRestock`: read liveness from the snapshot, then **re-check inside the write transaction** before inserting, because the read and the write are separate steps and a row created by the previous tick can land between them. Log the launch through the house `os.Logger` at the same register as the restock launch.

Wire the call into the brain's tick beside the restock keeper.

- [ ] **Step 4: Run tests to verify they pass**

Run the filter, then the whole product:
`cd app/Modules && swift test --test-product DirectiveEngineTests --event-stream-output-path /tmp/rc-s2b.jsonl`
Expected: zero failures. Baseline is 714 functions / 95 suites / 0 failed.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/Brain.swift app/Modules/DirectiveEngine/Tests/BrainSurveyTests.swift
git commit -m "feat(brain): keep one roaming survey alive"
```

---

### Task 3: Surface survey on the why-view

Clause 8 of the robustness bar: an operator asking "why is nothing charting?" must be able to answer it on screen. Today `Brain.Plan.idle(reason:ranked:prune:)` carries only the grow/prune story, and survey's verdict has nowhere to go.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/Brain.swift` (the published report)
- Modify: whichever `DirectivesFeature` view renders the brain report — find it from the `brainReport` shared key rather than assuming a filename
- Test: the existing brain-report and feature tests

**Interfaces:**
- Consumes: `Brain.surveyReadiness` (Task 1).

- [ ] **Step 1: Trace the existing path first**

Follow `@Shared(.inMemory("brainReport"))` from where the brain publishes it to where the view renders it, and add survey alongside the existing content rather than reshaping it. Do NOT fold survey's reason into the grow/prune `idle` reason — they answer different questions and conflating them makes both harder to read.

- [ ] **Step 2: Write the failing tests**

- A published report carries the survey verdict, ready or idle-with-reason.
- The three idle reasons render distinguishably — an operator must be able to tell "no tagged vessel" from "nothing staged aboard" without opening the log.
- A ready survey and a launched survey do not read identically.

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd app/Modules && swift test --test-product DirectiveEngineTests --filter Survey --event-stream-output-path /tmp/rc-s3.jsonl`

- [ ] **Step 4: Implement, then verify both products**

`DirectiveEngineTests` (baseline 714/95/0) and `DirectivesFeatureTests` (baseline 146/15/0), each with its own `--event-stream-output-path`, plus `swift build --build-tests` clean.

Respect the UI rules: no hard-coded colors, spacing or font sizes — use `DesignSystem.swift` tokens; a system or location designation renders in a monospace token; a list-row struct lives in its own file away from any `#Preview`.

Watch for the chrome min-height trap: a vertical `fixedSize` `Text` in non-scrolling chrome reports its zero-width wrap height as the view's minimum, which AppKit makes the window's minimum height. If the survey line lands in chrome rather than a scroll view, give it a `lineLimit`.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/DirectiveEngine app/Modules/DirectivesFeature
git commit -m "feat(brain): surface the survey verdict on the why-view"
```

---

## What this plan does NOT cover

- **Staging the survey fleet.** It is already staged. Survey Run never stows or adopts, and the brain only refuses to launch without it.
- **The roam planner.** `SurveyRoamPlanner` and `SurveyRun.plan` ship unchanged.
- **Priority or contention.** Survey and tendMesh use disjoint tagged fleets, so nothing arbitrates.
- **The `systemJSON` decode escape hatch.** Shipping this starts the clock on it (142 surveyed today, "a few thousand" is the threshold). Watch the count; do not build it speculatively.

## Live precondition

`F2908E6E` is tagged and staged with controller `B2CBDEC6` and six adopted drones, and the anchor's system is in the census — so this launches on the first tick after it ships. That is the intent, but it means the change is live-affecting the moment it merges.
