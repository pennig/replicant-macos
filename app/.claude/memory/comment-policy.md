---
name: comment-policy
description: "A comment may only explain the code in situ, under a HARD budget — 6-line file header, 3-line declaration doc, 2-line inline. The first version of this policy set a keep-test and refused a line budget; it produced 20-line docs on string constants and left the module it swept the most commented in the repo. Records why, so the same reasoning is not re-derived."
metadata:
  type: feedback
---

# Comment policy

## What the first version got wrong

The 2026-08-05 DirectiveEngine pass ran against a standard that set a **keep**
test ("does this change what a correct implementer writes?") and explicitly
refused a line budget, calling the budget "a shape, not a count". It also
licensed files to GROW during a reduction pass, required a sentence per
parameter, and required docs on private helpers.

Measured outcome: DirectiveEngine went 38% → 35% comment lines across ~40
commits, and finished as **the most heavily commented module in the repo**,
above every module the pass never touched (repo average 25%). The prose it
produced included 20-line doc comments on string constants and a 54-line
comment block on a test.

The note you are reading previously ended with a section arguing the line
targets were "arithmetically wrong" and that only ~2% of surviving prose failed
the standard's test. That reasoning is the failure: a keep-test cannot bound
anything, because a determined reader finds a defensible invariant behind every
line. **Do not re-derive it.**

## The budget — hard, not advisory

    file header            ≤ 6 lines   (the //  Name.swift banner is exempt)
    declaration doc (///)  ≤ 3 lines
    inline //              ≤ 2 lines

Blank `///` lines count. A fact that does not fit in three lines is a memory
note, and the comment is the sentence pointing at it. An important declaration
does not buy a longer doc.

**Withdrawn from the first version:** the growth licence, "every parameter gets
a sentence", and docs on private helpers. A file leaves a cleanup pass with
FEWER comment lines than it entered with.

## The rule

**A comment may only explain the code as it exists in situ.** History goes to
`app/.claude/memory/` and git.

**KEEP:** what the file is; an invariant a reader cannot recover from the code;
what a caller must guarantee; a parameter whose name does not carry its meaning.
A one-line trailing `//` naming something the type cannot is cheap and good.

**DELETE:** dated history; rejected alternatives; design/product rationale;
live-fleet snapshots; incident narratives; provenance pointers ("§4.1", "ticket
05 decided this"); restatement of the signature; docs on private helpers.

**The test, applied AFTER the budget:** would a competent Swift reader get this
code wrong without the sentence? If no, cut it — however true it is.

Three habits to cut on sight: restating the signature; the argued paragraph
("so that", "which is why", "deliberately does NOT", "the alternative would");
docs on private helpers.

## Still true from the first version

- **`check-comments.sh` exit 0 proves nothing about prose.** Eleven regexes over
  dates and device codes, with no notion of an essay.
- **A false comment is corrected, not merely deleted**, when the true rule is
  caller-facing and recorded.
- **Before deleting a load-bearing fact, OPEN the memory note** — a title that
  sounds like it covers the topic is not evidence the number made it in. Every
  gap found in that effort was a hand-tuned constant whose derivation lived only
  in a source comment.
- **Executable lines must not change.** Prove it per file with the projection
  diff in the standard.

## Scope status

As of 2026-08-05 (second pass), the repo is 25,117 comment lines of 106,268
total (23.6%), down from 26,994 / 108,145 (25.0%). DirectiveEngine is 30%, down
from 35%. Roughly fifteen of the heaviest files have been swept against the new
budget; **the other ~445 have not**, and should not be assumed clean. The
remaining mass is concentrated: blocks of ten lines or more held a third of all
comment prose in 8% of the blocks before this pass began.

Related: `docs/superpowers/comment-cleanup-standard.md` (full standard and the
measurements behind the budget), `app/CLAUDE.md` (`## Comments`).
