# Multiple Theatres — residuals after the build

Status: the 14-ticket plan is implemented, reviewed and green. This file records what
was deliberately NOT done, what a follow-up must do, and the facts a future reader would
otherwise have to rediscover. Written at the end of the effort; the per-ticket ledger it
was distilled from lived in a git-ignored scratch directory and is gone.

## The one thing to read before standing up a second theatre

**Do not stand up a second theatre until the readiness follow-up below lands.** The type
system is fully multi-theatre; the behaviour is roughly 40% of it. Recognition, both
resolvers, prune, restock, mine ferries and haul routing are genuinely per-theatre.
Survey, salvage, mine installation and the general haul drainer are not.

## Follow-up ticket, gating — theatre-aware readiness

`Brain.surveyReadiness`, `salvageReadiness` and `mineReadiness` each take
`theatres.first(where: \.isOperational)`, and `haulReadiness` only asks whether any
operational theatre exists. Each is resolved **once, before** its caller's
`for theatre in ...` loop. So for every sibling theatre the loop constructs a directive
carrying the FIRST theatre's carrier and roam centre while stamped with the sibling's
`theatreDepot`. Only `ensureOne`'s account-wide device-reservation check stops those rows
committing.

Consequences at two theatres:

- Theatre B gets no survey run, no salvage run, no mine, and no general haul drainer.
- Four `"… declined: X is already committed"` notices every 5-second tick, forever.
- `BrainLimits.hubStock` and the why-view goal lines report theatre A's numbers under
  theatre B's heading.

The work is to give those four functions a `Theatre` parameter and scope carrier
selection to that theatre's depot along with them. `plan()`'s grow pass needs the same
treatment — it takes one best candidate globally and idles the whole pass if that
candidate's nearest theatre has no free carrier, rather than falling through.

`TheatreLivenessTests` pins the device-reservation guard as the mechanism that currently
holds this together. That test is correct and should stay; the follow-up makes the guard
stop being load-bearing for this case.

## Behaviour deltas that shipped, invisible at one theatre

- **Depot selection moved from richest-stocked to lowest-depot-designation.** The deleted
  `WorldView.hubLocation` ordered by stock with designation as the tie-break. The
  readiness functions above now take `theatres.first(where: \.isOperational)`, and
  `theatres` is sorted by depot designation. Same for `Snapshot.hubFootprint`, which feeds
  `BrainLimits.hubStock`. That one is display-only — `limits` is documented "Reports,
  never gates" — so there is no rail impact, but the why-view shows the lowest-depot
  theatre's stock rather than the richest.
- **Tier-3 derivation is byte-identical to the deleted rule.** Same predicate, same `> 0`
  stock clause, same `max { left == right ? $0 > $1 : left < right }` tie-break, which
  selects the lexicographically SMALLEST designation on a stock tie. The existing depot
  provably does not move.

## Open, not blocking

- **`hub_bonus` is dead code.** It is declared in `openapi.json` on
  `TravelResponseSchema`, but the app's travel preview calls the endpoint backed by
  `DeviceCommandResponseSchema`, which does not declare it and is
  `additionalProperties: false`. The field is stripped at the first generated decode, so
  the badge can never light. Verified inert rather than wrong end to end: missing key →
  `decodeIfPresent` → nil → `if plan.hubBonus == true` → no badge, no crash. Needs a
  `probe-api` run against the real travel endpoint to settle whether the server sends it —
  operator work, because a travel call mutates the live account.
- **`HaulTargetPlanner.secondsPerLy = 30` is uncalibrated.** The per-candidate raw-units
  fallback is in place, so a wrong constant degrades to the old ordering rather than to no
  haulage. Ordering is provably total: no NaN path, a `seconds > 0` guard, and same-system
  piles short-circuit to `.infinity` before distance is computed. Calibration needs
  measurement against real ferry legs. See `app/.claude/memory/haul-round-trip-ranking.md`.
- **The 15 ly System Hub relay range is assumed to combine as `min`.** No hub exists on the
  account to measure against. Under-estimating connectivity is the safe direction — it
  means a theatre services fewer systems than it could, rather than producing an
  impossible ferry. Record the measurement when the first hub lands.
- **`TheatreSiteRanking`'s 30 ly redundancy ceiling is borrowed, not derived.** It is
  `2 × Brain.reclaimRangeLY`, and `reclaimRangeLY` was calibrated for reclaim-versus-print
  economics — a different decision. Sound analogy, not a proof. Know that before re-tuning.
- **`TheatreSiteRanking.rank` walks the whole star catalogue** (~14,788 rows), a few
  million to tens of millions of distance computations per call. It is called only from
  reducer effects, both now `.cancellable`. It must never move onto a SwiftUI `body`,
  `onChange`, or any render path — see
  `app/.claude/memory/scroll-anchor-forces-foreach-walk.md` for the recorded hang.
- **`TheatreSiteRankingTests.unsurveyedStillOffered` was strengthened but its sibling
  fixtures are still thin.** Several rank tests have few competing candidates. Worth a
  pass whenever that suite is next touched.
- **Retry amplification** (a brain retry re-arming the mission's own re-entry budget,
  recorded in `brain-salvage-build`) is untouched and gets multiplied by theatre count.
  At one theatre the multiplier is 1.

## Facts worth keeping

- **`theSupervisorAdoptsTheRowTheBrainLaunched` is intermittent, not deterministic.**
  `app/.claude/memory/supervisor-adopts-row-whole-package-failure.md` describes it as
  failing under `--build-system native`. Across roughly a dozen whole-package runs during
  this effort it failed twice and passed the rest, including on the verified baseline. Do
  not attribute it to a change without re-running.
- **The whole package is 2861 tests, not the ~335 the plan cites.** 335 is
  `DirectiveEngine`'s slice. Swift Testing emits a `testStarted` for suites as well as
  functions, so a ticket adding one suite and five tests moves the total by six.
- **`swift test --event-stream-output-path` truncates on this package.** Under the default
  `swiftbuild` backend every test target is its own process and each truncates the same
  file, so a whole-package run reports only the last module. Use
  `--build-system native` for whole-package runs, or `--test-product` for scoped ones. The
  `swift-test-event-stream` skill covers it.
- **`app/macOS/ReplicantApp.swift` is outside both `swift build` and the LSP index.** The
  `theatrePins` session-cleanup registration there is verified only by eye. A typo would
  stay invisible until a second account signs in on the same machine.
