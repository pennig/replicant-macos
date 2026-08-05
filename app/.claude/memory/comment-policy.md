---
name: comment-policy
description: "A comment may only explain the code as it exists in situ — history goes to .claude/memory/ and git, never the source. The trap the whole effort kept rediscovering: check-comments.sh exit 0 is a floor, not a finish line — it's regexes over dates and device codes and cannot see rationale, so design essays pass it cleanly."
metadata:
  type: feedback
---

# Comment policy

Derived from the DirectiveEngine comment-cleanup effort — ten reviewed tasks
against `docs/superpowers/comment-cleanup-standard.md`, which is the canonical
statement and should be read in full before doing this work again. This note is
the durable summary.

## The rule

**A comment may only explain the code as it exists in situ.** History — why it
changed, what broke, what was rejected, product/design rationale — goes to
`app/.claude/memory/` and to git, never into the source.

**KEEP:** what the file is and does; invariants true of the code itself; what
each parameter means; what a caller must guarantee.

**DELETE:** dated history ("as of 2026-08-04", "before the fix", round-N
narratives); rejected alternatives; product/design rationale; live-fleet
snapshots (device codes, replicant names, stock figures); incident narratives;
provenance pointers ("ticket 05 decided this", "spec §11"); restatement of
what the code plainly says. A pointer survives only when it names *where a
full contract lives*, never *who decided it*.

## The binding budget is a SHAPE, not a line count

Per-file line targets derived from a ratio were tried and explicitly
overruled by review starting at Task 3: they are not reachable on files with
a lot of executable code, and chasing a count is what breaks parameter
coverage. The actual budget is per-declaration:

For each declaration, allow exactly —
1. one sentence saying what it does, naming **every** parameter;
2. one sentence per live prohibition or invariant a caller can violate, each
   stated as rule-plus-consequence in the present tense (a consequence-of-
   violation survives — "treating that absence as 'device gone' deletes the
   fleet"; a bare explanation-of-choice does not — "which is why `step` is a
   bare `String`");
3. nothing else.

**A file fails on a surviving sentence that names no rule. It never fails on
a line count. It DOES fail on a parameter cut to make a count.** Sweep every
parameter list before calling a doc comment done — Task 2 landed comfortably
above its line target and still silently dropped a parameter's meaning in
two cases.

## `check-comments.sh` is a floor, not a finish line

`app/scripts/check-comments.sh` exists and its exit code gates the mechanical
pass. It is eleven regexes over dates, "as of", "used to", and device codes —
it has no notion of rationale. Design essays, "modeled on X" narrative, and
product justification all pass it cleanly. Passing the lint proves nothing
about whether the prose survives the standard's real test (does this change
what a correct implementer writes?); that judgment has to be made by hand
against the KEEP/DELETE lists above, every time, even on a file that already
shows exit 0.

## A false comment is corrected, never just deleted

When a surviving comment states something untrue, and the true rule is
caller-facing and already recorded in `.claude/memory/`, correct the comment
to the true rule rather than deleting it. Deleting is the fallback for when
the truth isn't known yet. Correcting a sentence changes no executable line
and is squarely inside a comment-only pass.

## Before deleting a load-bearing fact: open the note, don't trust its title

When a fact being deleted from source is load-bearing, it must already live
in `.claude/memory/` (with a matching `MEMORY.md` index line) — write the note
first if it doesn't. Confirming that is only valid by **opening the linked
note and reading the fact inside it**; a title or index line that sounds like
it covers the topic is not evidence the specific number or derivation
actually made it in. **Tunable constants and their derivations are where
every gap in this effort was found — four separate tasks each surfaced one**:
a calibration argument sitting only in a source comment, with no note
anywhere carrying the arithmetic behind it, until the cleanup pass forced the
question. Treat any hand-tuned literal (a cutoff, a budget, a cap, a deadline)
as suspect by default.

## A file may legitimately GROW

`SurveyRun.swift` went from 218 to 231 comment lines in a pass whose purpose
is removing them, and was approved: 14 declarations had zero doc comments,
and a zero-line doc cannot pass the "every parameter gets a sentence" rule.
**Report gross removed and gross added, not net** — a net change close to
zero can hide a large two-way churn (SurveyRun's pass removed 121 lines and
added 134). The failure mode to police is a file that grew because deletion
was timid, which shows up as low gross removal; a file that grew because
previously-undocumented declarations finally got documented is fine.
Private helpers get docs too — a stricter "only caller-misusable
declarations" rule was considered and rejected, because it would have
deleted the two highest-value additions in the task that established this.

## Scope status

**`DirectiveEngine` is the only module swept as of this note.** Verified
result: `check-comments.sh` exit 0 across the module; `swift build
--build-tests` clean; `DirectiveEngineTests` 757 started / 757 ended / 0
failed / 0 skipped / runEnded 1, identical to the pre-cleanup baseline; all 26
files' executable lines byte-identical to the pre-cleanup commit (`843d377`)
— the pass was provably comment-only. The module went 10,825 → 9,298 total
lines, 6,082 → 4,555 comment lines (25% of comment lines removed). Densest
remaining files by comment count: `Brain.swift` (766), `RelayRun.swift`
(678), `SalvageRun.swift` (509), `DirectiveEngine.swift` (305),
`HaulRun.swift` (277).

This policy governs comment work in **all modules going forward**, but only
`DirectiveEngine` has been sanitized against it. The other ~175 non-test
source files in the app, and every test file, have not been touched by this
effort and should not be assumed clean.

## The honest density number

The plan that scoped this effort predicted the module would land at roughly
1,800–2,200 surviving comment lines. It landed at 4,555 — more than double.
Ten independent task reviews each looked at the gap and adjudicated the
per-file line targets as **arithmetically wrong**, not as evidence of a
missed or timid pass: on file after file, the reviewers could not hold "one
sentence per parameter plus one sentence per live prohibition, per
declaration" to a target derived from a ratio, and when they measured
surviving prose against the standard's actual test (does this change what a
correct implementer writes?), only about 2% of it failed. Record both
numbers — the ~1,800–2,200 prediction and the 4,555 outcome — rather than
trusting either alone; the prediction was a planning estimate that turned
out to be a bad model of the file set, and the outcome is a real count that
by itself does not say whether the pass was thorough or lax. The per-file
sanity check that replaced the line target: above ~1.9 comment lines per
executable line, justify the file declaration by declaration; below that,
the ratio isn't evidence of anything on its own.

Related: `docs/superpowers/comment-cleanup-standard.md` (full standard, evolved
across the ten tasks), `app/CLAUDE.md` (`## Comments` section — the same rule
stated as the always-on project rule).
