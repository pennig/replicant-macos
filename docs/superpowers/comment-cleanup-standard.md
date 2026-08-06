# The comment standard

## Why this replaces the previous version

The first standard set a *keep* test — "does this change what a correct implementer
writes?" — and explicitly refused a line budget, calling the budget "a shape, not a
count". Applied honestly, that produced 20-line doc comments on string constants and
a 54-line comment block on a test. Measured over the whole repo afterwards: 595
comment blocks of ten lines or more held 8,957 lines, a third of all comment prose.
The module the cleanup actually swept ended as the most heavily commented in the
repo, at 35% against a 25% repo average.

A keep test cannot bound anything, because a determined reader finds a defensible
invariant behind every line. This version sets a budget first and a test second.

## The budget — hard, not advisory

    file header            ≤ 6 lines
    declaration doc (///)  ≤ 3 lines
    inline //              ≤ 2 lines
    anything longer        needs a reason you can say out loud, per block

Blocks over the cap are not "justified by the declaration being important". They are
cut. If the fact does not fit in three lines, it is not a comment — it is a memory
note in `app/.claude/memory/`, and the comment is the one sentence that points at it.

Count blank `///` lines and `//` separator lines against the budget. A four-line doc
padded to seven with blanks is a seven-line doc. The `//  <Name>.swift` /
`//  Replicould — <Module>` banner is exempt — it is not prose, and it stays.

## The rule

**A comment may only explain the code as it exists in situ.** History goes to
`app/.claude/memory/` and git, never the source.

**Keep** — what the file is; an invariant a reader cannot recover from the code; what
a caller must guarantee; the meaning of a parameter whose name does not carry it.

**Delete** — dated history; rejected alternatives; design and product rationale;
live-fleet snapshots (device codes, replicant names, stock figures); incident
narratives; provenance pointers ("§4.1", "ticket 05 decided this"); restatement of
what the signature already says.

## The test, applied after the budget

Not "does this help?" but: **would a competent Swift reader, looking at this code,
get it wrong without this sentence?** If the answer is no, it goes — however true it
is. Truth was never the bar.

Three specific habits to cut on sight:

1. **Restating the signature.** `/// The device code.` on `var deviceCode: String`
   earns nothing. A parameter whose name carries its meaning gets no sentence. The
   previous standard's "every parameter gets a sentence" rule is withdrawn — it
   manufactured boilerplate on `directive:` and `world:` across every mission.

2. **The argued paragraph.** Any comment that reasons — "so that", "which is why",
   "deliberately does NOT", "the alternative would" — is making a case to a reader
   who is not litigating. State the rule, or delete it. A consequence survives only
   when the consequence is severe and non-obvious, and then in one clause.

3. **Docs on private helpers.** A `private func` inside the file that declares it
   gets a comment only when its body is genuinely unreadable. The previous standard
   required docs here; that requirement is withdrawn.

## Growth is not permitted

The previous standard allowed a file to grow during a comment-reduction pass, on the
grounds that undocumented declarations needed documenting. That licence is
withdrawn. **A file leaves this pass with fewer comment lines than it entered with.**
If a declaration genuinely has no doc and genuinely needs one, it gets ≤3 lines and
the file still nets down.

Report gross removed and gross added per file. Added should be near zero.

## Mechanical discipline

**Executable lines must not change.** Prove it per file, before building:

    diff <(git show <BASE>:$F | grep -vE '^\s*(//|/\*|\*)' | grep -vE '^\s*$') \
         <(grep -vE '^\s*(//|/\*|\*)' $F | grep -vE '^\s*$')

Expected empty. This projection keeps code lines carrying a trailing `//` at full
width, so an empty diff also proves no trailing comment was touched.

Then: `cd app/Modules && swift build --build-tests` → `Build complete`, no new
warnings. `./app/scripts/check-comments.sh <paths>` from the repo root → exit 0.
Keep the `//  <Name>.swift` / `//  Replicould — <Module>` header banner.

`check-comments.sh` is eleven regexes over dates and device codes. It has no notion
of an essay. Exit 0 proves nothing about the prose; judge that yourself against the
budget.

## Trailing annotations are cheap and usually fine

`private let starPipeline: MTLRenderPipelineState  // additive glow field (no depth)`
is a good comment: one line, names a fact the type cannot. Cutting these is not where
the win is. The win is in the multi-paragraph blocks — 56% of all comment prose sits
in blocks of five lines or more.
