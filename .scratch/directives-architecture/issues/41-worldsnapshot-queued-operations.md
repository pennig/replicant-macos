# 41 — `WorldSnapshot` gains `queuedOperations`

Type: task
Status: resolved
Blocked by: 40
Labels: directives-architecture, stage-3

A pure addition, landed while the index still enforces uniqueness so that it changes nothing. Ticket 42 relaxes the index into a reader that is already in place.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 9.

**Phase B starts here, and not before Checkpoint E has been run and recorded.** If the observed concurrent-print count at Checkpoint E was 1, Phase A did not work and none of these tickets should start.

**`openOperations` keeps its current meaning until ticket 44.** This ticket only adds.

**The `id` tie-break is not decoration.** `startedAt` is a client clock stamped at dispatch, and two ops written in one transaction can share it. Without a tie-break the order is unstable across reads, and ticket 43's "oldest wins" rule inherits the instability.

Give the memberwise initialiser a `[:]` default for the new argument, or every one of the existing `WorldSnapshot(...)` constructions in tests has to change in this ticket. Say in `## Comments` that the default exists for that reason.

---

- [x] **Step 1:** Read `WorldSnapshot`'s initialiser first. If the test-facing init is memberwise and unsorted, the sort belongs inside it and the test goes there; if the sort is at the read path (`:237-239`), the test goes against the read path. Decide, then write the failing test.
- [x] **Step 2:** Confirm it fails to compile.
- [x] **Step 3:** Add the property at `:29` and fill it at `:353` with `Dictionary(grouping:by:)` over open ops, sorted by `(startedAt, id)`.
- [x] **Step 4:** All six targets green.
- [x] **Step 5:** `check-comments.sh`; commit.

**Done when:** two ops sharing a `startedAt` come back in a stable order, with a test.

---

## Comments

| Commit | Message |
|---|---|
| (pending) | `feat(directives): WorldSnapshot.queuedOperations` |

**The init is memberwise and unsorted, so the sort lives inside it, not at the read call site.**
`WorldSnapshot.init` does no computation on any other field — every array/dictionary argument is
stored as given. Rather than special-case `queuedOperations` to trust its caller like every other
field, the init sorts unconditionally by `(startedAt, id)` before storing, so the oldest-first
invariant holds for every construction path, not only `read(from:now:directive:)`. The Step-1
test (`queuedOpsAreOldestFirst`) constructs `WorldSnapshot` directly with an out-of-order list and
asserts sorted output — it is a real test of the init's sort, not a vacuous one. Confirmed by
mutation: deleting the sort, or reversing its comparator, reddens it. `read`'s construction site
does a bare `Dictionary(grouping: operations, by: \.entityCode)` with no sort of its own, so the
sort exists in exactly one place.

**The brief's Step-1 test as supplied does not compile against this file.** It uses an `op(on:owner:id:startedAt:)`
helper signature that does not match this file's actual `op(_:device:status:directiveID:startedAt:)`,
and it omits `queuedOperations:` from the init call it references (bare-memberwise
`WorldSnapshot(...)` at that point in the brief has no such parameter yet). Adapted to the real
helper; not shipped verbatim, and not vacuous — confirmed RED against unmodified source (compile
failure, `value of type 'WorldSnapshot' has no member 'queuedOperations'` etc.), independent of
that mismatch.

**The `[:]` default on `queuedOperations` exists so the ~200 existing `WorldSnapshot(...)` call
sites — three of them in production code (`Brain.swift:1398,1477,2006`), not only tests — do not
all have to change in this ticket.** Removing the default and rebuilding confirmed this: the build
fails at `Brain.swift` alone with three "missing argument" errors before even reaching test files.

**The `id` tie-break is defended by its own test, `queuedOpsTieBreakOnIDWhenStartedAtTies`**,
deliberately separate from the ordering test: two ops share `startedAt` and are constructed
out-of-`id`-order. Removing the tie-break (compare `startedAt` alone) reddens only this test —
Swift's stable sort keeps `queuedOpsAreOldestFirst` green because that fixture's `startedAt`
values differ — which is exactly the instability the tie-break exists to prevent.

**`openOperations` is untouched.** The diff adds a new property, a new init parameter with a
default, and one new line at the `read` construction site; no existing line changed.
