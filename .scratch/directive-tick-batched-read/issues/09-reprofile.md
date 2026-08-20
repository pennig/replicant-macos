# 09 — Re-profile and record the real number

Status: ready-for-human
Blocked by: 08

The estimate is ~18% of a core against today's 53%. It is arithmetic from
measured shares, not a measured result, and stays unclaimed until a fresh
trace says otherwise.

Needs Matt: capturing a Time Profiler trace requires a Keychain login a
background job cannot complete. At least 90s of idle app time.

**Trap for whoever attributes it:** the parser must resolve
`<tagged-backtrace ref="N"/>`. In the original trace 147,218 of 280,546 rows
reused a deduplicated backtrace by ref, and dropping them silently attributes
47% of samples to "empty stack" — which reads like a profiler limitation
rather than the parser bug it is.

Full steps: `../plan.md` → **Task 9**.

**Attribute this honestly, or the number will read as a shortfall.** The
whole-branch review found a term the spec's arithmetic silently folded into the
share it zeroed out: `WorldSnapshot.read(from:now:directive:)` survives at six
call sites in the refresh resolvers (`DirectiveEngine.swift:481, 591, 631, 660,
705, 735`), and each is now a full `WorldCore.read` — `Device.all`,
`LocationFootprint.all` at 28,860 rows, `Star.all`, `LocationEvent.all`, all of
it. Those re-reads are necessary: they must observe the device rows the refresh
just wrote. Their absolute cost is unchanged. But they used to be one read among
~264 per minute and are now one among ~12, so their SHARE rises sharply, and
whatever fraction of ticks return a refresh action lands in the measurement.

If the measured figure overshoots ~34%, check this before concluding the design
underdelivered — and note that the branch's own transaction-counting test cannot
see it, because its `WaitingMachine` always returns `.wait` and so never reaches
those six sites. Scoping the post-refresh re-read to the touched devices instead
of re-reading the world is the obvious next lever.

**Done when:** `../spec.md`'s "Expected result" section carries the measured
split instead of the estimate, says plainly whether the arithmetic held, and
separates the tick's own cost from the refresh-resolver re-reads above. If it
did not hold, the gap is the next investigation.
