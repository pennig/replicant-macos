# Comment Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip `app/Modules/DirectiveEngine/Sources` of comments that record history, product rationale, or live-fleet facts, leaving only comments that explain the code as it exists — and install a rule plus a lint so it stays that way.

**Architecture:** A ruler-first pass. Task 1 builds the lint and writes the policy into `app/CLAUDE.md`; Task 2 cleans the canonical worst file and becomes the reference diff every later task imitates; Tasks 3–10 clean the remaining files in coherent groups; Task 11 verifies the module as a whole. Every task is comment-only — executable lines must not move.

**Tech Stack:** Swift 6 / SwiftPM (`app/Modules`), Swift Testing (JSON event stream), bash + grep for the lint.

**Spec:** `docs/superpowers/specs/2026-08-05-comment-policy-design.md`

## Global Constraints

- **A comment may only explain the code as it exists in situ.** Full keep/delete lists are in the spec's "The rule" section; every task's requirements implicitly include it.
- **Executable lines must not change.** This is a comment-only pass. Any behaviour change is a defect, not an improvement.
- **File header:** what the file is, what it does, invariants true of the code itself. Target ~10 lines, ~20 ceiling for the largest files. Preserve the existing `//  <Name>.swift` / `//  Replicould — DirectiveEngine` banner lines.
- **`///` doc comments:** bare contract — what it does, what parameters mean, what a caller must guarantee. No dates, no prior shapes, no incidents, no rejected alternatives.
- **Delete:** dated history, rejected alternatives, product/design rationale, live-fleet snapshots (device codes like `C7836770`, replicant names like `pennig-1`, stock figures), incident narratives, provenance pointers ("ticket 05 decided this"), restatement of what the code says.
- **A pointer survives only when it names where a full contract lives** (e.g. "see `DirectiveEngineCore.resolveFootprintRefresh`"), never who decided it.
- **Before deleting a load-bearing fact,** grep `app/.claude/memory/`. If covered, delete freely. If genuinely unrecorded, extend the relevant memory note first (with a matching `MEMORY.md` index line), then delete.
- **Never use `swift test` console text.** Read results from the JSON event stream per the `swift-test-event-stream` skill.
- **Worktree LSP setup** (already done for this worktree; redo if `.build` is wiped): `cd app/Modules && swift build --build-tests` then `./scripts/link-index-store.sh`.
- **Commits go to the current worktree branch.** No PRs, no pushing, no touching `origin`.

## Baseline (measured 2026-08-05, commit `843d377`)

Module total: **10,825 lines, 6,082 comment lines (56%)**.

| File | Lines | Comments | | File | Lines | Comments |
|---|---|---|---|---|---|---|
| `Brain.swift` | 1841 | 1143 | | `BrainCeiling.swift` | 182 | 137 |
| `RelayRun.swift` | 1581 | 1016 | | `DirectiveExecutor.swift` | 380 | 122 |
| `SalvageRun.swift` | 1247 | 758 | | `RestockRun.swift` | 206 | 115 |
| `HaulRun.swift` | 615 | 391 | | `MeshValue.swift` | 201 | 102 |
| `DirectiveEngine.swift` | 888 | 345 | | `WorldSnapshot.swift` | 212 | 101 |
| `MissionStepMachine.swift` | 300 | 240 | | `SalvageTargetPlanner.swift` | 151 | 70 |
| `PrunePredicate.swift` | 349 | 236 | | `SurveyRoamPlanner.swift` | 116 | 60 |
| `SurveyRun.swift` | 481 | 218 | | `DirectiveResolutionClient.swift` | 216 | 59 |
| `WorldView.swift` | 357 | 204 | | `DirectiveIngestion.swift` | 162 | 51 |
| `MeshGraph.swift` | 398 | 198 | | `BrainGoal.swift` | 77 | 46 |
| `BrainReport.swift` | 280 | 169 | | `HaulTargetPlanner.swift` | 96 | 43 |
| `GrowRanking.swift` | 286 | 162 | | `AMIFleet.swift` | 70 | 43 |
| | | | | `SurveyTargetSuggestions.swift` | 106 | 41 |
| | | | | `MissionRegistry.swift` | 27 | 12 |

Target: ~1,800–2,200 comment lines module-wide.

## Why this plan is not TDD-shaped

There is no new behaviour to drive out with a failing test. The invariant runs the other
way: **behaviour must not change.** So each cleanup task's verify cycle is:

1. `swift build --build-tests` clean
2. Code-only projection identical before and after (command given in every task)
3. `check-comments.sh` exits zero for the touched files
4. Full `DirectiveEngine` suite green via the event stream

Task 1 — the lint script — *is* genuinely test-first, and is written that way.

### The code-only projection check

Run from the repo root, per file:

```bash
diff <(git show HEAD:PATH | grep -vE '^\s*(//|/\*|\*)' | grep -vE '^\s*$') \
     <(grep -vE '^\s*(//|/\*|\*)' PATH | grep -vE '^\s*$')
```

**Expected: empty output.**

Caveat: a *trailing* comment removed from a code line (`let x = 1  // why`) legitimately
changes that line and will show here. That is the only acceptable difference. Inspect each
reported line; if it is anything other than a trailing-comment removal on an otherwise
identical statement, revert it.

---

### Task 1: The ruler — lint script + CLAUDE.md policy

**Files:**
- Create: `app/scripts/check-comments.sh`
- Modify: `app/CLAUDE.md` (add a `## Comments` section after the existing `## Rules` section)

**Interfaces:**
- Produces: `app/scripts/check-comments.sh [paths...]` — defaults to `app/Modules/DirectiveEngine/Sources` when given no arguments. Prints `file:line: matched text` per violation. Exits `1` if any violation found, `0` otherwise. Later tasks run it against the files they touch.

- [ ] **Step 1: Write the script so it currently FAILS on the dirty module**

Create `app/scripts/check-comments.sh`:

```bash
#!/usr/bin/env bash
# Flags comments that record history rather than explain the code.
# See app/CLAUDE.md § Comments and
# docs/superpowers/specs/2026-08-05-comment-policy-design.md
set -uo pipefail

DEFAULT_PATH="app/Modules/DirectiveEngine/Sources"
paths=("${@:-$DEFAULT_PATH}")

# Patterns that are objectively history, never in-situ explanation.
patterns=(
  '\b(19|20)[0-9]{2}\b'
  '\bas of\b'
  '\bused to\b'
  '\bpreviously\b'
  '\bbefore the fix\b'
  '\bno longer\b'
  '\bwe considered\b'
  '\bthe alternative\b'
  '\bturned out\b'
  '\bthis (used|shipped) '
  '\b[0-9A-F]{8}\b'
)

joined=$(IFS='|'; echo "${patterns[*]}")
status=0

while IFS= read -r file; do
  # Comment lines only: whole-line // and /* */ block bodies.
  if grep -nE '^[[:space:]]*(//|/\*|\*)' "$file" \
     | grep -inE "$joined" \
     | sed "s|^|${file}:|" \
     | grep . ; then
    status=1
  fi
done < <(find "${paths[@]}" -name '*.swift' -type f)

if [ "$status" -ne 0 ]; then
  echo ""
  echo "Comments above record history, not the code as it exists."
  echo "Move the fact to app/.claude/memory/ and delete it here."
  echo "See app/CLAUDE.md § Comments."
fi

exit "$status"
```

Then: `chmod +x app/scripts/check-comments.sh`

- [ ] **Step 2: Run it and verify it FAILS loudly on the un-cleaned module**

Run from repo root: `./app/scripts/check-comments.sh`

Expected: **exit 1**, with many hits — including at minimum
`MissionStepMachine.swift` (the `2026-08-03` reference) and
`RelayRun.swift` (`as of 2026-08-04`, `C7836770`, `43C9B54A`).

Confirm with: `./app/scripts/check-comments.sh; echo "exit=$?"` → `exit=1`

- [ ] **Step 3: Verify it PASSES on a clean fixture (guards against a script that always fails)**

```bash
mkdir -p /tmp/rc-lint-fixture
cat > /tmp/rc-lint-fixture/Clean.swift <<'EOF'
//
//  Clean.swift
//  Replicould — DirectiveEngine
//
//  Resolves a target designation to its entry point.
//
/// Returns the entry point for `designation`, or nil when unknown.
func entryPoint(for designation: String) -> String? { nil }
EOF
./app/scripts/check-comments.sh /tmp/rc-lint-fixture; echo "exit=$?"
```

Expected: no output, `exit=0`.

If this fails, the patterns are over-broad — fix before continuing.

- [ ] **Step 4: Add the policy to `app/CLAUDE.md`**

Insert this section immediately after the `## Rules` section's final bullet and before `## Don't`:

```markdown
## Comments

**A comment may only explain the code as it exists in situ.** History — why it
changed, what broke, what we rejected — goes to `.claude/memory/` and git, never
into the source. Enforced by `scripts/check-comments.sh`.

**Keep:**
- **A file header** — what the file is, what it does, and invariants true of the
  code itself (purity, one-shot lifecycle, what owns what). ~10 lines; ~20 is the
  ceiling for the largest files.
- **`///` on public/internal API** — what it does, what each parameter means, what
  a caller must guarantee. Bare contract.
- **Inline `//`** — only where intent is not recoverable by reading the code: a
  non-obvious algorithm step, a deliberate deviation from the obvious approach, or
  a workaround for an external constraint (server behaviour, SDK bug).

**Delete:**
- Dated history — "as of 2026-08-04", "before the fix", "this worked differently
  before", round-N narratives
- Rejected alternatives, "we considered X"
- Product and design rationale — *why we chose this shape* belongs in memory
- Live-fleet snapshots — device codes, replicant names, current stock figures
- Incident narratives
- Provenance pointers ("ticket 05 decided this"). A pointer survives only when it
  names *where the full contract lives*, never who decided it.
- Restatement of what the code plainly says

When a fact you are deleting is load-bearing and not already in `.claude/memory/`,
write the memory note first (with its `MEMORY.md` index line), then delete.
```

- [ ] **Step 5: Commit**

```bash
git add app/scripts/check-comments.sh app/CLAUDE.md
git commit -m "chore: add comment policy and a lint that enforces it

A comment may only explain the code as it exists in situ. The lint flags
the objective violations only — dates, 'as of', 'used to', device codes —
with no ratio threshold.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `MissionStepMachine.swift` — the canonical exemplar

**300 lines, 240 comments (80%) — the worst ratio in the repo. Target ~130 lines total.**

This task's diff is the reference every later task imitates. Do it carefully.

**Files:**
- Modify: `app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift`

**Interfaces:**
- Consumes: `app/scripts/check-comments.sh` from Task 1.
- Produces: the reference diff. Later tasks are told to match its density and tone.

- [ ] **Step 1: Confirm the memory covers what you are about to delete**

The big deletions here are the `.refreshFootprint` self-loop history and the
`.refreshDevices` incident narrative. Verify coverage:

```bash
grep -l "re-stamps\|self-loop\|stepStartedAt" app/.claude/memory/*.md
```

Expected to include `brain-relay-reserve-floor.md` and
`same-step-dispatch-needs-tracked-op.md`. Open both and confirm they state the hazard
as a *rule a future caller would find* — that a self-referential `nextStep` re-enters
every tick forever because `DirectiveExecutor.move` re-stamps `stepStartedAt`
unconditionally, so the step deadline never fires.

If either fails to state it that way, extend the note (and its `MEMORY.md` index line)
before deleting from code. Commit the memory change separately, first.

- [ ] **Step 2: Rewrite the header**

Current header is 12 lines and includes a stale claim ("No machines ship in this stage:
Survey Run is Stage 4, Relay Run is Stage 5") that is now false — both ship. Replace with:

```swift
//
//  MissionStepMachine.swift
//  Replicould — DirectiveEngine
//
//  A mission is a pure step machine: (directive state, world snapshot) → ONE
//  action. The engine owns every side effect — dispatching, writing rows,
//  waiting — and mission logic owns none.
//
```

- [ ] **Step 3: Compress every `MissionAction` case doc to bare contract**

`.refreshFootprint` goes from 34 lines to exactly this:

```swift
    /// Re-read the whole stockpile census, persist it, then ask the machine
    /// again against the fresh `world.footprints`. Resolved by the engine.
    ///
    /// - `thenStall` non-nil: an unresolved re-ask collapses to `.stall`.
    /// - `thenStall` nil: it falls back to `.advanceStep(nextStep:)`.
    case refreshFootprint(nextStep: String, thenStall: DirectiveAttentionReason?)
```

`.refreshDevices` goes from 32 lines to:

```swift
    /// Re-read each named device authoritatively — plus whatever those devices
    /// report stowed aboard them — then ask the machine again against the fresh
    /// snapshot. Reads are `.high`, bypassing the TTL and read-budget floor.
    /// Exactly one refresh-and-re-ask per evaluation, never a loop.
    ///
    /// Name every device the answer depends on: a carrier's `stowed_devices` is
    /// not a reliable inverse of its children's `stowedInDeviceCode`, so relying
    /// on expansion to reach a row you are judging can leave a check permanently
    /// unsatisfiable.
    ///
    /// - `thenStall` nil: an unresolved re-ask waits instead of stalling.
    case refreshDevices(deviceCodes: [String], thenStall: DirectiveAttentionReason?)
```

Apply the same treatment to every remaining case (`dispatch`, `wait`, `advanceStep`,
`assignController`, `refreshSystem`, and the rest). Each keeps what it does and what its
parameters mean; each loses spec section references (`spec §11`), rationale, and history.

- [ ] **Step 4: Verify code is untouched**

```bash
F=app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift
diff <(git show HEAD:$F | grep -vE '^\s*(//|/\*|\*)' | grep -vE '^\s*$') \
     <(grep -vE '^\s*(//|/\*|\*)' $F | grep -vE '^\s*$')
```

Expected: empty. Any output that is not a trailing-comment removal → revert it.

- [ ] **Step 5: Build**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
```

Expected: `Build complete`. No warnings introduced.

- [ ] **Step 6: Lint the file**

```bash
./app/scripts/check-comments.sh app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift
echo "exit=$?"
```

Expected: `exit=0`.

- [ ] **Step 7: Confirm the size drop**

```bash
wc -l app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift
```

Expected: ~130 lines (from 300). If still above 180, the doc comments are not yet at
bare contract — go back to Step 3.

- [ ] **Step 8: Commit**

```bash
git add app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift
git commit -m "refactor(comments): MissionStepMachine states contracts, not history

300 → ~130 lines. Every MissionAction case documents what it does and what
its parameters mean; the refreshFootprint/refreshDevices incident histories
live in .claude/memory.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Tasks 3–10: the remaining files

**Every one of these tasks follows the identical seven-step cycle.** It is written out
in full here once; each task below states only its files, its targets, and anything
specific to watch for.

**The cycle, for the file set `F1 F2 …`:**

1. **Check memory coverage** for any load-bearing fact you are about to delete:
   `grep -rl "<the fact's keywords>" app/.claude/memory/`. If genuinely unrecorded,
   extend the relevant note (plus its `MEMORY.md` index line) and commit that first.
2. **Rewrite each header** to ~10 lines (≤20 for the biggest): what the file is, what
   it does, invariants true of the code. Keep the `//  <Name>.swift` /
   `//  Replicould — DirectiveEngine` banner.
3. **Compress every `///` to bare contract**; delete inline archaeology. Match the
   density and tone of the Task 2 diff — read it first:
   `git show <task-2-sha> -- app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift`
4. **Verify code untouched**, per file:
   ```bash
   diff <(git show HEAD:$F | grep -vE '^\s*(//|/\*|\*)' | grep -vE '^\s*$') \
        <(grep -vE '^\s*(//|/\*|\*)' $F | grep -vE '^\s*$')
   ```
   Expected empty; only a trailing-comment removal is an acceptable difference.
5. **Build:** `cd app/Modules && swift build --build-tests 2>&1 | tail -20` → `Build complete`.
6. **Lint:** `./app/scripts/check-comments.sh <each file>` → `exit=0`.
7. **Commit** with `refactor(comments): <file/group> states contracts, not history`,
   the before→after line counts in the body, and the `Co-Authored-By` trailer.

---

### Task 3: `RelayRun.swift`

**1,581 lines, 1,016 comments (64%). Target ~700 lines total.**

**Files:** Modify `app/Modules/DirectiveEngine/Sources/RelayRun.swift`

Specific to watch for:

- The 55-line header. Replace with exactly the 17-line version in the spec's "Worked
  example" — it is already written; copy it verbatim.
- **Keep** the carrier-hosts-a-replicant precondition and the `carrierRetainsAuthority`
  gate: those are live constraints on the code. **Delete** the fleet inventory that
  proved it held on one date (`pennig-1`, `pennig-scan`, `pennig-salvage`, `C7836770`,
  `43C9B54A`, "As of 2026-08-04").
- **Delete** the rejected print-VESSEL alternative wholesale.
- **Delete** "(brain-primitive contracts, ticket 05)" — provenance, not a contract
  location.
- Memory coverage for the deletions is `brain-tendmesh-build.md`,
  `brain-primitive-contracts.md`, `relay-return-and-restock.md`,
  `tendmesh-relay-pool-and-carrier-tag.md`. Verify before deleting.

---

### Task 4: `Brain.swift`

**1,841 lines, 1,143 comments (62%). Target ~850 lines total.**

**Files:** Modify `app/Modules/DirectiveEngine/Sources/Brain.swift`

Specific to watch for:

- This is the largest file and carries the most product rationale — the goal taxonomy,
  the priority axes, the selector-not-enactor doctrine. Nearly all of it is design
  reasoning that belongs in memory, and nearly all of it is already there:
  `brain-goal-decision-policy.md`, `brain-robustness-bar.md`, `brain-executor-seam.md`,
  `brain-tendmesh-worthiness.md`. Verify, then delete.
- **Keep** invariants that constrain the code: that the plan loop is pure/nonisolated,
  that the brain may only touch `relayRun`/`restockRun` rows, that it is stateless
  between ticks.
- Because of its size, run the code-only projection check (cycle step 4) **before**
  building — a clipped line is much easier to find in this file from the projection
  diff than from a compiler error.

---

### Task 5: `SalvageRun.swift`

**1,247 lines, 758 comments (61%). Target ~600 lines total.**

**Files:** Modify `app/Modules/DirectiveEngine/Sources/SalvageRun.swift`

Specific to watch for:

- Heavy incident history around the `positioning`/`configuring` step split and the
  `awaitCompletion` false-stall. Covered by `salvage-run-design.md` — verify, delete.
- **Keep** the `nextBody`-keyed touring contract and the fresh-evidence gate's
  `min()`-over-drone-rows rule: both describe what the code does now.

---

### Task 6: `HaulRun.swift`, `SurveyRun.swift`, `RestockRun.swift`

**1,302 lines, 724 comments. Targets: HaulRun ~330, SurveyRun ~330, RestockRun ~130.**

**Files:** Modify all three in `app/Modules/DirectiveEngine/Sources/`

Specific to watch for:

- `RestockRun.swift` carries the "nothing polls `LocationFootprint`" reasoning. That is
  a **live constraint** on why it buys its own census read — keep one compressed
  sentence of it. Delete the dated narrative around it (covered by
  `relay-return-and-restock.md`).
- `SurveyRun.swift` lines ~415 and ~475 carry the pre-fix confirm-step shape noted in
  `confirm-steps-need-fresh-evidence.md`. **Do not "fix" anything** — this is a
  comment-only pass. Delete the commentary about it; leave the code exactly as is.

---

### Task 7: engine plumbing

**`DirectiveEngine.swift`, `DirectiveExecutor.swift`, `DirectiveIngestion.swift`, `DirectiveResolutionClient.swift`, `MissionRegistry.swift`, `AMIFleet.swift`**

**1,743 lines, 632 comments. Target ~1,250 lines total.**

**Files:** Modify all six in `app/Modules/DirectiveEngine/Sources/`

Specific to watch for:

- `DirectiveEngine.swift` holds `resolveFootprintRefresh` and the `paid: Set<RefreshKind>`
  collapse. **Keep** the termination bound as a present-tense rule — "`paid` grows
  strictly on every guarded hop over a closed four-case enum, so at most one refresh
  round per kind, ≤4 per evaluation". That is a property of the code. **Delete** the
  round-1/2/3/4 narrative explaining how it got there (`brain-relay-reserve-floor.md`).
- `DirectiveExecutor.swift`'s `move` re-stamping `stepStartedAt` unconditionally is
  load-bearing for callers — keep one sentence stating it.

---

### Task 8: mesh + ranking

**`PrunePredicate.swift`, `GrowRanking.swift`, `MeshGraph.swift`, `MeshValue.swift`**

**1,234 lines, 698 comments (57%). Target ~650 lines total.**

**Files:** Modify all four in `app/Modules/DirectiveEngine/Sources/`

Specific to watch for:

- `PrunePredicate.swift` (67% comments) carries the "implemented literally this would
  have reclaimed the ENTIRE mesh" story. That is history — covered by
  `brain-tendmesh-build.md`. **Keep** the resulting rule: the union is rooted at the
  anchor with deployed relays as free interior nodes.
- `GrowRanking.swift`'s ranking key ordering is a contract — keep it stated compactly.
  Delete the justification for each tier (covered by `brain-tendmesh-worthiness.md`).

---

### Task 9: world model + brain support

**`WorldView.swift`, `WorldSnapshot.swift`, `BrainCeiling.swift`, `BrainGoal.swift`, `BrainReport.swift`**

**1,108 lines, 657 comments (59%). Target ~600 lines total.**

**Files:** Modify all five in `app/Modules/DirectiveEngine/Sources/`

Specific to watch for:

- `BrainCeiling.swift` (75% comments) is nearly all reserve-floor arithmetic history —
  the corrected binding type, the ~18× undershoot, the rename. All of it is in
  `brain-relay-reserve-floor.md` in more detail. **Keep** the `// CALIBRATE` marker on
  `K = 5`, that `printPermitted(hubStock:)` fails **closed**, and that `resourceTypes`
  is derived from `relayBill.keys` (all three are live properties of the code).
  Numeric constants stay in the code regardless — do not touch them.
- `WorldView.swift`: **keep** that `hubLocation` must be used rather than
  `originDesignation`. Live constraint, and a trap. Delete the dated incident.

---

### Task 10: planners

**`SalvageTargetPlanner.swift`, `SurveyRoamPlanner.swift`, `SurveyTargetSuggestions.swift`, `HaulTargetPlanner.swift`**

**469 lines, 214 comments (46%). Target ~330 lines total.**

**Files:** Modify all four in `app/Modules/DirectiveEngine/Sources/`

Specific to watch for:

- These are the least bloated files. Be conservative — much of their commenting is
  legitimate algorithm explanation. Delete history and rationale; keep the algorithm
  notes.
- `SurveyRoamPlanner.swift` carries the "greedy nearest-neighbour was measured and
  rejected" note. Rejected alternative → delete (it is in `directives-feature.md`).

---

### Task 11: whole-module verification

**Files:** No source changes expected. This task is a gate.

- [ ] **Step 1: Lint the entire module**

```bash
./app/scripts/check-comments.sh; echo "exit=$?"
```

Expected: `exit=0`.

- [ ] **Step 2: Clean build from scratch**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
```

Expected: `Build complete`, no new warnings.

- [ ] **Step 3: Full DirectiveEngine suite via the event stream**

Use the `swift-test-event-stream` skill for the exact invocation. Run the
`DirectiveEngineTests` target and read pass/fail from the JSON event stream — **never**
from console text.

Expected: **zero failures.** The baseline at `843d377` is green; any failure here means
a cleanup task clipped code. Find it with the projection check (Step 4) rather than by
guessing.

- [ ] **Step 4: Prove the whole pass was comment-only**

```bash
for F in app/Modules/DirectiveEngine/Sources/*.swift; do
  d=$(diff <(git show 843d377:$F | grep -vE '^\s*(//|/\*|\*)' | grep -vE '^\s*$') \
           <(grep -vE '^\s*(//|/\*|\*)' $F | grep -vE '^\s*$'))
  [ -n "$d" ] && { echo "=== $F ==="; echo "$d"; }
done
```

Expected: no output, or only trailing-comment removals. Anything else gets reverted.

- [ ] **Step 5: Record the result**

```bash
cd app/Modules/DirectiveEngine/Sources
wc -l *.swift | tail -1
grep -cE '^\s*(//|/\*|\*)' *.swift | awk -F: '{s+=$2} END {print "comment lines:", s}'
```

Expected: total ~7,000 lines (from 10,825); comment lines ~1,800–2,200 (from 6,082).
If comment lines land above 2,600, the pass was too timid — report which files are
still densest rather than silently accepting it.

- [ ] **Step 6: Write the memory note**

Create `app/.claude/memory/comment-policy.md` recording the policy, the lint's location,
and that `DirectiveEngine` was cleaned first while other modules are governed going
forward but not yet swept. Add its index line to `app/.claude/memory/MEMORY.md`.

- [ ] **Step 7: Commit**

```bash
git add app/.claude/memory/
git commit -m "docs(memory): record the comment policy and the first cleanup pass

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage:** The rule → Task 1 (CLAUDE.md) and applied in Tasks 2–10. Disposition
of deleted content → cycle step 1 in every task, plus Task 2 Step 1 explicitly.
Enforcement → Task 1 (both halves). Verification → Task 11 (all four spec items map to
Steps 1–4). Expected outcome → Task 11 Step 5. Out-of-scope items are excluded from
every task's file list; no task touches tests or another module.

**Placeholder scan:** No TBDs. Every code block is literal content. The seven-step cycle
is written out in full once and referenced rather than restated — this is a deliberate
exception to "repeat the code", because it is a *procedure* identical across eight
tasks, and each referring task states its own files, targets and hazards.

**Type consistency:** No new types. `check-comments.sh`'s interface (paths in, `file:line`
out, exit 0/1) is defined in Task 1 and used identically in Tasks 2–11.

**Known adjustment:** the lint's `\b[0-9A-F]{8}\b` device-code pattern may false-positive
on legitimate hex constants in comments. If Task 1 Step 3's clean-fixture check passes
but a later task hits a false positive on a real hex value, narrow the pattern rather
than weakening the file — and note it in the commit.
