# The cleanup standard — read before editing any file

Derived from Task 2 (`MissionStepMachine.swift`, 300 → ~165 lines) and its review.
That commit is the reference diff. Read it:

    git show <task-2-sha> -- app/Modules/DirectiveEngine/Sources/MissionStepMachine.swift

## The rule

**A comment may only explain the code as it exists in situ.** History lives in
`app/.claude/memory/` and in git, never in the source.

**KEEP:** what the file is and does; invariants true of the code itself; what each
parameter means; what a caller must guarantee.

**DELETE:** dated history ("as of 2026-08-04", "before the fix", round-N narratives);
rejected alternatives; product/design rationale; live-fleet snapshots (device codes,
replicant names, stock figures); incident narratives; provenance pointers ("ticket 05
decided this", "spec §11"); restatement of what the code plainly says.

A pointer survives ONLY when it names where a full contract lives, never who decided it.

## Five rules the Task 2 review established

1. **Every parameter gets a sentence, before any prohibition gets a paragraph.**
   Task 2 landed above its line target *and still* dropped `thenStall`'s meaning from
   two cases. Overshooting the target is fine; cutting parameter semantics while
   overshooting is not. Sweep the parameter list of every declaration before calling a
   doc comment done.

2. **A false comment gets CORRECTED to the true rule, not deleted** — when the true
   rule is recorded in `.claude/memory/` and is caller-facing. Deleting is the fallback
   for when the truth isn't known. Correcting a sentence changes no executable line and
   is squarely inside a comment-only pass.

3. **Ban "which is why" and "on purpose" as standalone justifications.** A
   consequence-of-violation survives ("treating that absence as 'device gone' deletes
   the fleet"); an explanation-of-choice does not ("which is why `Directive.step` is a
   bare `String`").

4. **The test for any surviving sentence: does this change what a correct implementer
   writes?** If no, cut it.

5. **`check-comments.sh` exit=0 is a FLOOR, never a finish line.** The lint is eleven
   regexes over dates, "as of", "used to", and device codes. It has no notion of
   rationale — design essays, "modeled on X", and product narrative all pass it
   cleanly. Task 2 confirmed this on its own intermediate drafts. Judge the prose
   yourself against the DELETE list; passing the lint proves nothing about it.

## The line target is ADVISORY — established by the Task 3 review

The plan's per-file line targets were derived from a ratio and are not reachable on
files with a lot of executable code. Task 3 landed at 1,243 against a ~700 target and
was endorsed on review: only ~2% of its surviving prose failed the standard's test.

**The binding budget is per-declaration, and it is a shape, not a count:**

For each declaration allow exactly —
1. one sentence saying what it does, naming **every** parameter;
2. one sentence per live prohibition or invariant a caller can violate, each stated as
   rule-plus-consequence in the present tense;
3. nothing else.

Inline `//` only where the code cannot be read to that conclusion. Land wherever that
puts the file, and report the number.

**A task fails on a surviving sentence that names no rule. It does not fail on a line
count. It DOES fail on a parameter cut to make a count.**

Sanity check, not a gate: if a file lands above **~1.9 comment lines per executable
line** (`MissionStepMachine.swift`'s measured post-cleanup density), justify it
declaration by declaration. Below that, the ratio is not evidence of anything and is
not worth arguing about. Task 3 landed at 1.34.

## A file may legitimately GROW — established by the Task 6 review

`SurveyRun.swift` went from 218 to 231 comment lines in a pass whose purpose is
removing them, and was approved. The reason: 14 declarations had **zero** doc
comments, and a zero-line doc cannot pass the parameter sweep rule 1 requires.

**Report gross, not net.** Task 6's SurveyRun removed 121 comment lines and added
134. The deletion was real and complete — no dated history, no incident narrative, no
provenance pointer survived. Net +13 hid a large two-way churn.

The failure mode to police is a file that grew because **deletion was timid**,
measurable as low gross removal. A file that grew because zero-doc declarations were
finally documented is fine. Always report both numbers.

Corollary, also settled in Task 6: **private helpers get docs too.** A stricter
"only caller-misusable declarations" rule was considered and rejected — it would have
saved ~6 lines of restatement and deleted the two highest-value additions in the
task, because both sat on `private func`s.

## The pattern worth copying

The best move in the Task 2 diff: when a deleted narrative contained one genuinely
load-bearing fact, that fact was **relocated to the API it is a property of** rather
than dropped with the story around it. Do this — don't let a fact die because the
paragraph carrying it was archaeology.

## Mechanical discipline — copy without modification

- **Executable lines must not change.** Prove it per file, before building:

      diff <(git show <BASE>:$F | grep -vE '^\s*(//|/\*|\*)' | grep -vE '^\s*$') \
           <(grep -vE '^\s*(//|/\*|\*)' $F | grep -vE '^\s*$')

  Expected empty. This projection keeps code lines carrying a trailing `//` comment at
  full width, so an empty diff also proves no trailing comment was touched — there is
  no blind spot.
- `cd app/Modules && swift build --build-tests` → `Build complete`, no new warnings.
- `./app/scripts/check-comments.sh <each file>` from repo root → exit 0.
- Header keeps the `//  <Name>.swift` / `//  Replicould — DirectiveEngine` banner.

## Known false comment still in the tree

`DirectiveExecutor.swift:93` says "the endpoint 403s away from the system". That is
false — `location-endpoint-presence-gate.md` records the gate as EXPLORATION, not
presence, and notes the 403's own message lies. Task 7 owns that file: correct it per
rule 2, do not merely delete it.
