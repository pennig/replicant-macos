# The brain's survey goal — the build record (SHIPPED 2026-08-06)

Design: `docs/superpowers/specs/2026-08-06-brain-survey-goal-design.md`.
Plan: `docs/superpowers/plans/2026-08-06-brain-survey-goal.md`.
The brain's second acting capability, after [brain-tendmesh-build](brain-tendmesh-build.md).
Additive: no schema change, no new table, no new poller.

## What shipped

**Liveness, not scheduling.** A Survey Run's continuous roam is unbounded and
self-targeting, so the brain does not schedule surveys — `Brain.ensureSurvey`
keeps **exactly one** live `surveyRun` alive, launching one when none exists.
It mirrors `ensureRestock` including the re-check **inside the write
transaction**: the liveness read and the insert are separate steps and a row
from the previous tick can land between them.

**`Brain.surveyReadiness`** is a pure two-case verdict — launch with a carrier
and roam centre, or idle with a named reason. **It has no stall case, so it
cannot escalate by construction**, not merely by testing. Three gates:

- the `auto:survey` carrier tag (`Brain.surveyCarrierTag`),
- staging, judged through `SurveyRun`'s OWN queries (`controller(aboard:in:)`,
  `adoptedDrones(of:aboard:in:)`) so brain and mission cannot disagree about
  what staged means,
- a roam centre the census can place.

**The census gate is the non-obvious one.** `SurveyRun.plan` returns
`.exhausted` when it cannot place its centre, so a run launched with an unknown
centre finishes immediately having charted nothing. The centre is derived from
`view.hubLocation` through `SiteAssay.system(of:)`, matching `PrunePredicate`.

## Why an unstaged fleet is idle and never a stall

Survey Run never stows and never adopts — staging is the operator's job by an
explicit product decision. So launching at an unstaged vessel produces an
instant `noSurveyControllerAboard` stall: the brain manufacturing work for a
human. Declining is correct. `brainManagedStall` remains gated to `relayRun`,
so a `surveyRun` can never enter the retry/escalate path at all.

## No same-tick guard is needed, and here is why

`tendRestock` defers when the tick already committed a grow dispatch.
`ensureSurvey` deliberately does **not**, and the reason is specific:
restock's demand is derived from the same ranking a grow dispatch just
consumed, so a dispatch tick can leave it stale. `surveyReadiness` never touches
`plan`/`ranked`/`decision` — it reads device, tag, stow and census state only —
and the fleets are disjoint by tag (`auto:survey` vs `auto:tendmesh`). There is
no shared derived value and no contention path.

## `.paused` counts as LIVE but must not READ as a fault

`Brain.owningStatuses` is `[.running, .needsAttention, .paused]`. A paused run
is the operator's deliberate, possibly indefinite choice, and relaunching around
it would override a human decision — so it blocks relaunch.

But the why-view must not therefore call it broken. Two rounds of review went
into the card's four sentences, and the rule that emerged is worth keeping:
**state a status and a static fact, never a status and an active verb.**

    running       roaming from <CENTRE> — carrier <code>
    halted        halted, roam centre <CENTRE> — carrier <code>
    paused        paused, roam centre <CENTRE> — carrier <code>
    fixed target  surveying a fixed target queue — carrier <code>

`halted — roaming from <CENTRE>` was written first and rejected: "roaming"
asserts motion, so the sentence contradicts itself in six words.

**A fixed-target Survey Run has no roam centre at all.**
`NewDirectiveFeature` writes `roamCentre: nil` unless the run is continuous, so
`.launched` carries `String?` and says what the run IS doing rather than
substituting a placeholder — a fake value would also have been styled in the
monospace token reserved for real designations.

## The clock this started, deliberately

`WorldView.read` decodes the `systemJSON` blob of **every surveyed system on
every tick**. That was 142 systems of 14,122 known when this shipped, which is
free — and it was pinned at 142 only because nothing was charting.

**This capability is what drives that number.** The
[tendMesh build record](brain-tendmesh-build.md) names "a few thousand surveyed
systems" as the point where the `belts` index-table escape hatch stops being
YAGNI. The hatch was deliberately not built here — speculative work against a
threshold two orders of magnitude away. Re-measure when the surveyed count
passes ~1,000.

## Live state at ship

`F2908E6E` (Heaven Vessel, `auto:survey`) was already staged with controller
`B2CBDEC6` and six adopted drones, and the anchor's system was in the census —
so **this launches a real Survey Run on the first tick after it merges.** That
is the intent, and it is the one capability on this branch that is not inert.

Carrying no service bots, the fleet surveys unrepaired until an operator stages
two — see [survey-fleet-repair-build](survey-fleet-repair-build.md), whose
phases degrade quietly when no bot is aboard.

Related: [brain-goal-decision-policy](brain-goal-decision-policy.md),
[brain-executor-seam](brain-executor-seam.md),
[directives-feature](directives-feature.md),
[tendmesh-relay-pool-and-carrier-tag](tendmesh-relay-pool-and-carrier-tag.md).
