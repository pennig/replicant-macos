# Comment cleanup + forward-going comment policy

**Date:** 2026-08-05
**Scope:** `app/Modules/DirectiveEngine/Sources` (26 files, 10,825 lines)

## Problem

Comment density in this codebase has drifted far past explanation into archaeology.
Measured across non-test Swift sources, comment lines as a fraction of total lines:

| File | Lines | Comment lines | Ratio |
|---|---|---|---|
| `MissionStepMachine.swift` | 300 | 240 | 0.80 |
| `PrunePredicate.swift` | 349 | 236 | 0.67 |
| `RelayRun.swift` | 1581 | 1016 | 0.64 |
| `HaulRun.swift` | 615 | 391 | 0.63 |
| `Brain.swift` | 1841 | 1143 | 0.62 |
| `SalvageRun.swift` | 1247 | 758 | 0.60 |

The top twelve files by ratio are all in `DirectiveEngine`. Roughly 5,800 of that
module's 10,825 lines are comments.

The excess is not explanation of the code. It is four other things:

1. **Dated bug archaeology.** `MissionStepMachine.swift` spends twelve lines on how
   `.refreshFootprint` behaved "before 2026-08-03" and what that shape did wrong.
2. **Live-fleet snapshots.** `RelayRun.swift`'s header names device codes
   (`43C9B54A`, `C7836770`), replicant names (`pennig-1`, `pennig-scan`,
   `pennig-salvage`), and asserts a fleet-wide precondition "as of 2026-08-04".
3. **Rejected alternatives.** "The alternative — a print-VESSEL, collapsing printer
   and carrier into one device — is not built."
4. **Incident narratives.** "the run that prompted this went
   `noSurveyControllerAboard` on a controller the server had already re-stowed."

All four rot. Facts (2) are already false the moment the fleet changes; (1) and (4)
describe code that no longer exists; (3) describes code that never existed.

Critically, this content already has a home. `app/.claude/memory/` holds one fact per
file with a loaded index, and it already records most of this in more detail than the
code comments do — `brain-relay-reserve-floor.md` covers the `refreshFootprint`
round-2/3/4 history at greater length than `MissionStepMachine.swift` does.

## The rule

**A comment may only explain the code as it exists in situ.**

### Keep

- **File header.** What the file is, what it does, and invariants true of the code
  itself (purity, one-shot lifecycle, what owns what). Target ~10 lines; ~20 is the
  ceiling for the largest files.
- **`///` doc comments on public and internal API.** What it does, what each
  parameter means, what a caller must guarantee. Bare contract.
- **Inline `//`.** Only where intent is not recoverable by reading the code: a
  non-obvious algorithm step, a deliberate deviation from the obvious approach, or a
  workaround for an external constraint (server behaviour, SDK bug).

### Delete

- Dated history — "as of 2026-08-04", "before the fix", "this worked differently
  before", round-N narratives
- Rejected alternatives, and "we considered X"
- Product and design rationale — *why we chose this shape* belongs in memory
- Live-fleet snapshots — device codes, replicant names, current stock figures
- Incident narratives
- Provenance pointers ("ticket 05 decided this"). A pointer survives only when it
  names *where the full contract lives*, never who decided it.
- Restatement of what the code plainly says

### Worked example

`MissionStepMachine.swift`, `.refreshFootprint` — 34 comment lines today:

```swift
/// Re-read the whole stockpile census, persist it, then ask the machine
/// again against the fresh `world.footprints`. Resolved by the engine.
///
/// - `thenStall` non-nil: an unresolved re-ask collapses to `.stall`.
/// - `thenStall` nil: it falls back to `.advanceStep(nextStep:)`.
case refreshFootprint(nextStep: String, thenStall: DirectiveAttentionReason?)
```

Six lines. Contract only — no dates, no prior shapes, no incident.

`RelayRun.swift` header — 55 lines today:

```swift
//
//  RelayRun.swift
//  Replicould — DirectiveEngine
//
//  Grows the FTL mesh by one system: acquire a relay, stow it aboard the
//  carrier, fly to the target's Lagrange point, deploy, activate in-situ,
//  confirm the mesh grew. One-shot — a run meshes exactly one system and
//  finishes.
//
//  Two sources converge at `stowing`: `sourceRelayCode` nil PRINTS a fresh
//  relay at the hub; non-nil RECLAIMS the named one. The reclaim path
//  requires a carrier hosting a replicant — unexpressible in these types,
//  so `carrierRetainsAuthority` gates the `stow` on the server's own
//  `in_control_range`.
//
//  Pure: no I/O, no clock reads (time is `world.now`), no randomness.
//
```

Seventeen lines. The carrier precondition survives because it is a live constraint on
the code; the fleet inventory proving it held on one date does not.

## Disposition of deleted content

Deleted history is **not** migrated wholesale. For each load-bearing fact about to be
removed, grep `app/.claude/memory/`. If it is covered, delete freely. If it is
genuinely unrecorded, extend the relevant memory note first, then delete.

One known gap: the `.refreshFootprint` self-loop hazard — that a self-referential
`nextStep` with `thenStall: nil` re-enters every tick forever, because
`DirectiveExecutor.move` re-stamps `stepStartedAt` unconditionally so the step
deadline never fires. `brain-relay-reserve-floor.md` covers the round-2/3/4 history
around it; confirm the hazard itself is stated as a rule a future caller would find,
and extend the note if not.

## Enforcement

### `app/CLAUDE.md`

A new `## Comments` section stating the rule above — keep list, delete list, and the
pointer that history goes to `.claude/memory/`.

### `app/scripts/check-comments.sh`

A grep over comment lines only, in `DirectiveEngine/Sources` to start. Flags:

- four-digit years (`19xx`/`20xx`)
- `as of`, `used to`, `previously`, `before the fix`, `no longer`, `we considered`,
  `the alternative`
- bare 8-hex-digit device codes

Exit non-zero on any hit, printing `file:line: <matched text>`.

Deliberately **no ratio threshold**. A density cap punishes files that legitimately
need dense API documentation and is gamed by writing longer code. The greps above
target objective, mechanical violations with near-zero false-positive rate.

## Verification

1. `swift build --build-tests` clean from `app/Modules`.
2. Full `DirectiveEngine` test suite green, read from Swift Testing's JSON event
   stream per the `swift-test-event-stream` skill — never by scraping console text.
3. `check-comments.sh` exits zero over the cleaned module.
4. `git diff` shows changes only in comment lines. Any executable-line change is a
   defect in the pass, not an improvement, and gets reverted.

Comment-only edits should not move behaviour. Build and tests exist here to catch an
edit that clips real code, not to validate a design change.

## Expected outcome

~5,800 comment lines to roughly 1,800–2,200. Module total from 10,825 to about 7,000.

## Accepted risk

Bare-contract `///` means a future caller can pass `thenStall: nil` into a
spend-gating step and reintroduce the unbounded self-loop. The mitigation is the
memory note, not the comment. Raised during design and accepted deliberately.

## Out of scope

- Test files. `DirectiveEngineTests.swift` (2,256 lines) and its siblings are the
  other bloat pocket, but a test comment is often the only statement of what a case
  proves. Separate pass, separate judgement.
- Other modules' sources. The policy governs them going forward; the cleanup pass
  does not reach them. Below ~35% density the tail is mostly reasonable doc comments.
- Any change to executable code.
